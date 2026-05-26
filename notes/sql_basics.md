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

### 「全テーブルに WHERE を足す」イメージとの違い

イメージとしては「全テーブルに `WHERE tenant_id = current_setting('app.tenant_id')` を付けている」で正しい。ただし正確には**アプリの SQL を書き換えるのではなく、Postgres が実行時にポリシー条件を自動で AND 結合する**。

```sql
-- アプリが投げる SQL
SELECT * FROM knowledge_entries;

-- Postgres が内部で実質こう実行する
SELECT * FROM knowledge_entries
WHERE tenant_id = current_setting('app.tenant_id', true)::uuid;
```

`WHERE` を手で書く方式との差:

- **アプリ側は tenant_id を一切意識しない**（書く必要がない）
- **回避できない** — 手書き WHERE は外したり書き忘れたりできるが、ポリシーは DB が必ず適用する。だから「最終防衛線」になる
- **SELECT だけでなく INSERT / UPDATE / DELETE 全部に効く**（`USING` が読み取り系、`WITH CHECK` が書き込み系）

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

第2引数の `true` = 「変数が未設定なら NULL を返す（エラーにしない）」。これがフェイルセーフの鍵。`false`（省略時のデフォルト）だと未設定でエラーになる。

### カスタム変数はどこで定義する？

`app.tenant_id` は**どこにも定義していない**。PostgreSQL は `名前空間.変数名` のようにドットを含む名前を「カスタムパラメータ」として扱い、`SET` した瞬間に存在する（`CREATE VARIABLE` 的な事前宣言は不要）。`app` という名前空間も「アプリ用」の意味で慣習的に付けているだけ。

```
work_mem        ← ドットなし = 組み込みパラメータ。未知の名前は SET でエラー
app.tenant_id   ← ドットあり = カスタム。検証されず任意の text として保持される
```

だから「変数の定義箇所」を探しても見つからないのが正常。読み出し側（`current_setting`）が `0003_rls_policies.sql` にあり、書き込み側（`SET LOCAL`）が C# インターセプタにある、という構造になる。

### SET / SET LOCAL / set_config

| 書き方 | スコープ | 用途 |
|---|---|---|
| `SET app.x = ...` | セッション全体（接続が閉じるまで） | プール使い回しで別テナントに残ると危険 |
| `SET LOCAL app.x = ...` | 現トランザクション内のみ、終了で自動リセット | 本プロジェクトが採用 |
| `set_config('app.x', val, is_local)` | 第3引数で上記を切替 | 値を変数で渡せる関数版（`0002` の `set_config('app.password', ...)` で使用） |

### フェイルセーフの仕組み

```sql
-- SET LOCAL が未発行のまま SELECT すると
SELECT name FROM knowledge_entries;

-- current_setting('app.tenant_id', true) が NULL を返す
-- NULL = どのテナントとも一致しない
-- → 0件が返る（全データ漏洩ではなく空になる）
```

「設定を忘れたら全部見える」ではなく「設定を忘れたら何も見えない」になる設計。失敗しても安全な方向に倒れる。

### ポリシーの3パターン

全テーブルに RLS を付けているが、絞り込み条件はテーブルの役割で3種類ある（`0003_rls_policies.sql`）。

| テーブル | 自動で足される条件 |
|---|---|
| `knowledge_entries` / `categories` / `field_definitions` / `validation_rules` / `destinations` / `inquiries` / `unclassified_queue` / `tenant_public_keys` | `tenant_id = app.tenant_id` |
| `user_tenants` | `user_id = app.user_id`（テナントではなくユーザー基準） |
| `tenants` | 自分が所属する `tenant_id` の `IN` サブクエリ、かつ SELECT のみ |

`user_tenants` は「どのユーザーがどのテナントに属するか」の対応表なので `app.user_id` で絞る。`tenants` は「自分が所属するテナントだけ可視」にし、書き込みはポリシーで許可しない。

---

## SET LOCAL（C# 側との連携）

### 変数にセットする値の出どころ

JWT 自体に tenant_id は入っていない（`sub = user_id` のみ）。ユーザーは複数テナントに所属しうるので、テナントは**リクエストごとに解決**する。

```
ログイン（Supabase Auth）→ JWT 発行（user_id だけ）
    ↓
ASP.NET Core が JWT の user_id で user_tenants を引く
    ↓
URL /t/{slug}/chat の slug と照合 → このリクエストのテナントを確定
    ↓
確定した tenant_id を HttpContext.Items に保持
    ↓
DB 接続のたびに SET LOCAL app.tenant_id = '<その uuid>'
```

肝は「**クライアントが名乗った tenant id は信じず、サーバが JWT → user_tenants 照合で導出した値だけを流す**」点。

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

---

## 現状の実装ステータス（Sprint 1 時点）

RLS は「読み出し側（ポリシー）」だけ完成していて、「書き込み側（変数セット）」はまだ無い。

| 部品 | 状態 |
|---|---|
| RLS ポリシー（`current_setting` 参照） | 済 `0003_rls_policies.sql` |
| JWT 検証 | 済 `Program.cs`（JwtBearer 設定） |
| テナント解決ミドルウェア（JWT → user_tenants 照合） | 未実装 |
| `SET LOCAL` 発行（`TenantConnectionInterceptor`） | 未実装（`Program.cs` にコメントで予告のみ。`AddDbContext` に `AddInterceptors` 未接続） |

つまり今アプリから接続すると `app.tenant_id` 未設定 → 全テーブル 0 行になる。これは漏洩側ではなく**フェイルセーフ側に倒れている**正常な途中状態。残作業は Sprint 1 Day2-4 の interceptor 実装。
