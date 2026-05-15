# Sprint 1 実装計画（3 日分）

> 想定読者: 駆け出し Web エンジニアの自分。AI（先輩）にレビューや一次実装を頼みながら進める。
> 期間: 2026-05-17 〜 2026-05-19（3 日）
> ゴール: **マルチテナント分離（認証 + RLS）が動く土台**を完成させ、最初の CRUD 画面 1 枚を出す。
> Done の定義は各日末尾のチェックリスト。

## 全体マップ

| 日 | テーマ | 主成果物 |
|---|---|---|
| Day 1 | DB の防御層を立てる | 詳細: [`sprint1/day1.md`](sprint1/day1.md) — Supabase プロジェクト、`0002_rls_roles.sql`、`0003_rls_policies.sql`（1 テーブル分のお手本） |
| Day 2 | アプリ ↔ DB の認証/テナント導管 | 詳細: [`sprint1/day2.md`](sprint1/day2.md) — JwtBearer、テナント解決ミドルウェア、`DbConnectionInterceptor`、残りテーブルの RLS、Testcontainers での漏洩テスト |
| Day 3 | 最初の画面と CRUD | 詳細: [`sprint1/day3.md`](sprint1/day3.md) — Category CRUD 3 ページ、Excel 取込スクリプト雛形 |

各 day ファイルは、タスクごとに「**目的 / 前提確認 / 手順（コマンド・コード片レベル）/ 完了確認 / 詰まったら / AI 依頼テンプレ**」の節を持つ作業指示書。明日朝は [`sprint1/day1.md`](sprint1/day1.md) を開いて着手する。

「自分で書く（説明責任が重い箇所）」と「AI に委譲（仕様だけ握る）」の区分は [`09_task_split.md`](09_task_split.md) を継承する。各タスクに **[自分]** / **[AI]** を明記する。

---

## Day 1 — DB の防御層

> 「アプリのフィルタ漏れを DB レベルで遮断する」を物理的に成立させる日。最初の 1 テーブルを自分の手で RLS 化し、残りは Day 2 で AI に複製させる。

### 1-1. Supabase プロジェクト作成 [自分]

- **やること**
  - Supabase ダッシュボードで新規プロジェクトを作成（リージョンは Tokyo/AP-Northeast-1）
  - Project URL / `anon` key / `service_role` key / JWKS endpoint URL を控える
  - DB 接続文字列（Direct connection、port 5432）を控える
  - `auth.users` テーブルが存在することを確認（後で `user_tenants.user_id` の FK にする）
- **Done**
  - `.env.local`（git ignore 対象）に `SUPABASE_URL` / `SUPABASE_JWKS_URL` / `SUPABASE_DB_URL_OWNER` を書き込んだ
  - JWKS URL を `curl` で叩いて JSON が返ることを確認
- **参照**: [`04_security_multitenant.md:80-105`](04_security_multitenant.md)

### 1-2. `0002_rls_roles.sql` を書く [自分]

- **やること**
  - `portfolio_owner`（スキーマ所有）と `portfolio_app`（`NOBYPASSRLS`）の 2 ロールを作る migration を `infra/db/migrations/0002_rls_roles.sql` に追加
  - 既存スキーマの所有権を `portfolio_owner` に移す `REASSIGN OWNED BY`
  - `portfolio_app` に `CONNECT` / `USAGE` / `SELECT,INSERT,UPDATE,DELETE` を `GRANT`
  - `ALTER DEFAULT PRIVILEGES` で将来テーブルにも自動付与
- **自分で書く理由**: GRANT の粒度を誤ると RLS が無力化される。面接で「なぜ 2 ロール構成か」を語る。
- **Done**
  - ローカル Postgres（docker compose）に流して `\du` で 2 ロール確認
  - `SELECT rolbypassrls FROM pg_roles WHERE rolname='portfolio_app'` が `f` を返す
- **参照**: [`04_security_multitenant.md:58-78`](04_security_multitenant.md)

### 1-3. `knowledge_entries` 1 テーブルだけ RLS のお手本を書く [自分]

