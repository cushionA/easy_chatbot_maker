# Sprint 3 Day 3 作業指示書（2026-05-29）

> テーマ: **Vault と UI を結線する**
> 完了時の状態: API キーが Supabase Vault に暗号化保管され、起票時に SECURITY DEFINER 関数経由で復号して `DestinationConfig.SecretValue` に載る。destination の登録/編集 + 接続テストの最小 Blazor UI が動く。起票実行サービスが、成功時 `inquiries.status='created'`、失敗時 `'failed'` + `draft_fields` 保持、成功時 `draft_fields` NULL クリアを行う。
> 推定所要: 6〜8 時間

> 参照の正: [`04_security_multitenant.md:121-146`](../04_security_multitenant.md)（Vault / SECURITY DEFINER）、[`06_destinations.md:146-179`](../06_destinations.md)（失敗時挙動・接続テスト・Vault 参照）。
> 横断ルール: API キーは `appsettings` 禁止・Vault のみ（BYOK、[`CLAUDE.md`](../../CLAUDE.md)）。クライアント由来 tenant id は信頼しない（JWT クレーム / RLS コンテキスト）。

---

## Day3-1. Vault secret 保存/復号の SECURITY DEFINER 関数を書く [自分]

**目的**
API キーを平文で `destinations.config` に置かず、Supabase Vault（pgsodium）に暗号化保管する。`portfolio_app` には Vault テーブルへの直接権限を与えず、**SECURITY DEFINER 関数 2 つ（保存・復号）に EXECUTE 権限だけ**渡す。これがテナント越境の Vault 読出しを防ぐ最終境界（[`04_security_multitenant.md:135-142`](../04_security_multitenant.md)）。

**自分で書く理由**
秘匿情報の境界は漏洩したら一発アウト。`SECURITY DEFINER` は「定義者の権限で動く」危険な仕組みで、`search_path` 固定や引数検証を誤ると権限昇格になる。面接で「pgsodium ベースの Vault で暗号化保管、復号は SECURITY DEFINER 関数経由に限定、RLS と二重防御」と語る要所（[`04_security_multitenant.md:144-146`](../04_security_multitenant.md)）。

**前提確認**
- [ ] Supabase の `vault` 拡張が有効（Supabase は既定で Vault 利用可。`SELECT * FROM vault.secrets LIMIT 0;` が通る）
- [ ] [`04_security_multitenant.md:121-142`](../04_security_multitenant.md) を読んだ
- [ ] `destinations.secret_vault_id`（`uuid`）列が存在（`0001_schema.sql:126`、エンティティ `Destination.SecretVaultId`）

**手順**
1. 新規 migration `infra/db/migrations/0004_vault_functions.sql` を作成（番号は既存の最新+1 に合わせる。`ls infra/db/migrations/` で確認）。
2. **保存関数**（テナント所属チェック付きで Vault に secret を作り、`secret_vault_id` を返す）と **復号関数** を SECURITY DEFINER で定義する骨子:
   ```sql
   -- 保存: 呼び出し側テナントの destination に紐づく secret を Vault に作成/更新し、id を返す。
   -- SECURITY DEFINER だが、引数のテナント整合は current_setting('app.tenant_id') で必ず検証する。
   CREATE OR REPLACE FUNCTION app_set_destination_secret(
       p_destination_id uuid,
       p_secret         text
   ) RETURNS uuid
   LANGUAGE plpgsql
   SECURITY DEFINER
   SET search_path = vault, public      -- search_path 固定（DEFINER の鉄則）
   AS $$
   DECLARE
       v_tenant uuid := current_setting('app.tenant_id', true)::uuid;
       v_secret_id uuid;
   BEGIN
       -- 越境防止: この destination が呼び出しテナントのものか確認
       IF NOT EXISTS (
           SELECT 1 FROM public.destinations
           WHERE id = p_destination_id AND tenant_id = v_tenant
       ) THEN
           RAISE EXCEPTION 'destination not found for current tenant';
       END IF;

       v_secret_id := vault.create_secret(p_secret);   -- pgsodium で暗号化保管
       UPDATE public.destinations
          SET secret_vault_id = v_secret_id
        WHERE id = p_destination_id AND tenant_id = v_tenant;
       RETURN v_secret_id;
   END;
   $$;

   -- 復号: destination id から復号済み API キーを返す。テナント整合を必ず検証。
   CREATE OR REPLACE FUNCTION app_get_destination_secret(
       p_destination_id uuid
   ) RETURNS text
   LANGUAGE plpgsql
   SECURITY DEFINER
   SET search_path = vault, public
   AS $$
   DECLARE
       v_tenant uuid := current_setting('app.tenant_id', true)::uuid;
       v_vault_id uuid;
       v_secret text;
   BEGIN
       SELECT secret_vault_id INTO v_vault_id
         FROM public.destinations
        WHERE id = p_destination_id AND tenant_id = v_tenant;  -- 越境不可
       IF v_vault_id IS NULL THEN
           RAISE EXCEPTION 'no secret for destination';
       END IF;

       SELECT decrypted_secret INTO v_secret
         FROM vault.decrypted_secrets
        WHERE id = v_vault_id;
       RETURN v_secret;
   END;
   $$;

   -- portfolio_app には EXECUTE だけ与える（Vault 表への直接権限は与えない）
   REVOKE ALL ON FUNCTION app_set_destination_secret(uuid, text) FROM public;
   REVOKE ALL ON FUNCTION app_get_destination_secret(uuid)       FROM public;
   GRANT EXECUTE ON FUNCTION app_set_destination_secret(uuid, text) TO portfolio_app;
   GRANT EXECUTE ON FUNCTION app_get_destination_secret(uuid)       TO portfolio_app;
   ```
   - **越境防止の肝**: 関数内で `current_setting('app.tenant_id')` と `destinations.tenant_id` を突合し、別テナントの `destination_id` を渡されても弾く。`SECURITY DEFINER` は RLS をすり抜けうるので、この明示チェックが無いと越境読出しになる。
   - `app.tenant_id` 未設定（`true` で NULL）なら整合チェックに失敗して例外 → フェイルセーフ。
