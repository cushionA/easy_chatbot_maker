# Sprint 5 Day 1 作業指示書（2026-06-04）

> テーマ: **匿名アクセスの防御層**
> 完了時の状態: 公開鍵を持つ匿名リクエストだけが、当該テナントの `knowledge_entries` を読み・`inquiries`/`unclassified_queue` に書ける。`embed.js` が CORS/Origin 制限付きで配信され、匿名チャットの最小 API が叩ける
> 推定所要: 6〜8 時間

> 前提: Sprint 1〜4 完了。`app.tenant_id` 方式の RLS（`0003_rls_policies.sql`）・`portfolio_app`（NOBYPASSRLS）・`DbConnectionInterceptor`・分類/検索/未分類登録サービスが動いている。本日はそれらの**隣に別の鍵束**を足す。

---

## 5-1-1. `0004_anon_widget_rls.sql`（匿名用限定 RLS のお手本）[自分]

**目的**
ログイン経路（`app.tenant_id`）とは独立した、匿名ウィジェット専用の限定ポリシーを **1 テーブル分だけ**自分の手で書く。`knowledge_entries` を「読みだけ」許す型を確定し、残り 2 テーブルは 5-1-2 で AI に複製させる。面接で「なぜ匿名を別セッション変数にしたか」を語れる状態にする。

**自分で書く理由**
これは**漏洩したら全テナントアウト**な境界。`app.widget_tenant_id` を `app.tenant_id` と混同したり、未設定時にフェイルセーフが効かないと、匿名訪問者に他テナントのナレッジが漏れる。型は自分で握り、AI には複製だけさせる。

**前提確認**
- [ ] `design/04_security_multitenant.md:185-209`（匿名アクセス・別変数方式）を読んだ
- [ ] 既存 migration の最大番号が `0003_rls_policies.sql` であることを確認（`ls infra/db/migrations/`）。本ファイルは `0004` を採番する
- [ ] `tenant_public_keys` テーブルが `0001_schema.sql:181-190` に既にあること、列が `key_hash` / `allowed_origins` / `rate_limit_rpm` であることを確認

**手順**
1. 新規ファイル `infra/db/migrations/0004_anon_widget_rls.sql` を作成
2. `knowledge_entries` だけに匿名用ポリシーを追加する（既存の `tenant_isolation` ポリシーは**消さない**。OR で並ぶ）:
   ```sql
   -- 匿名ウィジェット: 読み取りのみ。app.widget_tenant_id 経由でのみ可視。
   -- 既存の tenant_isolation（app.tenant_id）と共存する。両者は別セッション変数なので混線しない。
   DROP POLICY IF EXISTS public_widget_read ON knowledge_entries;
   CREATE POLICY public_widget_read ON knowledge_entries
     FOR SELECT
     USING (tenant_id = current_setting('app.widget_tenant_id', true)::uuid);
   ```
   - 第二引数 `true` で「未設定なら NULL」→ 匿名変数を立てない接続は空集合（フェイルセーフ）
   - `FOR SELECT` のみ。匿名は `knowledge_entries` に書けない
3. owner で流す:
   ```bash
   psql "$SUPABASE_DB_URL_OWNER" -f infra/db/migrations/0004_anon_widget_rls.sql
   ```
4. 手動検証（5-1-1 の範囲では `knowledge_entries` だけ）:
   ```bash
   # 匿名変数で A を立てると A のナレッジだけ見える
   psql "$SUPABASE_DB_URL_APP" -c "BEGIN; SET LOCAL app.widget_tenant_id = '<tenant-a-uuid>'; SELECT count(*) FROM knowledge_entries; ROLLBACK;"
   # 何も立てない → 0 行（フェイルセーフ）
   psql "$SUPABASE_DB_URL_APP" -c "SELECT count(*) FROM knowledge_entries;"
   # app.tenant_id 側を立てても匿名ポリシーとは独立に既存どおり動く（混線しない）
   ```

**ポリシー骨子（この 3 テーブル分を自分が決める。書込テーブルは 5-1-2 で AI が複製）**

