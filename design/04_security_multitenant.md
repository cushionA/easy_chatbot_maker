# 04. セキュリティとマルチテナント分離

> **採用構成は Plan B 確定**（Supabase Auth + Supabase Vault + Supabase Postgres）。
> ASP.NET Core が Supabase Postgres に**直接接続**してアプリロジックを動かす。Supabase の PostgREST/REST API ゲートウェイは経由しない。

## 3 層の防御

| 層 | 仕組み | 役割 |
|---|---|---|
| **認証** | Supabase Auth（JWT） | 誰が来たか確認 |
| **認可** | `user_tenants` テーブル + JWT クレーム照合 | このユーザーはどのテナントを名乗っていいか |
| **データ分離** | Row Level Security (RLS) + `current_setting('app.tenant_id')` | アプリのフィルタ漏れを DB レベルで遮断 |

各層は独立に効く。1 層が破れても残り 2 層で防ぐ「深層防御」が前提。

## マルチテナント分離方式: RLS 一択

### Schema-per-tenant を採用しなかった理由

- 1000 テナント運用には 1000 schema 管理が必要、現実的でない
- 無料枠（Supabase Free）では多 schema 不可
- マイグレーションがテナント数倍になる

### RLS のしくみ（直接接続版）

全テーブルに `tenant_id` 列を持たせ、ポリシーは Postgres のセッション変数 `app.tenant_id` を参照する。

```sql
ALTER TABLE knowledge_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON knowledge_entries
  USING       (tenant_id = current_setting('app.tenant_id')::uuid)
  WITH CHECK  (tenant_id = current_setting('app.tenant_id')::uuid);
```

- `app.tenant_id` は ASP.NET Core が**リクエスト開始時に `SET LOCAL app.tenant_id = ...` で流す**（後述）
- `USING` で SELECT/UPDATE/DELETE を、`WITH CHECK` で INSERT/UPDATE の書き込みも防ぐ
- アプリ側で `WHERE tenant_id = ?` を書き忘れても DB が漏洩を防ぐ

#### なぜ `auth.uid()` ベースにしないか

Supabase 標準のポリシー例は `auth.uid()` を使うが、これは **PostgREST 経由でアクセスしたときに JWT クレームから自動で値が入る** 仕組みに依存する。本プロジェクトのように **ASP.NET Core が Postgres へ直接接続する構成では `auth.uid()` は常に NULL** になり機能しない。

代わりに、テナント解決（JWT → `user_tenants` 照合 → 当該リクエストのテナント ID 確定）を**アプリ層で完結**させ、結果の `tenant_id` だけをセッション変数に流す方式に統一する。RLS は最終防衛線、認可ロジックは ASP.NET Core 側、と責務を分ける。

### 適用範囲

| テーブル | ポリシー |
|---|---|
| `tenants` | 自分が所属する `tenant_id` のみ可視（`SELECT` ベースの別ポリシー） |
| `user_tenants` | 自分のレコードのみ可視 |
| `categories` / `validation_rules` / `field_definitions` / `knowledge_entries` | テナント分離 |
| `destinations` / `inquiries` / `unclassified_queue` | テナント分離 |
| `tenant_public_keys` | テナント分離（admin のみ書込可は別途アプリ層で制御） |

実 SQL は [03_db_schema.md](03_db_schema.md) を参照。

## 専用 DB ロールの分離（`BYPASSRLS` 回避）

定番の落とし穴: **スキーマ所有者ロールは暗黙の `BYPASSRLS` 属性を持つ**ことが多く、そのロールでアプリが接続すると `ENABLE ROW LEVEL SECURITY` してもポリシーが効かない。

対策として 2 ロール構成にする:

| ロール | 用途 | 属性 |
|---|---|---|
| `portfolio_owner` | マイグレーション実行・スキーマ変更 | スキーマ所有 |
| `portfolio_app` | アプリ実行時の接続 | **`NOBYPASSRLS`**, 必要な権限のみ GRANT |

```sql
CREATE ROLE portfolio_app NOLOGIN NOBYPASSRLS;
GRANT CONNECT ON DATABASE portfolio TO portfolio_app;
GRANT USAGE ON SCHEMA public TO portfolio_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO portfolio_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO portfolio_app;
```

ASP.NET Core の接続文字列は `portfolio_app` を使う。マイグレーションは別接続文字列（`portfolio_owner`）から実行する運用。

## 認証フロー

```
[ユーザー]
   │ Supabase Auth でサインイン
   │
   ↓ JWT 発行（sub=user_id, exp など）
   │
[Blazor Server / ASP.NET Core]
   │ ① JwtBearer で署名検証（Supabase の JWKS / HS256 シークレット）
   │ ② JWT クレームから user_id を抽出
   │ ③ user_tenants を JOIN → このユーザーの所属テナント一覧を取得
   │ ④ URL `/t/{slug}/chat` の slug を tenants.slug と照合
   │    所属していなければ 403
   │ ⑤ 確定した tenant_id を AsyncLocal / HttpContext.Items に保持
   │
   ↓
[EF Core: SaveChangesInterceptor / Command Interceptor]
   │ ⑥ 接続/コマンド実行直前に
   │    SET LOCAL app.tenant_id = '<解決した uuid>';
   │    を発行
   │
[Postgres: portfolio_app ロールで接続]
   │ ⑦ RLS ポリシーが current_setting('app.tenant_id') を参照し
   │    他テナント行を物理的に弾く
```

### `SET LOCAL` の発行ポイント

- **`DbConnectionInterceptor.ConnectionOpenedAsync` で発行する**のが本筋
  （EF Core が接続プールから borrow したタイミングで毎回流れる）
- 補強として `DbCommandInterceptor.ReaderExecutingAsync` でも発行する
  （プール再利用時の取りこぼし防止、トランザクション境界での再セット）