3. owner 接続で流す（`SUPABASE_DB_URL_OWNER`）。Supabase の `vault.create_secret` / `vault.decrypted_secrets` の正確な名称は環境で確認（`\df vault.*`）。差異があれば関数本体を合わせる。

**完了確認**
- [ ] `portfolio_app` 接続で `SET LOCAL app.tenant_id`（自テナント）した上で `app_set_destination_secret` → secret_vault_id が返り `destinations.secret_vault_id` が埋まる
- [ ] 同接続で `app_get_destination_secret` → 元の平文が返る
- [ ] **別テナントの `app.tenant_id` をセットして同 destination の復号を呼ぶ → 例外（越境拒否）**
- [ ] `portfolio_app` から `SELECT * FROM vault.decrypted_secrets` を直接叩くと権限エラー（直接アクセス不可）

**詰まったら**
- `vault.create_secret` が無い → Supabase バージョン差。`SELECT * FROM pg_proc WHERE proname LIKE '%secret%';` で実名確認
- `permission denied for schema vault` → DEFINER 関数の所有者が `vault` にアクセスできる役割（owner）になっているか。関数所有者を `postgres`/owner にする
- 越境チェックが効かない → 関数内で RLS は DEFINER 権限で無効化されうる。**だからこそ手書きの `tenant_id` 突合が必須**。チェック行を消すと越境できてしまうことを一度実演して理解する

**AI 依頼テンプレ**: なし（秘匿境界は自分で書く範囲）

---

## Day3-2. `IDestinationSecretStore`（C# から Vault 関数を呼ぶ薄いラッパ）[自分]

**目的**
Day3-1 の関数 2 つを C# から呼ぶ薄いインターフェースを置く。アプリ側は「Vault を意識せず secret を保存/取得」できる。起票時はここで復号して `DestinationConfig` を組む。

**自分で書く理由**
秘匿情報の取り扱い境界。生 SQL（関数呼出）をどこで・どの DbContext で叩くかは設計判断で、ここに secret がメモリ上で滞留するので「ログに出さない」「保持しない」を自分で担保する。

**前提確認**
- [ ] Day3-1 完了
- [ ] `AppDbContext`（`portfolio_app` 接続・RLS コンテキストあり）から生 SQL を実行できる

**手順**
1. `Portfolio.Web/Services/IDestinationSecretStore.cs`:
   ```csharp
   namespace Portfolio.Web.Services;

   public interface IDestinationSecretStore
   {
       // destination に API キーを Vault 経由で保存し、secret_vault_id を返す
       Task<Guid> SetSecretAsync(Guid destinationId, string secret, CancellationToken ct);

       // destination の API キーを Vault から復号して返す（呼び出し直後だけ保持、ログ厳禁）
       Task<string> GetSecretAsync(Guid destinationId, CancellationToken ct);
   }
   ```