| テーブル | 操作 | USING / WITH CHECK |
|---|---|---|
| `knowledge_entries` | `SELECT` のみ | `USING (tenant_id = current_setting('app.widget_tenant_id', true)::uuid)` |
| `inquiries` | `SELECT` + `INSERT` | 両方 `tenant_id = current_setting('app.widget_tenant_id', true)::uuid`。匿名は自テナントの行だけ書ける |
| `unclassified_queue` | `INSERT` のみ | `WITH CHECK (tenant_id = current_setting('app.widget_tenant_id', true)::uuid)`。閲覧は admin（既存 `tenant_isolation`）に任せ匿名には `SELECT` を与えない |

> 設計判断（メモに残す）: `categories` は匿名にも見せる必要があるが、本 Sprint では「カテゴリ選択 UI は admin 設定済みのものを API レスポンスに同梱する」方針にして、匿名 RLS の対象テーブルを最小 3 つに絞る。漏洩面を増やさないため。

**完了確認**
- [ ] `0004_anon_widget_rls.sql` が流れ、`knowledge_entries` に `public_widget_read` ポリシーが付く（`\d knowledge_entries` で確認）
- [ ] 匿名変数 A → A のナレッジのみ、未設定 → 0 行
- [ ] 既存の `app.tenant_id` 経路（ログインユーザーの SELECT）が壊れていない

**詰まったら**
- 未設定で全件返る → `portfolio_app` が NOBYPASSRLS か（`SELECT rolbypassrls FROM pg_roles WHERE rolname='portfolio_app'` が `f`）、`FORCE ROW LEVEL SECURITY` が `knowledge_entries` に効いているか
- 既存ログインユーザーの SELECT が 0 件になった → 新ポリシーが `FOR SELECT` で既存 `tenant_isolation` を上書きしていないか。ポリシーは OR で結合されるので両方残っているか `\d` で確認

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## 5-1-2. 残り 2 テーブルへ匿名ポリシー展開（`inquiries` / `unclassified_queue`）[AI]

**目的**
5-1-1 で確定した型を `inquiries`（SELECT+INSERT）と `unclassified_queue`（INSERT のみ）に複製する。型は自分が握ったので複製は AI で十分。

**前提確認**
- [ ] 5-1-1 完了、`0004_anon_widget_rls.sql` に `knowledge_entries` の匿名ポリシーがある
- [ ] 上の「ポリシー骨子」表を AI に見せられる

**AI 依頼テンプレ**
```
infra/db/migrations/0004_anon_widget_rls.sql に knowledge_entries の匿名ウィジェット用ポリシー public_widget_read（FOR SELECT, USING app.widget_tenant_id）が既にある。
同じ app.widget_tenant_id 方式で、以下 2 テーブルに匿名ポリシーを追加してほしい。既存の tenant_isolation ポリシーは消さず共存させること。

- inquiries:
  - public_widget_insert: FOR INSERT, WITH CHECK (tenant_id = current_setting('app.widget_tenant_id', true)::uuid)
  - public_widget_read:   FOR SELECT, USING (tenant_id = current_setting('app.widget_tenant_id', true)::uuid)
- unclassified_queue:
  - public_widget_insert: FOR INSERT, WITH CHECK (tenant_id = current_setting('app.widget_tenant_id', true)::uuid)
  （匿名には SELECT を与えない＝レビューは admin の既存ポリシーのみ）

current_setting の第二引数は必ず true（未設定でフェイルセーフ空集合）。
DROP POLICY IF EXISTS を各 CREATE の前に置く。
完成後、psql で各テーブルに対し「匿名変数 A を立てて INSERT できる / 立てずに INSERT すると WITH CHECK 違反で失敗する」のスポットチェック手順も出して。
```

**自分の確認ポイント**
- [ ] 3 テーブルすべて `app.widget_tenant_id`（`app.tenant_id` ではない）を参照している
- [ ] `unclassified_queue` に匿名 `SELECT` ポリシーが**付いていない**
- [ ] 第二引数 `true` が全ポリシーに入っている
- [ ] AI が既存 `tenant_isolation` を消していない

**完了確認**
- [ ] 匿名変数 A を立てて `inquiries` / `unclassified_queue` に INSERT 成功
- [ ] 変数未設定で INSERT → 失敗（フェイルセーフ）

---

## 5-1-3. 公開鍵検証 + widget セッション変数発行ミドルウェア [自分]

