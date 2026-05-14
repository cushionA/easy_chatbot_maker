# 04. セキュリティとマルチテナント分離

## 3層の防御

| 層 | 仕組み | 役割 |
|---|---|---|
| **認証** | Supabase Auth（JWT） | 誰が来たか確認 |
| **認可** | `user_tenants` テーブル + JWT クレーム | このユーザーはどのテナントに属するか |
| **データ分離** | Row Level Security (RLS) | DB レベルで他テナントの行を見せない |

## マルチテナント分離方式：RLS 一択

### Schema-per-tenant を採用しなかった理由

- 1000テナント運用には1000 schema 管理が必要、現実的でない
- 無料枠（Supabase Free）では多 schema 不可
- マイグレーションがテナント数倍になる

### RLS のしくみ

各テーブルに `tenant_id` カラム。ポリシーで「ログイン中ユーザーが属するテナントの行だけ見える」を DB が保証：

```sql
ALTER TABLE knowledge_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON knowledge_entries
  USING (tenant_id IN (
    SELECT tenant_id FROM user_tenants
    WHERE user_id = auth.uid()
  ));
```

- `auth.uid()` は Supabase Auth が JWT から自動セット
- アプリ側で `WHERE tenant_id = ?` を書き忘れても DB が防ぐ
- INSERT/UPDATE にも `WITH CHECK` 句で同じポリシー適用

### 適用範囲

| テーブル | ポリシー |
|---|---|
| `tenants` | 所属テナントのみ可視 |
| `user_tenants` | 自分のレコードのみ可視 |
| `categories` / `validation_rules` / `field_definitions` / `knowledge_entries` | テナント分離 |
| `destinations` / `inquiries` / `unclassified_queue` | テナント分離 |

実SQL は [03_db_schema.md](03_db_schema.md) を参照。

## 認証フロー

```
[ユーザー]
   │ Supabase Auth でサインイン
   │
   ↓ JWT 発行（sub=user_id を含む）
   │
[Blazor Server]
   │ JWT 検証 → 認証成功
   │
   │ user_tenants 参照
   │ ↓
   │ このユーザーの所属テナント一覧
   │
   │ URL `/t/{slug}/chat` の slug と照合
   │ → 当該テナントに所属していなければ 403
   │
[テナントスコープでDBアクセス]
   │ Supabase RLS が自動で他テナント行を除外
```

`auth.uid()` は Supabase Auth の組み込み関数。アプリ側で JWT パースする必要はない。

## 秘匿情報の保管：Supabase Vault

API キー（Redmine API Key、GitHub PAT 等）は **平文で `destinations.config` に置かない**。

### しくみ

- Supabase Vault は pgsodium ベースの暗号化拡張
- `vault.secrets` テーブルに暗号化保管、`vault.decrypted_secrets` ビューで復号アクセス
- アクセス権限は role でコントロール

### スキーマ参照

`destinations.secret_vault_id uuid` で Vault レコードを参照：

```sql
-- 起票時の API キー取得（admin role でのみ可能）
SELECT decrypted_secret
  FROM vault.decrypted_secrets
 WHERE id = (SELECT secret_vault_id FROM destinations WHERE id = $1);
```

### 面接で語る点

> 「マルチテナント環境で API キー等を平文保管するのは情報漏洩リスクが高い。pgsodium ベースの Supabase Vault でテナントごとに暗号化保管し、復号は専用ロールに限定した。RLS と組合せて二重防御」

## URL 設計

`/t/{slug}/chat` 形式。

- `slug` は推測可能だが、アクセスには認証が必須なので問題なし
- サブドメイン方式（`acme.app.example.com`）は DNS 設定が面倒で MVP には過剰
- UUID 直接露出はユーザビリティ最悪

## ユーザーロール

2階層に絞る：

| ロール | 権限 |
|---|---|
| `admin` | マスタ編集、destination 設定、未分類キューレビュー、ユーザー追加 |
| `member` | 問い合わせ（チャット）のみ |

将来 `owner` / `viewer` を増やす余地はあるが、MVP では2階層で十分。

## RLS のテスト戦略

ポリシーバグはサイレント漏洩につながる。**E2E テストで明示確認**：

1. テナント A のユーザー作成、テナント A のナレッジを作成
2. テナント B のユーザー作成、テナント B のナレッジを作成
3. テナント A ユーザーでログイン → テナント B のナレッジが見えないことを確認
4. SELECT/INSERT/UPDATE/DELETE すべてに対してテスト

これは AI に書かせる範囲だが、**テスト項目自体は座布団さんが定義**する（漏れたら漏洩）。

面接で語る：

> 「RLS ポリシーは書き間違うと漏洩につながるため、テナント間で他テナントのデータが SELECT/INSERT/UPDATE/DELETE のいずれでも見えないことを E2E で明示テストした」

## 埋め込みウィジェット経由のアクセス

`embed.js` ウィジェットは **匿名アクセス**（テナントの自社サイト訪問者）。

設計：

- `tenant_public_keys` テーブルに公開鍵を保管
- リクエストヘッダーで公開鍵検証
- `allowed_origins` で CORS 制限
- `rate_limit_rpm` で過剰利用防止
- 認証不要だが、書き込み権限は制限（読み取り＋分類検索＋未分類キュー登録のみ）

公開鍵経由のアクセスは別 RLS ポリシーで扱う：

```sql
CREATE POLICY public_widget_read ON knowledge_entries
  FOR SELECT
  USING (
    tenant_id = current_setting('app.widget_tenant_id', true)::uuid
  );
```

アプリ側で公開鍵検証後 `SET LOCAL app.widget_tenant_id = ?` でテナント ID をセット。
