# Sprint 3 Day 2 作業指示書（2026-05-28）

> テーマ: **アダプタを実装する**
> 完了時の状態: `RedmineDestination` と `GitHubIssuesDestination` の 2 実装が `DestinationRegistry` から解決でき、`TestConnectionAsync` / `SubmitAsync` がモック HTTP テストで green。起票失敗時のリトライ（指数バックオフ最大 3 回）と認証エラー即失敗が分岐する。
> 推定所要: 6〜8 時間

> 参照の正: [`06_destinations.md:70-107`](../06_destinations.md)（フィールドマッピング）、[`06_destinations.md:146-164`](../06_destinations.md)（失敗時挙動）、[`10_existing_streamlit.md:100-111`](../10_existing_streamlit.md)（`redmine_client.py`）。
> 前提: API キーはこの時点では「`DestinationConfig.SecretValue` に復号済みで入っている」前提で書く。Vault 復号は Day 3。

---

## Day2-1. 共通の起票失敗分類 + リトライ方針を決める [自分]

**目的**
「リトライしてよい失敗」と「即失敗にすべき失敗」を分ける境界を確定する。06 章のフロー図（[`06_destinations.md:146-164`](../06_destinations.md)）を、両アダプタが共有する 1 つのポリシーに落とす。ここを先に握れば、Redmine / GitHub の実装は「ポリシーに従って投げるだけ」になる。

**自分で書く理由**
リトライ境界を誤ると、認証エラー（401/403）を 3 回叩いて遅延だけ増やす、あるいは一時障害（5xx/タイムアウト）で即諦めてユーザー体験を損なう。失敗ハンドリングの設計判断は面接で語る対象（「冪等性の無い起票で安易に全リトライすると二重起票になる。だから一時障害だけに絞った」）。

**前提確認**
- [ ] Day 1 完了（`TicketSubmitResult` / `TestConnectionResult` がある）
- [ ] [`06_destinations.md:146-164`](../06_destinations.md) を読んだ

**手順**
1. `Portfolio.Destinations/SubmitRetryPolicy.cs` に「再試行可否の判定」と「指数バックオフ」を 1 箇所に集約する骨子を書く:
   ```csharp
   namespace Portfolio.Destinations;

   // 起票 API 応答をどう扱うかの分類。HTTP ステータスと例外種別から決める。
   public enum SubmitOutcome
   {
       Success,       // 2xx
       RetryableFail, // ネットワーク例外 / タイムアウト / 5xx / 429
       FatalFail      // 401/403（認証・権限）/ 4xx（不正リクエスト）→ 即失敗
   }

   public static class SubmitRetryPolicy
   {
       public const int MaxAttempts = 3; // 06 章「最大3回」

       // HttpResponseMessage / 例外 → SubmitOutcome の分類は各アダプタで使う。
       public static SubmitOutcome Classify(int? httpStatus, bool isNetworkOrTimeout)
       {
           if (isNetworkOrTimeout) return SubmitOutcome.RetryableFail;
           if (httpStatus is null)  return SubmitOutcome.RetryableFail;
           var s = httpStatus.Value;
           if (s is >= 200 and < 300) return SubmitOutcome.Success;
           if (s is 401 or 403)       return SubmitOutcome.FatalFail; // 認証/権限は即失敗
           if (s == 429 || s >= 500)  return SubmitOutcome.RetryableFail;
           return SubmitOutcome.FatalFail; // その他 4xx は不正リクエスト＝即失敗
       }

       // attempt は 0 始まり。バックオフは 1s, 2s, 4s（+少量ジッタは実装側で）
       public static TimeSpan Backoff(int attempt) =>
           TimeSpan.FromSeconds(Math.Pow(2, attempt));
   }
   ```
2. リトライ実行の小さなヘルパ（`SubmitAsync` 用）を同ファイルか別ファイルに置く。**冪等性が無い起票なので、リトライは「送信前に確実に失敗が分かったケース（接続失敗・5xx で本文未到達）」に限る**方針をコメントで明記。`Polly` を使ってもよいが、MVP は依存を増やさず自前ループで十分:
   ```csharp
   // 擬似コード方針（実装は各アダプタ内 or 共通ヘルパ）:
   // for attempt in 0..MaxAttempts-1:
   //   送信 → Classify
   //   Success  → return 成功
   //   FatalFail→ return 失敗（即）
   //   Retryable→ 最終試行なら失敗 return、そうでなければ Backoff(attempt) 待って continue
   ```
3. 認証エラー（`FatalFail` のうち 401/403）は `TicketSubmitResult.ErrorMessage` に「auth」と分かる文言を入れ、UI が destination 切替提案を出せるようにする（[`06_destinations.md:161`](../06_destinations.md)）。