**目的**
リクエストヘッダの公開鍵を `tenant_public_keys.key_hash` と照合し、合致したテナントに対して `SET LOCAL app.widget_tenant_id = '<uuid>'` を立てる。**ここが匿名経路の認可の単一ポイント**。ログイン経路の `TenantResolutionMiddleware` とは別物として独立させる。

**自分で書く理由**
公開鍵の照合と「どのテナントの匿名変数を立てるか」の決定は、誤ると越境につながる認可の中核。`DbConnectionInterceptor` が `app.tenant_id` を立てる経路と混線させない設計判断も含め、面接で語る要所。

**前提確認**
- [ ] 5-1-2 完了
- [ ] `Data/Entities/TenantPublicKey.cs`（`KeyHash` / `AllowedOrigins` / `RateLimitRpm`）を確認
- [ ] 既存の `DbConnectionInterceptor`（`app.tenant_id` を `HttpContext.Items["TenantId"]` から立てる）の動きを再確認

**手順**
1. 新規 `backend/Portfolio.Web/Middleware/WidgetAuthMiddleware.cs`:
   ```csharp
   // 匿名ウィジェット経路専用。/api/widget/... のみ対象。
   // ログイン経路の TenantResolutionMiddleware とは独立に動く。
   public sealed class WidgetAuthMiddleware(RequestDelegate next)
   {
       public async Task InvokeAsync(HttpContext ctx, OwnerDbContext owner)
       {
           if (!ctx.Request.Path.StartsWithSegments("/api/widget"))
           {
               await next(ctx);
               return;
           }

           // 公開鍵はヘッダで受け取る（クエリには載せない＝ログ流出防止）
           var presented = ctx.Request.Headers["X-Widget-Key"].ToString();
           if (string.IsNullOrEmpty(presented))
           {
               ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
               return;
           }

           // 鍵はハッシュで保管。提示値をハッシュ化して照合（タイミング安全比較）。
           var hash = WidgetKeyHasher.Hash(presented);
           // owner 接続で引く理由: tenant_public_keys を引く時点ではまだ
           // どのテナントか未確定なので、app 接続だと RLS で空集合になる。
           var key = await owner.TenantPublicKeys
               .AsNoTracking()
               .FirstOrDefaultAsync(k => k.KeyHash == hash, ctx.RequestAborted);
           if (key is null)
           {
               ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
               return;
           }

           // 確定したテナントを匿名コンテキストとして格納。
           // app.tenant_id 用の Items["TenantId"] とは別キーにする（混線防止）。
           ctx.Items["WidgetTenantId"]  = key.TenantId;
           ctx.Items["WidgetKey"]       = key; // 5-1-4 の Origin / 5-2-3 の rate limit で使う
           await next(ctx);
       }
   }
   ```
2. `WidgetKeyHasher`（SHA-256 等。鍵は十分なエントロピーを持つランダム文字列なので salt 不要、固定ハッシュで OK。**平文鍵は DB に残さない**）を `backend/Portfolio.Web/Services/WidgetKeyHasher.cs` に追加
3. `DbConnectionInterceptor`（Sprint 1 で作成済み）に分岐を足す。`Items["WidgetTenantId"]` があれば `app.tenant_id` ではなく `app.widget_tenant_id` を立てる:
   ```csharp
   // 既存: Items["TenantId"] → SET LOCAL app.tenant_id
   // 追加: Items["WidgetTenantId"] → SET LOCAL app.widget_tenant_id
   // 両方同時には立てない（ログイン経路と匿名経路は排他）
   ```
4. `Program.cs` に登録（`UseAuthentication`/`UseAuthorization` の後、ただし匿名なので `[Authorize]` は通さない。`MapRazorComponents` の前）:
   ```csharp
   app.UseMiddleware<WidgetAuthMiddleware>();
   ```

**完了確認** — 単体テスト 4 ケース（テストは 5-1-5 の AI 依頼に同梱可）:
- [ ] `X-Widget-Key` なし → 401
- [ ] 存在しない鍵 → 401
- [ ] 有効な鍵 → 通過、`Items["WidgetTenantId"]` に当該テナント
- [ ] `/api/widget` 以外のパス → ミドルウェアは素通り（既存ログイン経路に影響なし）