2. 実装 `DestinationSecretStore`（`AppDbContext` 注入。`SET LOCAL app.tenant_id` は既存の `TenantConnectionInterceptor`（Sprint 1 Day2-4）が発行済みなので、関数内の越境チェックがそのまま効く）。**パラメータ化必須**（`backend/CLAUDE.md`、生 SQL でも文字列連結禁止）:
   ```csharp
   // SetSecretAsync:
   //   SELECT app_set_destination_secret({destinationId}, {secret})  ← パラメータバインド
   // GetSecretAsync:
   //   SELECT app_get_destination_secret({destinationId})            ← パラメータバインド
   // Npgsql の FromSqlInterpolated / SqlQuery<T> 等でスカラを取る。
   ```
   - secret は `ILogger` に出さない。例外メッセージにも含めない。
3. `Program.cs` で DI 登録（`AddScoped<IDestinationSecretStore, DestinationSecretStore>()`）。

**完了確認**
- [ ] 統合テスト or 手動: 自テナントで `SetSecretAsync` → `GetSecretAsync` がラウンドトリップする
- [ ] 別テナント文脈で他テナントの destination を `GetSecretAsync` → 例外（Day3-1 の越境チェックが効く）
- [ ] secret がログに出ていない（`LogTo` を一時的に有効化して確認）

**詰まったら**
- スカラ取得が EF Core でやりにくい → `Database.SqlQuery<string>($"SELECT app_get_destination_secret({id})")` で 1 行取る。`FromSqlInterpolated` はエンティティ用なので不可
- `app.tenant_id` 未設定で例外 → このサービスは必ずリクエスト文脈（ミドルウェアで tenant 解決済み）から呼ぶ。バッチ等から呼ぶ場合は別途 `SET LOCAL` が要る

**AI 依頼テンプレ**: なし（秘匿境界は自分。ただし統合テストは AI に依頼してよい）

---

## Day3-3. destination 登録/編集 + 接続テストボタンの最小 Blazor UI [AI]

**目的**
テナント admin が起票先を登録/編集し、保存前に「接続テスト」できる最小画面を作る。Sprint 1 の Category CRUD（`Components/Pages/Categories/Create.razor` 等）と同じ `EditForm` パターンの複製。接続テスト失敗時は登録させない（[`06_destinations.md:166-172`](../06_destinations.md)）。

**前提確認**
- [ ] Day3-2 完了（secret 保存ができる）
- [ ] Sprint 1 の Category CRUD（一覧/作成/編集）が動く（複製元）
- [ ] `Destination` エンティティの列を確認（`Kind` / `Name` / `Config` / `SecretVaultId` / `IsPrimary` / `FieldMapping` / `SortOrder`）

**自分が先に決めること**
- [ ] ルート: `/t/{Slug}/settings/destinations`（一覧）、`/new`、`/{Id:guid}/edit`
- [ ] 入力フォームの項目: `Name` / `Kind`(redmine|github_issues のドロップダウン) / `Config`(JSON textarea: base_url・project_id / owner・repo) / API キー(`InputText type=password`、保存時のみ Vault へ) / `FieldMapping`(JSON textarea) / `IsPrimary`
- [ ] API キーは **画面に既存値を再表示しない**（編集時は「変更する場合のみ入力」。空なら据え置き）

**AI 依頼テンプレ**
```
backend/Portfolio.Web/Components/Pages/Categories/ の CRUD を参考に、起票先（destinations）の
登録/編集 + 接続テストの最小 Blazor UI を作ってほしい。@rendermode InteractiveServer 明示、
[Authorize]（admin 向け。ポリシーがあれば TenantAdmin）。

ページ:
1. Components/Pages/Settings/Destinations/Index.razor  @page "/t/{Slug}/settings/destinations"
   - AppDbContext.Destinations を一覧（Name / Kind / IsPrimary / 編集リンク）。RLS で自テナント分のみ。
2. Create.razor  @page "/t/{Slug}/settings/destinations/new"
   - EditForm + DataAnnotationsValidator。フィールド:
     Name(必須,max100) / Kind(select: redmine|github_issues) /
     Config(textarea, JSON) / ApiKey(InputText type=password) /
     FieldMapping(textarea, JSON, 任意) / IsPrimary(checkbox)
   - 「接続テスト」ボタン: 入力中の Config + ApiKey から DestinationConfig を組み、
     IDestinationRegistry.Resolve(kind).TestConnectionAsync を呼ぶ。
     結果(TestConnectionResult)を画面表示（成功=緑、InvalidApiKey/Unreachable/Forbidden=赤＋理由）。
   - 「保存」ボタン: 接続テスト成功でなければ保存させない（失敗/未実施なら警告）。
     保存手順: ① destinations 行を Add/SaveChanges（tenant_id は HttpContext.Items["TenantId"] / RLS 経由）
              ② IDestinationSecretStore.SetSecretAsync(destination.Id, apiKey) で Vault 保存
     Config / FieldMapping は JSON 妥当性を保存前に検証（不正 JSON はエラー表示）。
3. Edit.razor  @page "/t/{Slug}/settings/destinations/{Id:guid}/edit"
   - 既存ロード。ApiKey 欄は空表示（既存値は再取得・再表示しない）。空なら Vault は据え置き、入力ありなら更新。
   - 同じ接続テストボタン。見つからなければ NotFound。

制約（重要）:
- API キーは画面・ログ・appsettings に残さない。Vault(IDestinationSecretStore)経由のみ。
- DbUpdateException は "Save failed: ..." を画面表示。tenant id はクライアントから受け取らない。
- System.Text.Json のみ。typed HttpClient は使わない（アダプタが内部で持つ）。
```