**完了確認**
- [ ] `Classify` の単体テスト（200/401/403/400/429/500/タイムアウト）を自分で 1 つ書いて全分岐確認
- [ ] 「リトライは冪等性の無い起票で二重起票を生まない範囲に限る」コメントがコード上にある

**詰まったら**
- 429 を Fatal にすべきか迷う → Retryable（Retry-After を尊重するのが理想だが MVP は固定バックオフでよい）
- Polly を入れたい → 可。ただし依存追加は `backend/CLAUDE.md` の方針に沿って csproj に明記。MVP は自前で十分

**AI 依頼テンプレ**: なし（分類の境界を自分で決める範囲。`Classify` のテストだけ AI に増やしてもらってよい）

---

## Day2-2. `RedmineDestination` を実装（既存 `redmine_client.py` から移植）= 最初の 1 個 [自分]

**目的**
**Adapter パターンの「最初の 1 個」を自分の手で書く**（[`09_task_split.md:81`](../09_task_split.md) で明示）。既存 Streamlit 版 `redmine_client.py` の REST 呼出パターンを `ITicketDestination` 実装に再構成する。これが GitHub Issues 複製のテンプレになる。

**自分で書く理由**
「最初の 1 個」は型を確定させる作業で、ここを自分で通せば 2 個目を AI に複製させても挙動を保証できる。Redmine REST の認証ヘッダ・優先度マッピング・URL 組立を自分の手で通すことで、面接で「Adapter の中身まで説明できる」状態になる。

**前提確認**
- [ ] Day2-1 完了（`SubmitRetryPolicy` がある）
- [ ] [`06_destinations.md:74-90`](../06_destinations.md)（Redmine の field_mapping 例）を読んだ
- [ ] 既存 `redmine_client.py` を参照できる（無ければ 06 章の例 + Redmine REST 公式仕様で代替）

**手順**
1. `Portfolio.Web/Program.cs` の typed HttpClient 規約に合わせ、アダプタは `HttpClient` をコンストラクタ注入で受ける（`new HttpClient()` 禁止 — `backend/CLAUDE.md`）。`Portfolio.Destinations/Adapters/RedmineDestination.cs`:
   ```csharp
   using System.Net.Http.Json;
   using System.Text.Json;

   namespace Portfolio.Destinations.Adapters;

   public sealed class RedmineDestination(HttpClient http) : ITicketDestination
   {
       public string Kind => "redmine";

       public async Task<TestConnectionResult> TestConnectionAsync(
           DestinationConfig config, CancellationToken ct)
       {
           // PublicConfig から base url を取り出し、GET /users/current.json 等で疎通＋認証確認。
           // X-Redmine-API-Key: {config.SecretValue} ヘッダで認証。
           // 200 → Success / 401 → InvalidApiKey / 403 → Forbidden / 接続不可 → Unreachable
       }

       public async Task<TicketSubmitResult> SubmitAsync(
           Ticket ticket, DestinationConfig config, CancellationToken ct)
       {
           // 1. PublicConfig から base url / project_id を取得
           // 2. FieldMapping["ticket_priority"] で ticket.TicketPriority を priority_id に変換
           //    （default_tracker_id / default_assigned_to_id も FieldMapping から）
           // 3. POST {base}/issues.json { issue: { project_id, subject=Title,
           //       description=BodyMarkdown, priority_id, tracker_id, assigned_to_id } }
           //    ヘッダ X-Redmine-API-Key: {config.SecretValue}
           // 4. SubmitRetryPolicy で送信＋分類＋リトライ
           // 5. 成功 → ExternalId=issue.id, ExternalUrl={base}/issues/{id}
       }
   }
   ```
2. 優先度変換は `DestinationConfig.FieldMapping`（`JsonElement`）から引く。06 章の Redmine 例の形（`ticket_priority.field` / `ticket_priority.values[priority]`）に従う。**マッピングに無い優先度が来たら例外ではなく `normal` 相当のフォールバック**にするか、明示エラーにするかをここで決める（推奨: 設定不備として `FatalFail` 相当のエラーメッセージ）。
3. `Program.cs`（または `AddTicketDestinations`）でこのアダプタ用の typed HttpClient を登録:
   ```csharp
   builder.Services.AddHttpClient<RedmineDestination>(c => c.Timeout = TimeSpan.FromSeconds(30));
   builder.Services.AddSingleton<ITicketDestination>(sp => sp.GetRequiredService<RedmineDestination>());
   ```
   - base url はテナント設定（`PublicConfig`）由来なので、`AddHttpClient` の `BaseAddress` 固定はせず、`SubmitAsync` 内で絶対 URL を組む。
4. **API キーは `config.SecretValue` からのみ取る**。`appsettings` や環境変数にベタ書きしない（BYOK、[`CLAUDE.md`](../../CLAUDE.md)）。ログにキーを出さない。

