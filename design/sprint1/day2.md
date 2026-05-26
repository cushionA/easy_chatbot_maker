# Sprint 1 Day 2 作業指示書（2026-05-18）

> テーマ: **アプリ ↔ DB の認証/テナント導管**
> 完了時の状態: 全テーブルに RLS が当たり、JWT 検証 → テナント解決 → `SET LOCAL` の流れがリクエスト毎に動く。Testcontainers の漏洩テストが green
> 推定所要: 6〜8 時間

---

## Day2-1. RLS ポリシーを残テーブルに展開 [AI 委譲]

**目的**
Day1-4 で `knowledge_entries` に書いたお手本パターンを、残り 9 テーブルに横展開する。**型は自分が握ったので、複製は AI で十分**。

**前提確認**
- [ ] Day 1 完了
- [ ] `infra/db/migrations/0003_rls_policies.sql` の現状を AI に見せられる

**AI 依頼テンプレ**
```
infra/db/migrations/0003_rls_policies.sql に knowledge_entries の RLS ポリシーが既にある。
同じパターン（ENABLE + FORCE + tenant_isolation ポリシー）を以下のテーブルにも追加してほしい:

- categories
- field_definitions
- validation_rules
- destinations
- inquiries
- unclassified_queue
- tenant_public_keys

ただし以下の 2 テーブルは特殊なので別パターンで:

- user_tenants: USING / WITH CHECK は user_id = current_setting('app.user_id', true)::uuid
  （自分のレコードのみ可視）
- tenants: SELECT 専用ポリシー。
  USING (id IN (SELECT tenant_id FROM user_tenants WHERE user_id = current_setting('app.user_id', true)::uuid))
  INSERT/UPDATE/DELETE はアプリから直接行わないので明示的に拒否する別ポリシーは不要、GRANT で絞る方針

ポリシー名は tenant_isolation で統一。user_tenants と tenants は user_isolation / tenant_visibility にして。

完成後、SQL を流して \d <table> の出力で各テーブルに RLS enabled マークが付くことを確認してほしい。
```

**自分の確認ポイント（コードを見るとき）**
- [x] 全テーブルに `FORCE ROW LEVEL SECURITY` が入っている
- [x] `user_tenants` のポリシーが `tenant_id` ではなく `user_id` 基準になっている
- [x] `tenants` のポリシーが `user_tenants` をサブクエリで参照している
- [x] AI が勝手にポリシー名を変えていない

**完了確認**
```powershell
psql "$env:SUPABASE_DB_URL_APP" -c "BEGIN; SET LOCAL app.tenant_id = '00000000-0000-0000-0000-000000000001'; SELECT count(*) FROM categories; SELECT count(*) FROM destinations; ROLLBACK;"
```
- 各テーブルが当該テナントの件数のみ返る（事前に検証データを 2 テナント分入れておく）

---

## Day2-2. `Program.cs` に JWT 検証を組み込む

**目的**
Supabase が発行した JWT を `Authorization: Bearer ...` ヘッダから受け取り、署名検証してクレームを抽出できる状態にする。

**自分で書く理由**
認証パイプラインの中核。後から「なんとなく動いている」になりやすい部分で、ここで詰まると Day2-3 以降が全部空回りする。

**前提確認**
- [x] `backend/Portfolio.Web/Portfolio.Web.csproj` に `Microsoft.AspNetCore.Authentication.JwtBearer` が入っている（参照済み）
- [ ] `design/04_security_multitenant.md:82-105` を読んだ

**手順**
1. `backend/Portfolio.Web/appsettings.Development.json` に Supabase 設定を追加（ローカル開発用）:
   ```json
   "Supabase": {
     "JwksUrl": "https://abc123.supabase.co/auth/v1/.well-known/jwks.json",
     "Issuer": "https://abc123.supabase.co/auth/v1",
     "Audience": "authenticated"
   }
   ```
2. 本番用は `User Secrets` or 環境変数で上書きする方針（`appsettings.json` には書かない）
3. `Program.cs` に以下を追加（`AddRazorComponents` の手前あたり）:
   ```csharp
   builder.Services
       .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
       .AddJwtBearer(options =>
       {
           var supa = builder.Configuration.GetSection("Supabase");
           options.Authority = supa["Issuer"];
           options.Audience  = supa["Audience"];
           options.MetadataAddress = supa["JwksUrl"]; // Supabase は authority と異なる場所に JWKS を置くので明示
           options.TokenValidationParameters = new TokenValidationParameters
           {
               ValidateIssuer = true,
               ValidateAudience = true,
               ValidateLifetime = true,
               ValidateIssuerSigningKey = true,
               ClockSkew = TimeSpan.FromSeconds(30),
           };
       });
   builder.Services.AddAuthorization();
   builder.Services.AddHttpContextAccessor(); // Day2-4 で使う
   ```