**詰まったら**
- `tenant_public_keys` が引けない（0 件）→ owner 接続を使っているか。app 接続だと RLS で空集合になる
- 既存ログイン経路が壊れた → `app.tenant_id` と `app.widget_tenant_id` を同時に立てていないか。インターセプタで排他にする

**AI 依頼テンプレ**: ミドルウェア本体・ハッシャは自分。テストは 5-1-5 にまとめて依頼。

---

## 5-1-4. `embed.js` 配信エンドポイント + CORS/Origin チェック [自分（最初の 1 個）]

**目的**
利用者サイトが `<script src="https://.../api/widget/embed.js?key=...">` で読み込む配信エンドポイントを作り、`tenant_public_keys.allowed_origins` に基づく CORS / Origin 制限をかける。配信レスポンスと API レスポンスの両方に正しい `Access-Control-Allow-Origin` を返す型をここで確定する。

**自分で書く理由**
CORS / Origin 照合は「どのサイトからの埋め込みを許すか」の境界。ワイルドカード `*` で開けてしまうと公開鍵が漏れた時に任意サイトから叩かれる。許可判定ロジックは自分で握り、ウィジェット JS の中身（5-2-2）は AI に渡す。

**前提確認**
- [ ] 5-1-3 完了
- [ ] `design/08_features.md:79-87`（CORS/Origin チェック・shadow DOM の位置づけ）を読んだ
- [ ] `Program.cs` の minimal API でエンドポイントを足せる構成を確認

**手順**
1. 配信用に `Program.cs`（または `Endpoints/WidgetEndpoints.cs`）へ minimal API を足す:
   ```csharp
   // GET /api/widget/embed.js?key=<public-key>
   // Origin が allowed_origins に含まれるときだけ CORS ヘッダを返す。
   var widget = app.MapGroup("/api/widget");

   widget.MapGet("/embed.js", async (HttpContext ctx, OwnerDbContext owner) =>
   {
       var key = ctx.Request.Query["key"].ToString();
       var hash = WidgetKeyHasher.Hash(key);
       var pk = await owner.TenantPublicKeys.AsNoTracking()
           .FirstOrDefaultAsync(k => k.KeyHash == hash);
       if (pk is null) return Results.Unauthorized();

       var origin = ctx.Request.Headers.Origin.ToString();
       if (!string.IsNullOrEmpty(origin) && IsOriginAllowed(origin, pk.AllowedOrigins))
           ctx.Response.Headers.AccessControlAllowOrigin = origin; // エコーバック（* は使わない）

       ctx.Response.ContentType = "application/javascript; charset=utf-8";
       // embed.js 本体は 5-2-2 で AI が作る。ここでは雛形 or 静的ファイルを返す。
       return Results.File("wwwroot/widget/embed.js", "application/javascript");
   });
   ```
2. `IsOriginAllowed(origin, allowedOrigins)` を自分で書く。**完全一致**（`https://example.com`）を基本にし、ワイルドカードは許さない方針:
   ```csharp
   static bool IsOriginAllowed(string origin, string[] allowed)
       => allowed.Any(a => string.Equals(a, origin, StringComparison.OrdinalIgnoreCase));
   ```
3. プリフライト（`OPTIONS /api/widget/chat` 等）への応答を共通化する。許可 Origin のみ `Access-Control-Allow-Methods` / `Access-Control-Allow-Headers: X-Widget-Key, Content-Type` を返す。許可外は CORS ヘッダを付けない（ブラウザが弾く）

**完了確認**
- [ ] 許可 Origin から `GET /api/widget/embed.js?key=有効` → 200 + `Access-Control-Allow-Origin: <その Origin>`
- [ ] 許可外 Origin → JS は返るが CORS ヘッダなし（ブラウザの fetch は CORS エラー）
- [ ] 鍵不正 → 401
- [ ] `Access-Control-Allow-Origin: *` を**返していない**ことを目視（curl でヘッダ確認）

**詰まったら**
- ブラウザで CORS エラー → `Origin` ヘッダのスキーム/ポート込みで完全一致しているか（`https://example.com` と `https://example.com:443` は別物）。`allowed_origins` の登録値を見直す
- プリフライトが 404 → `MapMethods(..., "OPTIONS", ...)` を別途定義する必要があるか確認

**AI 依頼テンプレ**: 配信エンドポイントと `IsOriginAllowed` は自分。embed.js 本体は 5-2-2 で AI。