- **やること**
  - `infra/db/migrations/0003_rls_policies.sql` を新規作成
  - **`knowledge_entries` だけ**に対して以下を書く（残テーブルは Day 2 で AI に複製させる）:
    - `ALTER TABLE knowledge_entries ENABLE ROW LEVEL SECURITY;`
    - `FORCE ROW LEVEL SECURITY;`（owner にも RLS を効かせる）
    - `CREATE POLICY tenant_isolation ON knowledge_entries USING (tenant_id = current_setting('app.tenant_id', true)::uuid) WITH CHECK (...);`
    - 第二引数 `true` を付けて、セッション変数未設定時に NULL → 空集合になるフェイルセーフ動作を確認
- **自分で書く理由**: ここが**漏洩したらアウトな箇所**。残り 9 テーブルは AI で複製可能。
- **Done**
  - 手動で 2 行（テナント A / B）入れる → `SET LOCAL app.tenant_id = 'テナントAのuuid'` の後 SELECT すると A の行だけ見える
  - `SET LOCAL` 未発行で SELECT すると 0 行返る（フェイルセーフ）
- **参照**: [`04_security_multitenant.md:24-44`](04_security_multitenant.md), [`0001_schema.sql:242-254`](../infra/db/migrations/0001_schema.sql)

### Day 1 終了チェックリスト

- [ ] Supabase プロジェクトが作成され、接続情報が `.env.local` に揃っている
- [ ] `0002_rls_roles.sql` が動き、`portfolio_app` が `NOBYPASSRLS`
- [ ] `0003_rls_policies.sql`（`knowledge_entries` 分のみ）が動き、手動 SELECT でテナント分離が確認できた
- [ ] `.env.local` を `.gitignore` に追加した（または既に入っているか確認）

---

## Day 2 — アプリ ↔ DB の認証/テナント導管

> 「JWT を受け取ってからセッション変数に流すまで」の配管を全部つなぐ日。Day 1 のお手本ポリシーを全テーブルに展開する作業は AI に投げる。

### 2-1. RLS ポリシーを残テーブルに展開 [AI]

- **依頼内容**: 「`0003_rls_policies.sql` に書いた `knowledge_entries` と同じパターンで、`categories` / `field_definitions` / `validation_rules` / `destinations` / `inquiries` / `unclassified_queue` / `tenant_public_keys` にも `tenant_isolation` ポリシーを追加して」
- **特殊ケース**（自分で指定する）:
  - `tenants`: `SELECT` のみ別ポリシー（自分の所属テナントだけ可視）→ `user_tenants` を参照
  - `user_tenants`: 自分の `user_id` の行のみ可視（`current_setting('app.user_id')::uuid` を使う）
- **Done**: ローカル DB で 8 テーブル全部に対し、Day 1 と同じ手動確認をスポットチェック（2-3 テーブル）

### 2-2. `Program.cs` に `AddJwtBearer` を追加 [自分（雛形は AI）]

- **やること**
  - `Microsoft.AspNetCore.Authentication.JwtBearer` の `AddJwtBearer` を、Supabase JWKS URL を指定して登録
  - `Authority` / `Audience` / `TokenValidationParameters.ValidateIssuerSigningKey` を設定
  - `app.UseAuthentication(); app.UseAuthorization();` を `app.UseAntiforgery();` の前に挿入
- **自分で書く理由**: トークン検証は認証の中核、後から「なんとなく動いてる」になりやすい。
- **Done**
  - 期限切れトークン → 401
  - 改ざんしたトークン → 401
  - 正しいトークン → `HttpContext.User.Claims` に `sub` が入っている
- **参照**: [`04_security_multitenant.md:82-105`](04_security_multitenant.md)

### 2-3. テナント解決ミドルウェア [自分]

- **やること**
  - 新規 `backend/Portfolio.Web/Middleware/TenantResolutionMiddleware.cs` を追加
  - URL `/t/{slug}/...` の `slug` を抽出 → `tenants` から `id` を引く → `user_tenants` で当該ユーザーの所属を検証
  - 検証 OK なら `HttpContext.Items["TenantId"]` と `["UserId"]` に格納
  - 不所属なら 403