4. パイプラインに以下を追加（`app.UseAntiforgery();` の **前**）:
   ```csharp
   app.UseAuthentication();
   app.UseAuthorization();
   ```

**完了確認**
1. `dotnet build` が通る
2. ローカル起動して以下を試す:
   - Supabase ダッシュボードの Auth → Users で 1 ユーザー作成し、`service_role` で JWT を発行
   - `curl -H "Authorization: Bearer <正規 JWT>" http://localhost:8080/healthz` → 200
   - `curl -H "Authorization: Bearer invalid" http://localhost:8080/healthz` → 200 のまま（`/healthz` は `[Authorize]` 不要）
   - 簡易の `[Authorize]` 付きエンドポイントを 1 個足し、改ざんトークンで 401 を確認

**詰まったら**
- 401 にならない → `app.UseAuthentication()` が漏れている、または `UseRouting` との順序
- Supabase JWT の `iss` が `authority` と一致しない → `MetadataAddress` を明示しているか確認、`ValidateIssuer = false` の妥協は最終手段

**AI 依頼テンプレ**（雛形だけ AI に書かせる場合）
```
ASP.NET Core 8 + Blazor Server で、Supabase Auth 発行の JWT を Authorization Bearer ヘッダから受け取って検証する設定を Program.cs に追加してほしい。
- JwksUrl, Issuer, Audience は IConfiguration の "Supabase" セクションから読む
- ValidateIssuer/Audience/Lifetime/IssuerSigningKey すべて true
- ClockSkew は 30 秒
- IHttpContextAccessor も DI 登録（後続のミドルウェアで使う）
コードのみ。
```

---

## Day2-3. テナント解決ミドルウェア

**目的**
URL `/t/{slug}/...` の `slug` を読み取り、JWT の `sub`（user_id）と `user_tenants` を突き合わせて、当該リクエストの `tenant_id` を確定する。確定値は `HttpContext.Items["TenantId"]` に格納し、Day2-4 のインターセプタが拾う。

**自分で書く理由**
認可ロジックの中核。誤ると別テナントに侵入される。

**前提確認**
- [x] Day2-2 完了
- [ ] `design/04_security_multitenant.md:82-105` を再読

**手順**
1. 新規ファイル `backend/Portfolio.Web/Middleware/TenantResolutionMiddleware.cs`:
   ```csharp
   public sealed class TenantResolutionMiddleware
   {
       private readonly RequestDelegate _next;
       public TenantResolutionMiddleware(RequestDelegate next) => _next = next;

       public async Task InvokeAsync(HttpContext ctx, AppDbContext db)
       {
           // /t/{slug}/... 以外はスキップ
           var segs = ctx.Request.Path.Value?.Split('/', StringSplitOptions.RemoveEmptyEntries);
           if (segs is null || segs.Length < 2 || segs[0] != "t")
           {
               await _next(ctx);
               return;
           }

           // 認証必須
           if (ctx.User.Identity?.IsAuthenticated != true)
           {
               ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
               return;
           }

           var slug = segs[1];
           var userIdClaim = ctx.User.FindFirst("sub")?.Value;
           if (!Guid.TryParse(userIdClaim, out var userId))
           {
               ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
               return;
           }

           // slug -> tenant_id, かつ user_tenants で所属確認
           // ここはミドルウェアなので RLS 前。owner ロールで引くか、user_tenants の RLS は user_id ベースなので app でも OK
           var tenantId = await db.UserTenants
               .Where(ut => ut.UserId == userId && ut.Tenant.Slug == slug)
               .Select(ut => (Guid?)ut.TenantId)
               .FirstOrDefaultAsync();

           if (tenantId is null)
           {
               ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
               return;
           }

           ctx.Items["TenantId"] = tenantId.Value;
           ctx.Items["UserId"]   = userId;
           await _next(ctx);
       }
   }
   ```
2. `Program.cs` で登録（`UseAuthentication`/`UseAuthorization` の後、`MapRazorComponents` の前）:
   ```csharp
   app.UseMiddleware<TenantResolutionMiddleware>();
   ```
3. ミドルウェアが `AppDbContext` を解決する都合上、`SET LOCAL` 未発行で `user_tenants` を引くことになる。`user_tenants` のポリシーは `user_id = current_setting('app.user_id', true)::uuid` だが、ミドルウェア時点では `app.user_id` 未設定 → 空集合になってしまう。
   **対処**: ミドルウェアの DB アクセスだけは `portfolio_owner` 接続を使う、もしくは `user_tenants` のポリシーを「未設定時は自分の JWT クレームを使う」形にする。
   **MVP 推奨**: ミドルウェア専用に `OwnerDbContext` を別 DI 登録し、こちらで解決する（接続 URL は `SUPABASE_DB_URL_OWNER`）。

