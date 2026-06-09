# 04. セキュリティとマルチテナント分離

> **採用構成はマネージドサービス前提**（OIDC プロバイダ + Secret Manager + マネージド Postgres: Cloud SQL / RDS）。
> Node.js + TypeScript の API サーバが Postgres に**直接接続**してアプリロジックを動かす。OIDC プロバイダはトークン発行のみを担い、DB アクセスのゲートウェイは経由しない。

## 3 層の防御

| 層 | 仕組み | 役割 |
|---|---|---|
| **認証** | OIDC プロバイダ（JWT） | 誰が来たか確認 |
| **認可** | `user_tenants` テーブル + JWT クレーム照合 | このユーザーはどのテナントを名乗っていいか |
| **データ分離** | Row Level Security (RLS) + `current_setting('app.tenant_id')` | アプリのフィルタ漏れを DB レベルで遮断 |

各層は独立に効く。1 層が破れても残り 2 層で防ぐ「深層防御」が前提。

## マルチテナント分離方式: RLS 一択

### Schema-per-tenant を採用しなかった理由

- 1000 テナント運用には 1000 schema 管理が必要、現実的でない
- 多 schema 運用はマネージド Postgres でも管理コストが跳ね上がる
- マイグレーションがテナント数倍になる

### RLS のしくみ（直接接続版）

全テーブルに `tenant_id` 列を持たせ、ポリシーは Postgres のセッション変数 `app.tenant_id` を参照する。

```sql
ALTER TABLE knowledge_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON knowledge_entries
  USING       (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK  (tenant_id = current_setting('app.tenant_id', true)::uuid);
```

- `app.tenant_id` は Node API が**リクエスト開始時に `SET LOCAL app.tenant_id = ...` で流す**（後述）
- `USING` で SELECT/UPDATE/DELETE を、`WITH CHECK` で INSERT/UPDATE の書き込みも防ぐ
- アプリ側で `WHERE tenant_id = ?` を書き忘れても DB が漏洩を防ぐ
- `current_setting(..., true)` の第二引数（missing_ok）で、セッション変数未設定時は例外ではなく NULL → 空集合（フェイルセーフ）になる

#### なぜ JWT クレームを DB 側で参照しないか

DB 側で JWT クレームを直接読むポリシー（`auth.uid()` 相当）は、REST ゲートウェイが JWT を解釈してセッションに値を注入する構成でないと機能しない。本プロジェクトのように **Node API が Postgres へ直接接続する構成では、DB 側で JWT クレームを参照できない**。

代わりに、テナント解決（JWT → `user_tenants` 照合 → 当該リクエストのテナント ID 確定）を**アプリ層で完結**させ、確定した `tenant_id` だけをセッション変数に流す方式に統一する。RLS は最終防衛線、認可ロジックは Node API 側、と責務を分ける。

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

Node API の接続設定（`pg` / node-postgres）は `portfolio_app` を使う。マイグレーションは別接続設定（`portfolio_owner`）から実行する運用。なお `portfolio_owner` はテーブル所有者として RLS をすり抜けうるため、全テーブルに `FORCE ROW LEVEL SECURITY` を設定して owner にも RLS を強制する。

## 認証フロー

```
このチェックは毎回やる
[ユーザー]
   │ OIDC プロバイダでサインイン
   │
   ↓ JWT 発行（sub=user_id, exp など）
   │
[Node.js + TypeScript API（NestJS / Express）]
   │ ① JWKS で署名検証（OIDC プロバイダの公開鍵）
   │ ② JWT クレームから sub（OIDC subject）を抽出
   │ ③ users を oidc_sub で upsert（JIT プロビジョニング）して内部 user_id を得て、user_tenants を JOIN して所属テナント一覧を取得
   │ ④ URL `/t/{slug}/chat` の slug を tenants.slug と照合
   │    所属していなければ 403
   │ ⑤ 確定した tenant_id をリクエストコンテキスト（AsyncLocalStorage 等）に保持
   │
   ↓
[データ層フック: リクエスト単位のトランザクション先頭]
   │ ⑥ トランザクション開始直後に
   │    SET LOCAL app.tenant_id = '<解決した uuid>';
   │    SET LOCAL app.user_id   = '<内部 users.id (uuid)>';
   │    を発行（必ず同一トランザクション内で流す）
  （SET LOCAL = このトランザクション中だけ有効な設定値を app.tenant_id にセットする）
   │
[Postgres: portfolio_app ロールで接続]
   │ ⑦ RLS ポリシーが current_setting('app.tenant_id') を参照し
   │    他テナント行を物理的に弾く
```

### `SET LOCAL` の発行ポイント

- **リクエスト単位でトランザクションを張り、その先頭で `SET LOCAL` を発行する**のが本筋
  （`pg` のコネクションを borrow → `BEGIN` → `SET LOCAL` → クエリ群、という流れを 1 つのデータ層フックに集約する）
- `SET LOCAL` は**必ず同一トランザクション内**で流す。トランザクション外で発行すると設定が乗らないため、フック側でトランザクション境界を強制する
- `SET LOCAL` はトランザクション終了時に自動リセットされるので、別テナント用のリクエストが後続でプールから同じ接続を borrow しても安全

### 「OIDC を使うが DB は直接接続」の整理

- 認証は汎用 OIDC プロバイダ（例: Identity Platform / Cognito / Auth0）に委譲し、JWKS による署名検証・パスワードハッシュ・メール認証・OAuth プロバイダ連携などはタダ乗りできる
- ただし DB アクセス側は Node API の直接接続に統一し、DB 側で JWT クレームを参照するパターンには乗らない
- 「認証は OIDC に委ねるが、DB は直接接続でアプリ層がテナントを解決する」というハイブリッド構成