- **自分で書く理由**: 認可ロジックの中心。誤ると別テナントに侵入される。
- **Done**
  - 単体テストで以下 4 ケース: 所属 OK / 別テナント slug / 認証なし / slug 存在しない

### 2-4. `DbConnectionInterceptor` で `SET LOCAL` 発行 [自分]

- **やること**
  - 新規 `backend/Portfolio.Web/Data/TenantConnectionInterceptor.cs` を追加
  - `DbConnectionInterceptor.ConnectionOpenedAsync` をオーバーライドし、`HttpContext.Items` から `TenantId` / `UserId` を取って `SET LOCAL app.tenant_id = '...'; SET LOCAL app.user_id = '...';` を発行
  - `IHttpContextAccessor` 経由で取得（DI 登録も追加）
  - `AppDbContext` の `OnConfiguring` で `.AddInterceptors(...)` 登録
- **自分で書く理由**: RLS が機能する/しないを決める単一のポイント。
- **Done**
  - 簡単な統合テストで「ログイン後に `knowledge_entries` を SELECT すると自分のテナント分しか取れない」を確認

### 2-5. RLS 漏洩テスト（Testcontainers）[AI 一次実装 → 自分レビュー]

- **依頼内容**: 「`Testcontainers.PostgreSql` で本物の Postgres を立ち上げ、テナント A / B のデータを作成して、A のセッション変数で接続 → B のデータが見えないことを SELECT/INSERT/UPDATE/DELETE すべてで検証するテストを `Portfolio.Web.Tests/RlsIsolationTests.cs` に書いて」
- **自分の責務**: ケース定義（漏れたらアウトな箇所を列挙）と、テストが green なのが偶然でないこと（一度わざとポリシーを外して red になることを確認）
- **Done**
  - 4 操作 × 2 方向（A→B, B→A）の 8 ケースが green
  - 「セッション変数未設定時に空集合」のフェイルセーフケースも入っている

### Day 2 終了チェックリスト

- [ ] 全テーブルに RLS ポリシーが当たっている
- [ ] 期限切れ/改ざん JWT が 401 で弾かれる
- [ ] 別テナントの slug を踏むと 403
- [ ] `SET LOCAL` が毎リクエスト発行されているのを Postgres ログ or テストで確認した
- [ ] Testcontainers の RLS テストが green、かつ「ポリシー外すと red」も一度確認した

---

## Day 3 — 最初の画面と CRUD

> 「最初の 1 個」を自分の手で書く日。Category の 3 ページ（一覧/作成/編集）を **Blazor `EditForm` のお手本**として作る。Knowledge / FieldDefinition は同パターンで AI が複製できるようになる。

### 3-1. ルーティングを `/t/{slug}/...` 形式に整える [自分]

- **やること**
  - `Components/Routes.razor` を確認し、トップを `/t/{slug}/chat` に向ける
  - 既存 `Home.razor` は `/t/{slug}/_debug/embedding` に退避（Embedding 動作確認用に残す）
  - `Components/Layout/MainLayout.razor` に sidebar 雛形（ナレッジ / カテゴリ / 設定 のリンク、`slug` をパラメータで受ける）
- **自分で書く理由**: URL 設計はサービスの顔。

### 3-2. Category 一覧ページ `/t/{slug}/categories` [自分]

- **やること**
  - `Components/Pages/Categories/Index.razor` を新規作成
  - `AppDbContext.Categories` から SELECT して `<table>` で表示（`Name` / `Description` / 作成日時 / 編集リンク）
  - `[Authorize]` を付ける
- **Done**
  - 認証なしでアクセス → ログイン誘導
  - 自テナントのカテゴリのみ表示される（RLS が効いていることを目視確認）

### 3-3. Category 作成ページ `/t/{slug}/categories/new` [自分]

- **やること**
  - `Components/Pages/Categories/Create.razor` を `EditForm` + `DataAnnotationsValidator` で実装
  - フィールド: `Name`（必須、max 100）、`Description`（任意、max 500）、`DisplayOrder`（int）
  - 保存後は `/t/{slug}/categories` にリダイレクト