**完了確認** — 単体テストで以下 4 ケース:
- [ ] 認証なしで `/t/foo/...` → 401
- [ ] 認証あり、存在しない slug → 403
- [ ] 認証あり、他テナントの slug（自分が所属していない）→ 403
- [ ] 認証あり、自分が所属する slug → 通過、`ctx.Items["TenantId"]` に値が入る

**詰まったら**
- `ctx.User.FindFirst("sub")` が null → Supabase JWT は `sub` を使うが、`ClaimTypes.NameIdentifier` 経由だと型が変わっていることがある。両方試す

**AI 依頼テンプレ**: ミドルウェア本体は自分。**テスト**は AI に依頼する:
```
TenantResolutionMiddleware の単体テストを xUnit で書いてほしい。
モック対象: AppDbContext（InMemoryProvider）または UserTenants DbSet をフェイク
ケース: 1) 認証なし→401  2) 存在しない slug→403  3) 他テナント slug→403  4) 自分が所属する slug→200 かつ Items["TenantId"] が期待値
```

---

## Day2-4. `DbConnectionInterceptor` で `SET LOCAL` 発行

**目的**
EF Core が接続プールから接続を借りたタイミングで `SET LOCAL app.tenant_id = '...'; SET LOCAL app.user_id = '...';` を発行する。**これが RLS の有効/無効を分ける単一のポイント**。

**自分で書く理由**
ここを誤ると、全 RLS が機能しない or 別テナントの値が混入する。

**前提確認**
- [ ] Day2-3 完了
- [ ] `design/04_security_multitenant.md:107-114`（`SET LOCAL` の発行ポイント）を読んだ

**手順**
1. 新規ファイル `backend/Portfolio.Web/Data/TenantConnectionInterceptor.cs`:
   ```csharp
   public sealed class TenantConnectionInterceptor : DbConnectionInterceptor
   {
       private readonly IHttpContextAccessor _http;
       public TenantConnectionInterceptor(IHttpContextAccessor http) => _http = http;

       public override async Task ConnectionOpenedAsync(DbConnection connection,
           ConnectionEndEventData eventData, CancellationToken cancellationToken = default)
       {
           var items = _http.HttpContext?.Items;
           if (items?["TenantId"] is not Guid tenantId) return;
           if (items?["UserId"]   is not Guid userId)   return;

           await using var cmd = connection.CreateCommand();
           // SET LOCAL は文字列リテラル必須なので format で埋め込む。
           // tenantId/userId は Guid 型保証済み（middleware で TryParse 済み）なので SQL injection リスクなし。
           cmd.CommandText = $"SET LOCAL app.tenant_id = '{tenantId}'; SET LOCAL app.user_id = '{userId}';";
           await cmd.ExecuteNonQueryAsync(cancellationToken);
       }
   }
   ```
2. `Program.cs` の `AddDbContext` を以下に差し替え:
   ```csharp
   builder.Services.AddScoped<TenantConnectionInterceptor>();
   builder.Services.AddDbContext<AppDbContext>((sp, opt) =>
   {
       var conn = builder.Configuration.GetConnectionString("PortfolioApp")!;
       opt.UseNpgsql(conn, x => x.UseVector())
          .AddInterceptors(sp.GetRequiredService<TenantConnectionInterceptor>());
   });
   ```
3. `appsettings.Development.json` の `ConnectionStrings:PortfolioApp` を `portfolio_app` の接続文字列に変更
4. `OwnerDbContext` を別途登録（Day2-3 で使う、マイグレーション専用）

**完了確認**
- [ ] ログイン後にカテゴリ一覧を引くと、自テナントのものしか返らない（手で別テナント slug を試して 403 ではなく、ちゃんと所属テナントの URL でアクセス）
- [ ] Postgres のログ（Supabase ダッシュボードの Logs → Postgres Logs）に `SET LOCAL app.tenant_id = ...` が毎リクエスト出ている

**詰まったら**
- `SET LOCAL` がトランザクション外で発行され効果なし → EF Core は `ConnectionOpenedAsync` の文脈ではまだトランザクション外。`SET` でも `SET SESSION` 相当に effectively なる場合がある。`DbCommandInterceptor.ReaderExecutingAsync` で再発行する補強案を入れる
- それでも漏れる → トランザクション開始タイミングと干渉している。`opt.UseNpgsql(conn).EnableDetailedErrors().LogTo(Console.WriteLine)` でクエリログを出して順序確認

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## Day2-5. RLS 漏洩テスト [AI 一次実装 → 自分レビュー]