- `SET LOCAL` はトランザクション/セッション終了時に自動リセットされるので、別テナント用の接続が後続でプールから出てきても安全

### 「Supabase Auth を使うのに `auth.uid()` を捨てる」整理

- Auth は Supabase の SDK と JWKS をそのまま利用（パスワードハッシュ・メール認証・OAuth プロバイダなどはタダ乗りできる）
- ただし DB アクセス側は ASP.NET Core 直接接続に統一し、Supabase の RLS 標準パターン（`auth.uid()` ベース）には乗らない
- 「Auth は使うが PostgREST は使わない」というハイブリッド構成

## 秘匿情報の保管: Supabase Vault

API キー（Redmine API Key、GitHub PAT、Gemini API Key など）は **平文で `destinations.config` に置かない**。

### しくみ

- Supabase Vault は pgsodium ベースの暗号化拡張
- `vault.secrets` テーブルに暗号化保管、`vault.decrypted_secrets` ビューで復号アクセス
- 復号はロール権限でコントロール

### スキーマ参照

`destinations.secret_vault_id uuid` で Vault レコードを参照:

```sql
-- 起票時の API キー取得（portfolio_app からは復号権限を付与した別関数経由で呼ぶ）
SELECT decrypted_secret
  FROM vault.decrypted_secrets
 WHERE id = (SELECT secret_vault_id FROM destinations WHERE id = $1);
```

復号 SQL を直接アプリから叩かせず、**SECURITY DEFINER の関数でラップ**して `portfolio_app` に EXECUTE 権限だけ渡すと、テナント越境の Vault 読出しが防げる。

### 面接で語る点

> 「マルチテナント環境で API キー等を平文保管するのは情報漏洩リスクが高い。pgsodium ベースの Supabase Vault でテナントごとに暗号化保管し、復号は SECURITY DEFINER 関数経由に限定。RLS と組合せて二重防御」

## URL 設計

`/t/{slug}/chat` 形式。

- `slug` は推測可能だが、アクセスには認証が必須なので問題なし
- サブドメイン方式（`acme.app.example.com`）は DNS 設定が面倒で MVP には過剰
- UUID 直接露出はユーザビリティ最悪

## ユーザーロール

2 階層に絞る:

| ロール | 権限 |
|---|---|
| `admin` | マスタ編集、destination 設定、未分類キューレビュー、ユーザー追加 |
| `member` | 問い合わせ（チャット）のみ |

将来 `owner` / `viewer` を増やす余地はあるが、MVP では 2 階層で十分。
ロールは `user_tenants.role` 列で表現し、Razor 側は `[Authorize(Policy="TenantAdmin")]` 等のポリシーで分岐する。

## RLS のテスト戦略

ポリシーバグはサイレント漏洩につながる。**E2E テストで明示確認**:

1. テナント A のユーザー作成、テナント A のナレッジを作成
2. テナント B のユーザー作成、テナント B のナレッジを作成
3. テナント A ユーザーでログイン → テナント B のナレッジが見えないことを確認
4. SELECT / INSERT / UPDATE / DELETE すべてに対してテスト
5. 加えて **`SET LOCAL app.tenant_id` を発行しない状態で接続したときも全テーブルが空に見える** ことを確認（フェイルセーフ検証）

実装は `Testcontainers.PostgreSql` で本物の Postgres を立て、`portfolio_app` で接続して検証する。
ケース定義は人間が決め（漏れたら漏洩）、テストコード自体は AI 委譲で良い。

面接で語る:

> 「RLS ポリシーは書き間違うと漏洩につながるため、テナント間で他テナントのデータが SELECT/INSERT/UPDATE/DELETE のいずれでも見えないことを E2E で明示テストした。セッション変数未設定時にも空集合になることを確認する『フェイルセーフ』ケースも入れている」

## 埋め込みウィジェット経由のアクセス

`embed.js` ウィジェットは **匿名アクセス**（テナントの自社サイト訪問者）。

設計:

- `tenant_public_keys` テーブルに公開鍵（ハッシュ）を保管
- リクエストヘッダで公開鍵検証
- `allowed_origins` で CORS 制限
- `rate_limit_rpm` で過剰利用防止
- 認証不要だが、書き込み権限は限定（読み取り＋分類検索＋未分類キュー登録のみ）

公開鍵経由のアクセスは別 RLS ポリシーで扱う。アプリ層で公開鍵検証後、別のセッション変数を立てる:

```sql
CREATE POLICY public_widget_read ON knowledge_entries
  FOR SELECT
  USING (
    tenant_id = current_setting('app.widget_tenant_id', true)::uuid
  );
```

ASP.NET Core 側で公開鍵検証後 `SET LOCAL app.widget_tenant_id = ?` でテナント ID をセットする。`app.tenant_id` と `app.widget_tenant_id` を別変数にしておくと、ログイン済みユーザーと匿名ウィジェットの混線が起きない。

> ウィジェット実装自体は Phase 2 送り。MVP では `tenant_public_keys` テーブルとポリシーの骨格だけ用意する。

## Plan A（Oracle Cloud + 自前 Postgres）について

本ドキュメントは Plan B（Supabase）を前提に書く。Plan A への移行は Phase 2 で語る課題に格下げした:

- Supabase Auth → ASP.NET Core Identity または GitHub OAuth に差替が必要
- Supabase Vault → pgsodium を自前で構築（拡張インストール + キー管理）
- これらの自前実装はコア機能の実装時間を奪うため MVP では追わない

理由は採用面接で「Plan A も検討したが、認証/Vault の自前実装は採用訴求にならず、コア機能の実装時間を奪うため Plan B に倒した」と語れる材料にする。