- **自分で書く理由**: これが **「Blazor `EditForm` の最初のお手本」**。Knowledge / FieldDefinition は AI が同パターンで作る。
- **Done**: 作成 → 一覧に反映、空 Name でバリデーション赤字

### 3-4. Category 編集ページ `/t/{slug}/categories/{id:guid}/edit` [AI]

- **依頼内容**: 「`Create.razor` と同じパターンで、`id` で既存レコードをロード → 編集 → 保存できる `Edit.razor` を書いて」
- **自分の責務**: 出来たコードをレビューし、`Update` 時の `RowVersion` 競合（楽観ロック）が考慮されているか確認

### 3-5. Excel 取込スクリプト雛形 [AI 一次実装 → 自分レビュー]

- **依頼内容**: 「既存 Streamlit 版の `data.xlsx`（[`design/10_existing_streamlit.md`](10_existing_streamlit.md) 参照）を読み込んで、デモテナント 1 つと、その配下の Category / KnowledgeEntry を一括 INSERT する C# コンソールアプリを `backend/Portfolio.Tools.Seed/` に追加して」
- **自分の責務**:
  - デモテナント名・slug を決める（採用面接で見せたい題材）
  - INSERT 時に Embedding API を呼んで `embedding` 列を埋める指示まで含める
  - `passage:` プレフィクス（Day N 以降の対応）を将来差し込めるよう、Embedding 呼び出しを 1 関数にまとめる
- **Done**: `dotnet run --project backend/Portfolio.Tools.Seed -- --file demo/data.xlsx` でデモテナントとデータが作られ、画面で確認できる

### Day 3 終了チェックリスト

- [ ] `/t/{slug}/categories` で自テナントのカテゴリが一覧表示される
- [ ] 作成 → 編集 → 一覧反映 のフローが回る
- [ ] Excel 取込でデモテナントが作成され、画面で見える
- [ ] Knowledge / FieldDefinition の CRUD は **同パターンで AI に複製依頼できる状態**になっている（= Sprint 1 の残りが「テンプレ展開」だけになる）

---

## 進めるときの 1 サイクル

各タスクで [`09_task_split.md:107`](09_task_split.md) のワークフローに従う:

1. 該当する `design/` ファイルを読む（仕様の正）
2. 仕様を 5〜10 行の箇条書きにする（**この明文化が一番大事**）
3. インターフェース・型・SQL 雛形を自分で書く（[自分] タスクの中身）
4. AI に「この仕様で実装して」と依頼（[AI] タスク）
5. 出来たコードをレビューし、テストも AI に依頼
6. ローカルで動作確認、必要なら再依頼
7. PR にまとめてマージ（1 タスク 1 PR を基本に）

## つまづいたらここを見る

| 症状 | 見るべき場所 |
|---|---|
| RLS が効かない | [`04_security_multitenant.md:58-78`](04_security_multitenant.md)（`BYPASSRLS` 落とし穴） |
| JWT 検証が通らない | [`04_security_multitenant.md:82-105`](04_security_multitenant.md) |
| EF Core の vector 列でビルド失敗 | [`reviews/04_current_deliverable_review.md:88-115`](../reviews/04_current_deliverable_review.md)（NuGet 問題） |
| Embedding が遅い・落ちる | [`reviews/04_current_deliverable_review.md:170-189`](../reviews/04_current_deliverable_review.md)（タイムアウト/初回 DL） |
| query/passage の使い分け | [`embedding/CLAUDE.md`](../embedding/CLAUDE.md) と [`reviews/04_current_deliverable_review.md:161-168`](../reviews/04_current_deliverable_review.md) |

## Sprint 1 のあとに残るタスク

Day 3 まで終わると、Sprint 1 の 7 項目（[`README.md:64`](README.md)）のうち 1〜6 がカバーされる。残るのは:

- **Knowledge / FieldDefinition / ValidationRule の CRUD**（テンプレ展開、AI 全部委譲）
- **Vault 連携（SECURITY DEFINER 関数）** — Phase 2 だが Day 4 に着手しても良い
- **分類フロー本体（[`05_search_classification.md`](05_search_classification.md)）** — Sprint 2 の主題
