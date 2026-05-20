# SQL / PostgreSQL 基礎ノート

Sprint 1 で触れた内容を全体から個別の流れで整理する。

---

## 全体像

### SQL とは

データベースを操作するための言語。「データをくれ」「データを入れろ」「この構造にしろ」をDBに伝える。

```sql
SELECT name FROM categories WHERE tenant_id = '...'; -- データを取る
INSERT INTO categories (name) VALUES ('技術系');      -- データを入れる
UPDATE categories SET name = '技術' WHERE id = '...'; -- データを変える
DELETE FROM categories WHERE id = '...';              -- データを消す
```

### PostgreSQL とは

SQL を使うデータベース管理システム（DBMS）の一種。このプロジェクトでは Supabase が PostgreSQL を提供している。pgvector（ベクトル検索）などの拡張機能が使える点が採用理由の一つ。

### このプロジェクトの DB 設計の全体方針

```
アプリ（C#）
    ↓ SQL を投げる
PostgreSQL
    ├─ ロール分離（誰が接続するか）
    ├─ RLS（テナントごとにデータを分離）
    └─ pgvector（ベクトル検索）
```

セキュリティの核心は「アプリが SQL を投げても、DB 側でテナント分離を強制する」設計。アプリ側のバグや漏れがあっても DB が最後の砦になる。

---

## ロールと権限

### ロールとは

PostgreSQL における「接続する人・プログラムの種類」。Linux のユーザーに近い概念。

### このプロジェクトの2ロール構成

```
portfolio_owner  ← マイグレーション専用（スキーマの所有者）
portfolio_app    ← アプリ接続専用（C# から繋ぐ）
```

**なぜ2つに分けるか**

`portfolio_app` に `NOBYPASSRLS` を付けるため。1つのロールだけだと RLS をすり抜ける接続経路が残る。

```
スーパーユーザー（postgres）→ RLS を無視できる（BYPASSRLS がデフォルト）
portfolio_owner              → スキーマ操作専用、アプリからは使わない
portfolio_app                → NOBYPASSRLS = RLS が必ず効く、アプリはこれだけ使う
```

### GRANT（権限の付与）

```sql
-- portfolio_app に最小限の権限だけ与える
GRANT CONNECT ON DATABASE postgres TO portfolio_app;         -- 接続できる
GRANT USAGE ON SCHEMA public TO portfolio_app;               -- スキーマを使える
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES ...       -- テーブルを操作できる

-- 将来追加されるテーブルにも自動で同じ権限を付ける
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO portfolio_app;
```

「最小限の権限だけ渡す」が原則。必要ないものは渡さない。

### NOBYPASSRLS の確認方法

```sql
SELECT rolname, rolbypassrls FROM pg_roles
WHERE rolname IN ('portfolio_owner', 'portfolio_app');

-- portfolio_app の rolbypassrls が f（false）であることを確認
-- f = RLS をバイパスできない = RLS が必ず効く
```

---

## RLS（Row Level Security）

### RLS とは

テーブルの行（Row）単位でアクセスを制御するセキュリティの仕組み。「このユーザーはこの行だけ見える」を DB レベルで強制できる。

```
アプリが SELECT * FROM knowledge_entries を投げる
    ↓
RLS が「このセッションのテナントの行だけ」に自動で絞る
    ↓
アプリには自テナントのデータしか返らない
```

アプリ側で WHERE tenant_id = ? を書かなくても DB が勝手に絞ってくれる。アプリのバグで WHERE を書き忘れても漏洩しない。

### RLS の有効化

```sql
ALTER TABLE knowledge_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE knowledge_entries FORCE  ROW LEVEL SECURITY;  -- owner にも RLS を強制
```

`FORCE` がないと `portfolio_owner` で接続したときに RLS が効かない。owner でも RLS を効かせることで「誰がどの接続方法で来ても分離される」を保証する。

### ポリシー（USING / WITH CHECK）

```sql
CREATE POLICY tenant_isolation ON knowledge_entries
    USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
    WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);
```

| 節 | 役割 | タイミング |
|---|---|---|
| `USING` | 「見える行」を絞る | SELECT / UPDATE / DELETE 時 |
| `WITH CHECK` | 「書ける行」を絞る | INSERT / UPDATE 時 |

両方同じ条件にすることで「自テナントのデータしか見えないし書けない」を保証する。

### current_setting とは

```sql
current_setting('app.tenant_id', true)
```

セッション変数を読み取る関数。C# 側が `SET LOCAL app.tenant_id = '...'` でセットした値をここで参照する。

第2引数の `true` = 「変数が未設定なら NULL を返す（エラーにしない）」。これがフェイルセーフの鍵。

### フェイルセーフの仕組み

```sql
-- SET LOCAL が未発行のまま SELECT すると
SELECT name FROM knowledge_entries;

-- current_setting('app.tenant_id', true) が NULL を返す
-- NULL = どのテナントとも一致しない
-- → 0件が返る（全データ漏洩ではなく空になる）
```

「設定を忘れたら全部見える」ではなく「設定を忘れたら何も見えない」になる設計。失敗しても安全な方向に倒れる。

---

## SET LOCAL（C# 側との連携）

### アプリが DB に接続するたびにやること

```sql
BEGIN;
SET LOCAL app.tenant_id = '00000000-0000-0000-0000-000000000001';
SET LOCAL app.user_id   = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx';
-- ↑ LOCAL = このトランザクション内だけ有効。終わったら自動でリセット。

SELECT name FROM knowledge_entries; -- RLS が tenant_id で絞る
COMMIT;
```

C# の `TenantConnectionInterceptor` が接続を借りたタイミングで自動で発行する。

### LOCAL が重要な理由

```
SET LOCAL  → トランザクションが終わると自動でリセットされる（安全）
SET        → セッション全体に残り続ける（接続プールで使い回すと別テナントに漏れる危険）
```

接続プールは複数のリクエストで接続を使い回すので、`LOCAL` でないと前のリクエストのテナント ID が残ってしまう。

---

## RLS の動作確認（3ケース）

```powershell
# ケース1: テナント A のセッション → A のデータのみ
psql "$env:SUPABASE_DB_URL_APP" -c "BEGIN; SET LOCAL app.tenant_id = '<A のID>'; SELECT name FROM knowledge_entries; ROLLBACK;"

# ケース2: テナント B のセッション → B のデータのみ
psql "$env:SUPABASE_DB_URL_APP" -c "BEGIN; SET LOCAL app.tenant_id = '<B のID>'; SELECT name FROM knowledge_entries; ROLLBACK;"

# ケース3: SET LOCAL なし → 0件（フェイルセーフ）
psql "$env:SUPABASE_DB_URL_APP" -c "SELECT name FROM knowledge_entries;"
```

ケース3が0件であることが最重要。「忘れたら空になる」が確認できれば設計が正しく機能している証拠。

---

## 拡張機能

### pgvector

ベクトル（数値の配列）を DB に保存して類似度検索できる拡張機能。

```sql
embedding vector(768)  -- 768次元のベクトルを保存するカラム
```

テキストを数値の配列に変換（Embedding）して保存し、「意味が近い文章」を検索するために使う。

### pg_trgm

テキストの部分一致・あいまい検索を高速化する拡張機能。BM25（キーワード検索）と組み合わせてハイブリッド検索を実現する。

### 拡張機能の確認

```sql
\dx  -- 有効な拡張機能の一覧
```