**自分の確認ポイント**
- [ ] 接続テスト成功 → 保存可、失敗 → 保存ブロック
- [ ] API キーが編集画面で平文再表示されない、ログに出ない
- [ ] 不正 JSON の Config を弾く
- [ ] 別テナントの destination id を踏むと 404（RLS で見えない）
- [ ] `IsPrimary` を 2 つ true にすると DB の部分ユニークインデックス（`0001_schema.sql:134`）で弾かれる → エラーが画面に出る

**詰まったら**
- 接続テストで `SecretValue` をどう渡す? → 保存前は画面入力のキーを直接 `DestinationConfig.SecretValue` に。保存後（編集の再テスト）は `IDestinationSecretStore.GetSecretAsync`
- `InteractiveServer` でフォーム状態が消える → Sprint 1 の Category フォームと同じレンダーモード/`[SupplyParameterFromForm]` の作法に合わせる

---

## Day3-4. 起票実行サービス（`draft_fields` 保持/クリア + フィールドマッピング優先度変換）[自分 が骨子 → AI が肉付け]

**目的**
「`Ticket` を組んで → Vault から復号 → `DestinationConfig` を作って → `Resolve(kind).SubmitAsync` → 結果で `inquiries` を更新」の 1 本のサービスを置く。起票失敗時に `draft_fields` を短期保持、成功時に NULL クリアする（[`06_destinations.md:160-164`](../06_destinations.md)、プライバシー観点）。Sprint 4 の起票画面はこのサービスを呼ぶだけになる。

**自分で書く理由**
`draft_fields` の保持/クリアと `inquiries.status` 遷移は、プライバシー方針（失敗時のみ保持）と業務状態機械の中核。優先度変換をどこで効かせるか（アダプタが `FieldMapping` を読む設計なので、ここでは `Ticket.TicketPriority` を正しく載せるだけ）を握る。骨子（インターフェースと状態遷移）を自分で書き、HTTP/JSON 詳細は AI に肉付けさせる。

**前提確認**
- [ ] Day3-2 / Day3-3 完了
- [ ] [`06_destinations.md:146-164`](../06_destinations.md)（フロー図）を読んだ
- [ ] `Inquiry` エンティティの列を確認（`Status` / `DraftFields` / `DestinationId` / `ExternalTicketId` / `ExternalTicketUrl` / `MatchedKnowledgeId`）
- [ ] `inquiries.status` は NOT NULL。`'created'` 遷移で `match_count` トリガーが走る（`0001_schema.sql:224-238`）

**手順（自分が骨子を書く）**
1. `Portfolio.Web/Services/ITicketSubmissionService.cs`:
   ```csharp
   namespace Portfolio.Web.Services;

   public sealed record SubmissionRequest(
       Guid InquiryId,
       Guid DestinationId,
       string Title,
       string BodyMarkdown,
       string TicketPriority,         // low/normal/high/urgent
       Guid KnowledgeEntryId,
       string DraftFieldsJson);       // 失敗時に保持するフォーム入力（jsonb）

   public interface ITicketSubmissionService
   {
       Task<TicketSubmitResult> SubmitAsync(SubmissionRequest req, CancellationToken ct);
   }
   ```