---

## 5-1-5. 匿名チャット用最小 API の結線 [AI]

**目的**
既存の分類/検索/未分類登録サービス（Sprint 2〜4 で実装済み）を、匿名コンテキスト（`Items["WidgetTenantId"]`）から呼ぶ最小エンドポイントを作る。新しい検索ロジックは書かない、**結線だけ**。

**前提確認**
- [ ] 5-1-3 / 5-1-4 完了
- [ ] 既存の分類サービス（`Classify(query, tenantId, categoryId)` 相当）と未分類登録のシグネチャを AI に見せられる

**AI 依頼テンプレ**
```
ASP.NET Core 8 minimal API で、匿名ウィジェット用の最小エンドポイントを backend/Portfolio.Web/Endpoints/WidgetEndpoints.cs に追加してほしい。
WidgetAuthMiddleware が HttpContext.Items["WidgetTenantId"] に Guid を入れ、DbConnectionInterceptor が SET LOCAL app.widget_tenant_id を立てる前提（既存）。新しい検索ロジックは書かず、既存サービスを呼ぶだけ。

エンドポイント（すべて MapGroup("/api/widget") 配下、[Authorize] は付けない）:
1. GET  /categories         → 当該テナントの categories を返す（id/code/name/emoji/sort_order）
2. POST /classify           → body { query, categoryId? } を既存の分類サービスに渡し、候補 + match_strategy + confidence_score を返す
3. POST /inquiries          → 確定した inquiry を INSERT（status/match_strategy/confidence_score/matched_knowledge_id を記録）
4. POST /unclassified       → 「新規問題として」入力を unclassified_queue に INSERT

注意:
- tenant_id は body から受け取らず、Items["WidgetTenantId"] から取る（クライアント由来の tenant id は信頼しない）
- 例外時に内部情報を漏らさない（ProblemDetails で最小限）
- レスポンスはマスタ管理用の admin 専用列（auto_resolution の編集権限など）を含めない、表示に必要な分だけ

あわせて WidgetAuthMiddleware の単体テスト（401 系 3 ケース + 通過 1 ケース）を Portfolio.Web.Tests に書いて。
```

**自分の確認ポイント**
- [ ] どのエンドポイントも `tenant_id` を body から受けていない（必ず `Items["WidgetTenantId"]`）
- [ ] `POST /inquiries` / `/unclassified` が `app.widget_tenant_id` 経路で書けている（5-1-2 のポリシーと整合）
- [ ] レスポンスに admin 専用情報が混ざっていない

**完了確認**
- [ ] curl + `X-Widget-Key` で `/api/widget/categories` → 当該テナントのカテゴリ
- [ ] `/api/widget/classify` → 候補が返る
- [ ] `/api/widget/unclassified` POST → `unclassified_queue` に行が増える

---

## Day 1 終了チェックリスト

- [ ] `0004_anon_widget_rls.sql` が 3 テーブル（`knowledge_entries` SELECT / `inquiries` SELECT+INSERT / `unclassified_queue` INSERT）に `app.widget_tenant_id` ポリシーを当てている
- [ ] 匿名変数未設定で全テーブル空集合（フェイルセーフ）
- [ ] `WidgetAuthMiddleware` が公開鍵を照合し `Items["WidgetTenantId"]` を立て、インターセプタが `app.widget_tenant_id` を発行する
- [ ] `/api/widget/embed.js` が `allowed_origins` 完全一致のときだけ CORS ヘッダを返す（`*` ではない）
- [ ] 匿名 API 4 本（categories/classify/inquiries/unclassified）が `X-Widget-Key` 経由で叩ける
- [ ] 既存ログイン経路（`app.tenant_id`）が壊れていない

## Day 2 への引き継ぎメモ（自分宛て）

- 匿名変数名は `app.widget_tenant_id`、ヘッダは `X-Widget-Key` で統一（5-2-2/5-2-3 の AI 依頼に明示）
- `tenant_public_keys.rate_limit_rpm` は Day2-3 のレートリミットで使う（鍵オブジェクトを `Items["WidgetKey"]` に積んである）
- embed.js は `wwwroot/widget/embed.js` を配信する構成にした（5-2-2 でここに本体を置く）