## 秘匿情報の保管: Secret Manager

API キー（Redmine API Key、GitHub PAT、Gemini API Key など）は **平文で `destinations.config` に置かない**。

### しくみ

- シークレットは Secret Manager（AWS Secrets Manager / GCP Secret Manager）に保管する
- DB には実体ではなく**参照（リソース名 + バージョン）だけ**を持たせる
- 復号・取得は DB 関数ではなく**アプリ層が IAM 権限で実行**する

### スキーマ参照

`destinations.secret_ref text` で Secret Manager のシークレット（リソース名 / バージョン）を参照:

```sql
-- 起票時の API キー取得（DB は参照文字列のみを返す）
SELECT secret_ref
  FROM destinations
 WHERE id = $1;
-- 実体は Node API が secret_ref を使い、IAM 権限で Secret Manager から取得・復号する
```

テナント越境の読出し防止は二段で担保する: ①`secret_ref` を含む `destinations` 行は RLS で保護され、現テナントのセッション変数経由でしか取得できない、②アプリ層は「解決した destination 行に紐づく `secret_ref`」しか Secret Manager へ問い合わせない、というチョークポイントを置く。

### 面接で語る点

> 「マルチテナント環境で API キー等を平文保管するのは情報漏洩リスクが高い。Secret Manager に暗号化保管し、DB には参照（`secret_ref`）だけを置く。復号はアプリ層が IAM 権限で行い、参照元の `destinations` 行は RLS 保護下にあるため、現テナントの destination 経由でしか辿れない。RLS とアプリ層チェックで二重防御」

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
ロールは `user_tenants.role` 列で表現し、API 側はミドルウェアの認可ガード（`TenantAdmin` ポリシー相当）で分岐する。

## Elasticsearch のテナント分離

全文検索を Elasticsearch（ES）に寄せる場合、**ES には RLS が無い**。テナント分離は DB と同じ「フィルタ忘れ＝漏洩」の構造になるため、検索層で強制する。

設計:

- **単一共有インデックス + `tenant_id` フィルタ**を採用する。index-per-tenant は採用しない（schema-per-tenant を採らないのと同じ理由: インデックス数がテナント数倍になり管理不能）
- 全 ES クエリに `filter: { term: { tenant_id } }` を**必須注入**する。検索層のチョークポイント（1 関数）に集約し、呼び出し側が直接 ES を叩く経路を作らない
- `routing` も `tenant_id` を使い、シャード局所性とフィルタを一致させる
- フィルタ忘れ＝即漏洩なので、フィルタ注入を担う 1 関数に対してテナント分離テストを書く（[13_testing_strategy.md](13_testing_strategy.md) の ES テナント分離テストに接続）

```ts
// 検索層の唯一の入口。ここを通さず ES を叩かせない
function tenantScopedQuery(tenantId: string, query: QueryDsl): SearchRequest {
  return {
    index: "knowledge",
    routing: tenantId,
    query: {
      bool: {
        filter: [{ term: { tenant_id: tenantId } }],
        must: [query],
      },
    },
  };
}
```

匿名ウィジェット経由の ES 検索も同様に、公開鍵検証で解決したテナント ID を `tenant_id` フィルタとして強制注入する（`app.widget_tenant_id` で解決したテナントを ES フィルタにも渡す）。ログイン経路と匿名経路でフィルタ注入関数を共有し、どちらも `tenant_id` 必須を満たす。

## RLS のテスト戦略

ポリシーバグはサイレント漏洩につながる。**E2E テストで明示確認**:

1. テナント A のユーザー作成、テナント A のナレッジを作成
2. テナント B のユーザー作成、テナント B のナレッジを作成
3. テナント A ユーザーでログイン → テナント B のナレッジが見えないことを確認
4. SELECT / INSERT / UPDATE / DELETE すべてに対してテスト
5. 加えて **`SET LOCAL app.tenant_id` を発行しない状態で接続したときも全テーブルが空に見える** ことを確認（フェイルセーフ検証）

実装は testcontainers（Node）で本物の Postgres を立て、`portfolio_app` で接続して検証する。
ケース定義は人間が決め（漏れたら漏洩）、テストコード自体は AI 委譲で良い。E2E 全体の位置づけは [13_testing_strategy.md](13_testing_strategy.md) を参照。

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

Node API 側で公開鍵検証後 `SET LOCAL app.widget_tenant_id = ?` でテナント ID をセットする。`app.tenant_id` と `app.widget_tenant_id` を別変数にしておくと、ログイン済みユーザーと匿名ウィジェットの混線が起きない。

> ウィジェット実装自体は Phase 2 送り。MVP では `tenant_public_keys` テーブルとポリシーの骨格だけ用意する。

## マネージドサービス前提とセルフホストへの寄せ方

本ドキュメントはマネージドサービス（Cloud SQL / RDS + Identity Platform 等の OIDC + Secret Manager）を前提に書く。AWS / GCP のどちらでも成立し、Docker / Kubernetes で可搬。

セルフホスト（自前 Postgres / 自前 OpenSearch）へ寄せる場合に増える運用を Phase 2 課題として整理しておく:

- OIDC プロバイダ → 自前の認証基盤（または OSS の OIDC サーバ）を運用し、JWKS のローテーションを自前で回す
- Secret Manager → 自前のシークレット管理（KMS + 暗号化保管、または OSS の Vault 系）を構築・運用
- マネージド検索 → OpenSearch を自前運用（ノード管理・スナップショット・アップグレード）

これらの自前運用はコア機能の実装時間を奪うため、MVP ではマネージドに倒す。採用面接では「セルフホストも検討したが、認証 / シークレット / 検索基盤の自前運用は採用訴求にならず、コア機能の実装時間を奪うためマネージドサービスに倒した」と語れる材料にする。