2. 実装の状態遷移の骨子（自分で固定し、HTTP 詳細以外を握る）:
   ```
   SubmitAsync:
     1. destinations を id で取得（RLS で自テナント分のみ。kind / config / field_mapping を読む）
     2. secret = await IDestinationSecretStore.GetSecretAsync(destinationId)   ← Vault 復号
     3. cfg = new DestinationConfig(PublicConfig=config, SecretValue=secret, FieldMapping=field_mapping)
        ※ 優先度変換はアダプタが FieldMapping から行う。ここでは TicketPriority をそのまま載せる
     4. ticket = new Ticket(Title, BodyMarkdown, TicketPriority, TenantId, KnowledgeEntryId)
     5. result = await registry.Resolve(destination.Kind).SubmitAsync(ticket, cfg, ct)
     6. inquiry を id で取得し:
        成功 → status='created', external_ticket_id/url=result, draft_fields=NULL, destination_id 設定
        失敗 → status='failed', draft_fields=req.DraftFieldsJson（短期保持）
        SaveChanges（status 更新でトリガーが match_count を回す）
     7. return result
   ```
   - **成功時に `draft_fields=NULL` クリアは必須**（[`06_destinations.md:164`](../06_destinations.md)）。失敗時のみ保持。
   - secret はこのメソッドのローカル変数に留め、`inquiries` 等どこにも書かない・ログに出さない。
3. HTTP/JSON の細部（`config` の `JsonElement` 化、エラーメッセージ整形、`status` 文字列定数化）は AI に肉付けさせる（下記テンプレ）。
4. `Program.cs` で `AddScoped<ITicketSubmissionService, TicketSubmissionService>()`。

**AI 依頼テンプレ（骨子を渡したあと肉付けを依頼）**
```
ITicketSubmissionService の実装 TicketSubmissionService を肉付けしてほしい。骨子（状態遷移）は
ITicketSubmissionService.cs のコメント通り。AppDbContext / IDestinationRegistry /
IDestinationSecretStore を注入。

要件:
- destinations.Config(string jsonb) / FieldMapping(string?) を JsonElement にパースして DestinationConfig へ
- 成功: inquiries.Status="created", ExternalTicketId/Url 設定, DestinationId 設定, DraftFields=null
- 失敗: inquiries.Status="failed", DraftFields=req.DraftFieldsJson（成功時は必ず null クリア）
- status 文字列は const で定義（"created"/"failed"）
- secret はローカル変数のみ・ログ厳禁・例外メッセージに含めない
- 単体/統合テスト（Portfolio.Web.Tests）:
  - 成功時 DraftFields が null になる
  - 失敗時 DraftFields が保持され Status="failed"
  - GetSecretAsync が 1 回だけ呼ばれる
  ※ IDestinationRegistry / IDestinationSecretStore はモック、AppDbContext は InMemory か Testcontainers
- System.Text.Json のみ。Newtonsoft 禁止。
```

**自分の確認ポイント**
- [ ] 成功 → `draft_fields` が NULL、`status='created'`、外部 ID/URL が入る
- [ ] 失敗 → `draft_fields` 保持、`status='failed'`
- [ ] 優先度が Redmine では priority_id、GitHub では labels に変換される（Day 2 のマッピング経由）
- [ ] secret がどこにも永続化・ログ出力されていない
- [ ] テスト green

**詰まったら**
- `'created'` にしてもトリガーが回らない → `matched_knowledge_id` が NULL だとトリガー条件に合わない（`0001_schema.sql:225`）。`MatchedKnowledgeId` が入っているか確認。回らなくても起票自体は成功扱いでよい
- `draft_fields` が成功後も残る → 成功分岐で明示的に `inquiry.DraftFields = null` を入れる（最重要・プライバシー）

---

## Day 3 終了チェックリスト

- [ ] `0004_vault_functions.sql` が動き、`portfolio_app` は EXECUTE のみで Vault 直接アクセス不可
- [ ] 別テナント文脈で他テナントの secret 復号 → 例外（越境拒否を実演確認）
- [ ] destination 登録/編集 UI で接続テスト → 成功時のみ保存、API キーは Vault 保管・画面/ログに残らない
- [ ] 起票実行サービスが 成功=`created`+draft_fields クリア / 失敗=`failed`+draft_fields 保持 を満たす
- [ ] 優先度変換が Redmine=priority_id / GitHub=labels で効く
- [ ] `dotnet build` / `dotnet test` が green、`make secrets`（gitleaks）に引っかかる平文キーが無い

## Sprint 3 完走後の状態

- 起票の「配管」が全部つながった: `SubmitAsync` を呼べば、テナント設定の起票先へ、Vault 復号した API キーで、優先度変換とリトライ付きで起票できる
- 残り（Sprint 4 以降）:
  - **起票画面の本結線**（分類確定 → 動的フォーム → `SubmissionRequest` 組立 → `ITicketSubmissionService`）
  - **再試行 / destination 切替提案の UX**（失敗時 `draft_fields` から復元）
  - **fan-out / Jira 等の追加アダプタ** — Phase 2 の拡張点（[`06_destinations.md:54-61,68`](../06_destinations.md)）