**完了確認**
- [ ] `DestinationRegistry.Resolve("redmine")` が `RedmineDestination` を返す
- [ ] モック HTTP（後述 Day2-4 のテスト）で「正常起票 → ExternalId/ExternalUrl が埋まる」
- [ ] 優先度マッピングが FieldMapping 経由で priority_id に変換される
- [ ] コード・ログのどこにも API キーがベタ書き/出力されていない

**詰まったら**
- Redmine の認証ヘッダ → `X-Redmine-API-Key`。Basic 認証併用版もあるが MVP は API キーヘッダ一本
- `JsonElement` から値を取りにくい → `PublicConfig.GetProperty("base_url").GetString()` の形。キーが無い場合の `TryGetProperty` ガードを入れる
- 二重起票が怖い → Day2-1 の方針通り「送信成功（2xx）後はリトライしない」。タイムアウトで本文到達が不明なケースは Retryable だが、面接では「本来は冪等キーが欲しい」と課題として語れる

**AI 依頼テンプレ**: なし（最初の 1 個は自分。テストは Day2-4 で AI）

---

## Day2-3. `GitHubIssuesDestination` を実装（同パターン複製）[AI]

**目的**
`RedmineDestination` をテンプレに、GitHub Issues 版を AI に複製させる。`ITicketDestination` の契約と `SubmitRetryPolicy` は共有なので、差分は「エンドポイント・認証ヘッダ・優先度→labels 変換」だけ。

**前提確認**
- [ ] Day2-2 完了（`RedmineDestination` がローカルでテスト green）
- [ ] [`06_destinations.md:92-107`](../06_destinations.md)（GitHub の field_mapping 例 = `labels`）を AI に見せられる

**自分が先に決めること**
- [ ] 認証は GitHub PAT（`Authorization: Bearer {SecretValue}` + `User-Agent` 必須）
- [ ] 対象 repo は `PublicConfig` の `owner` / `repo` から組む（`POST /repos/{owner}/{repo}/issues`）
- [ ] 優先度は `default_labels` + マッピング `labels` を結合して `labels` 配列に入れる

**AI 依頼テンプレ**
```
Portfolio.Destinations/Adapters/RedmineDestination.cs を参考に、同じ ITicketDestination
契約を実装する GitHubIssuesDestination.cs を Portfolio.Destinations/Adapters/ に書いてほしい。

仕様（design/06_destinations.md の GitHub Issues 例に準拠）:
- Kind => "github_issues"（DB の CHECK 制約と一致）
- HttpClient はコンストラクタ注入（new HttpClient 禁止）
- TestConnectionAsync: GET https://api.github.com/repos/{owner}/{repo}
    ヘッダ Authorization: Bearer {config.SecretValue} / User-Agent: easy-chatbot-maker /
    Accept: application/vnd.github+json
    200→Success / 401→InvalidApiKey / 403→Forbidden / 404→Forbidden(repo無権限扱い) / 接続不可→Unreachable
- SubmitAsync: POST https://api.github.com/repos/{owner}/{repo}/issues
    body { title=ticket.Title, body=ticket.BodyMarkdown, labels=[...] }
    labels は FieldMapping の default_labels と ticket_priority.values[priority] を結合
    送信・分類・リトライは SubmitRetryPolicy を Redmine と同じく使う
    成功→ ExternalId=issue.number(文字列), ExternalUrl=issue.html_url
- owner / repo は config.PublicConfig から取得（TryGetProperty でガード）
- System.Text.Json のみ。Newtonsoft 禁止。API キーはログに出さない。appsettings から読まない。

DI 登録（Program.cs か AddTicketDestinations）も Redmine と同じ形で追加してほしい:
AddHttpClient<GitHubIssuesDestination> + AddSingleton<ITicketDestination>(...)
```

**自分の確認ポイント**
- [ ] `DestinationRegistry.Resolve("github_issues")` が解決される
- [ ] `User-Agent` ヘッダが付いている（無いと GitHub API は 403。複製時に落としやすい）
- [ ] 優先度 → labels の結合が 06 章の例どおり（`urgent` は 2 ラベル）
- [ ] リトライ/即失敗が Redmine と同じ `SubmitRetryPolicy` を共有している（独自実装になっていない）
- [ ] API キーがログ/appsettings に出ていない

**詰まったら**
- 403 が消えない → `User-Agent` 欠落か PAT のスコープ不足。`TestConnectionAsync` で `Forbidden` に落ちることを確認
- AI がリトライを独自実装した → Day2-1 の `SubmitRetryPolicy` を使うよう再依頼（境界の二重管理を防ぐ）

---