**目的**
RLS が **実 Postgres で本当に効いているか** を E2E 寄りのテストで証明する。InMemory プロバイダでは検証できない。

**前提確認**
- [ ] Day2-4 完了
- [ ] Docker Desktop が動いている（Testcontainers が必要）

**自分の責務（先に書く）**
ケースリストを以下に固定:
1. テナント A のユーザーで接続 → A のレコードのみ SELECT で見える
2. テナント A のユーザーで B の `tenant_id` を持つレコード INSERT → 失敗（`WITH CHECK` 違反）
3. テナント A のユーザーで B のレコードを UPDATE → 0 行影響（`USING` で見えない）
4. テナント A のユーザーで B のレコードを DELETE → 0 行影響
5. 上記 1-4 を A↔B 反転で再実行
6. セッション変数未設定で接続 → 全テーブル 0 行（フェイルセーフ）

**AI 依頼テンプレ**
```
ASP.NET Core 8 + xUnit + Testcontainers.PostgreSql で RLS 漏洩テストを書いてほしい。

要件:
- Testcontainers で Postgres 16 + pgvector を起動（pgvector/pgvector:pg16 イメージ）
- infra/db/init.sql, migrations/0001_schema.sql, 0002_rls_roles.sql, 0003_rls_policies.sql をこの順に流す
- テナント A / B と所属ユーザー a-user / b-user を作成
- knowledge_entries にそれぞれのテナントのレコードを 1 件ずつ INSERT
- 以下 6 ケースを Theory or 個別 Fact で実装:
  1. a-user セッションで SELECT → A の 1 件のみ
  2. a-user セッションで B の tenant_id の INSERT → 例外
  3. a-user セッションで B のレコード UPDATE → 0 行影響
  4. a-user セッションで B のレコード DELETE → 0 行影響
  5. 1-4 を b-user で反転
  6. セッション変数未設定で SELECT → 0 行（フェイルセーフ）

ファイル: backend/Portfolio.Web.Tests/RlsIsolationTests.cs
[Trait("Category", "RLS")] を付ける（CI で別ジョブにする予定）
```

**自分の確認ポイント**
- [ ] テストが green であることを確認したあと、**わざと `0003_rls_policies.sql` の `FORCE` 行をコメントアウトして再実行 → 一部ケースが red になる** ことを確認。green が偶然でない証拠を取る

**完了確認**
- [ ] 6 ケース全部 green
- [ ] 「ポリシー外すと red」を一度経験済み
- [ ] CI の workflow にこのテストを実行するステップを追加（または別ジョブとして分離）

---

## Day 2 終了チェックリスト

- [ ] 全 10 テーブルに RLS ポリシーが適用済み（特殊 2 テーブル含む）
- [ ] 正規 JWT → 200、改ざん/期限切れ → 401
- [ ] 別テナント slug → 403、所属テナント slug → 通過
- [ ] `SET LOCAL` が毎リクエスト Postgres ログに出ている
- [ ] Testcontainers の 6 ケースが green、ポリシー外すと red になることも確認
- [ ] `OwnerDbContext` と `AppDbContext` が DI 上で分離されている

## Day 3 への引き継ぎメモ

- Day3 では `/t/{slug}/categories` 系の Razor ページを書く。ミドルウェアは既に `slug → tenant_id` を解決済みなので、ページ側は `HttpContext.Items["TenantId"]` を読むか、単に `DbContext` を使えば自動で絞られる
- Excel 取込スクリプトはミドルウェアを通らないので、`OwnerDbContext` でテナント作成 → 個別接続で `SET LOCAL` してデータ投入、の 2 段で組む

> **対応済み（Day2-2 で発覚 / DB 接続の前提）**: `.env.local` の `SUPABASE_DB_URL_APP` は URL 形式（`postgresql://user:pass@host/db`）だが `NpgsqlDataSourceBuilder` はキーワード形式しか受け付けず `Program.cs` の接続ソース生成で落ちていた。方針 B で対応 — `Program.cs` に `ToNpgsqlConnectionString()` ヘルパーを追加し、`postgresql://`/`postgres://` で始まる場合のみ `Uri` パースで `NpgsqlConnectionStringBuilder`（`SslMode.Require`）に詰め替える。`ConnectionStrings:Postgres` と `SUPABASE_DB_URL_APP` の両経路を 1 回の変換で正規化。生 `.env.local`（URL 形式）でローカル起動成功を確認済み。`.env.local` は Supabase コピペそのまま（URL 形式）で OK。