## Day2-4. アダプタ単体テスト（モック HTTP でリトライ/即失敗を検証）[AI 一次実装 → 自分レビュー]

**目的**
両アダプタの「正常起票 / 401 即失敗 / 5xx でリトライ後失敗 / 接続テスト各分岐」を、外部 API に繋がず検証する。リトライ回数（最大 3 回）が実際に守られることをテストで固定する。

**前提確認**
- [ ] Day2-2 / Day2-3 完了
- [ ] `Portfolio.Web.Tests` が xUnit で動く（Sprint 1 で構築済み）

**自分が先に決めること（ケース定義）**
- [ ] 正常: 2xx → `Success=true`、`ExternalId`/`ExternalUrl` が埋まる
- [ ] 認証: 401 → 1 回で `Success=false`（**リトライしない** = ハンドラ呼出 1 回）、ErrorMessage に auth と分かる文言
- [ ] 一時障害: 500 を返し続ける → ハンドラ呼出 3 回（MaxAttempts）で `Success=false`
- [ ] 一時障害からの回復: 500 → 500 → 200 → `Success=true`（呼出 3 回）
- [ ] 接続テスト: 200/401/403/接続不可 で `TestConnectionResult.FailureReason` が期待値

**AI 依頼テンプレ**
```
RedmineDestination と GitHubIssuesDestination の単体テストを Portfolio.Web.Tests に
xUnit で書いてほしい。実 API には繋がない。

方法: HttpMessageHandler のフェイク（呼出回数を数え、用意したレスポンス列を順に返す）を作り、
それを HttpClient に挿す。バックオフ待ちでテストが遅くならないよう、待機を短縮できる形にする
（SubmitRetryPolicy.Backoff をテストでは無視できるよう、待機を注入可能にするか、テスト用に
小さい遅延へ差し替える。実装の都合に合わせて提案して）。

ケース（Redmine / GitHub 双方）:
1. 2xx → Success=true、ExternalId/ExternalUrl が期待値
2. 401 → Success=false、ハンドラ呼出は 1 回のみ（リトライしない）、ErrorMessage に "auth" を含む
3. 500 を毎回 → Success=false、ハンドラ呼出は 3 回（SubmitRetryPolicy.MaxAttempts）
4. 500,500,200 → Success=true、ハンドラ呼出は 3 回
5. TestConnectionAsync: 200→Success, 401→InvalidApiKey, 403→Forbidden, 接続例外→Unreachable

ファイル: Portfolio.Web.Tests/RedmineDestinationTests.cs / GitHubIssuesDestinationTests.cs
DestinationConfig.SecretValue にはダミー文字列を渡す。
```

**自分の確認ポイント**
- [ ] 全ケース green
- [ ] **わざと `SubmitRetryPolicy.Classify` の 401 を Retryable に変えると、401 のリトライ回数テストが red になる** ことを一度確認（green が偶然でない証拠）
- [ ] テスト全体が数秒で終わる（バックオフ実待ちでハングしていない）

**完了確認**
- [ ] `dotnet test Portfolio.sln` が green
- [ ] リトライ上限と認証即失敗が両アダプタで検証済み

**詰まったら**
- バックオフでテストが遅い → 待機を抽象化（`Func<int,TimeSpan>` 注入 or `TimeProvider`）してテストで 0 に
- フェイクハンドラの呼出回数が合わない → `TestConnection` と `Submit` でハンドラを共有していないか確認

---

## Day 2 終了チェックリスト

- [ ] `RedmineDestination` / `GitHubIssuesDestination` が `Kind` で `DestinationRegistry` から解決できる
- [ ] `SubmitRetryPolicy` が両アダプタ共有で、指数バックオフ最大 3 回・認証/不正リクエスト即失敗
- [ ] 優先度変換が `FieldMapping`（JSONB）経由（Redmine=priority_id / GitHub=labels）
- [ ] アダプタ単体テストが green、「分類を壊すと red」を一度確認
- [ ] コード・ログ・appsettings のどこにも API キーが無い
- [ ] **「RedmineDestination を見せて『同じ契約で別の起票先も書いて』で AI が複製できる」**状態になった

## Day 3 への引き継ぎメモ（自分宛て）

- アダプタは「`SecretValue` に復号済みキーが入っている」前提。Day 3 で Vault から復号して `DestinationConfig` を組む配管をつなぐ
- 起票実行時に `inquiries.status` を更新する（成功 `'created'` / 失敗 `'failed'`）。`status` は `inquiries` の NOT NULL 列（`0001_schema.sql:152`）。`'created'` 遷移時にトリガーがある（`0001_schema.sql:224-238`）ので値を合わせる
- 失敗時 `inquiries.draft_fields`（jsonb）保持、成功時 NULL クリアは Day3-4
