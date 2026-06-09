# Sprint 3 Day 2 作業指示書（2026-05-28）

> テーマ: **アダプタを実装する**
> 完了時の状態: `RedmineDestination` と `GitHubIssuesDestination` の 2 実装が `DestinationRegistry` から解決でき、`testConnection` / `submit` がモック HTTP テストで green。起票失敗時のリトライ（指数バックオフ最大 3 回）と認証エラー即失敗が分岐する。
> 推定所要: 6〜8 時間

> 参照の正: [`06_destinations.md:70-107`](../06_destinations.md)（フィールドマッピング）、[`06_destinations.md:146-164`](../06_destinations.md)（失敗時挙動）、[`10_existing_streamlit.md:100-111`](../10_existing_streamlit.md)（`redmine_client.py`）。
> 前提: API キーはこの時点では「`DestinationConfig.secretValue` に取得済みで入っている」前提で書く。Secret Manager 連携は Day 3。

---

## Day2-1. 共通の起票失敗分類 + リトライ方針を決める [自分] [BE]

**目的**
「リトライしてよい失敗」と「即失敗にすべき失敗」を分ける境界を確定する。06 章のフロー図（[`06_destinations.md:146-164`](../06_destinations.md)）を、両アダプタが共有する 1 つのポリシーに落とす。ここを先に握れば、Redmine / GitHub の実装は「ポリシーに従って投げるだけ」になる。

**自分で書く理由**
リトライ境界を誤ると、認証エラー（401/403）を 3 回叩いて遅延だけ増やす、あるいは一時障害（5xx/タイムアウト）で即諦めてユーザー体験を損なう。失敗ハンドリングの設計判断は面接で語る対象（「冪等性の無い起票で安易に全リトライすると二重起票になる。だから一時障害だけに絞った」）。

**前提確認**
- [ ] Day 1 完了（`TicketSubmitResult` / `TestConnectionResult` がある）
- [ ] [`06_destinations.md:146-164`](../06_destinations.md) を読んだ

**手順**
1. `apps/api/src/destinations/retryPolicy.ts` に「再試行可否の判定」と「指数バックオフ」を 1 箇所に集約する。**分類の境界そのものがこのタスクの中核なので、型とシグネチャだけ示し、分岐ロジックは自分で書く**:
   ```typescript
   // 起票 API 応答をどう扱うかの分類。HTTP ステータスと例外種別から決める。
   export type SubmitOutcome = 'success' | 'retryableFail' | 'fatalFail';
   //   success      : 2xx
   //   retryableFail: ネットワーク例外 / タイムアウト / 5xx / 429
   //   fatalFail    : 401/403（認証・権限）/ その他 4xx（不正リクエスト）→ 即失敗

   export const MAX_ATTEMPTS = 3; // 06 章「最大3回」

   // HttpStatus / 例外 → SubmitOutcome の分類は各アダプタで使う。
   export function classify(
     httpStatus: number | null,
     isNetworkOrTimeout: boolean
   ): SubmitOutcome {
     // ここを自分で実装: 06 章 06_destinations.md:146-164 のフローに従って分類する。
     //   - ネットワーク例外 / タイムアウト → retryableFail
     //   - httpStatus が無い（応答取得前に失敗）→ retryableFail
     //   - 2xx → success
     //   - 401 / 403（認証・権限）→ fatalFail（即失敗。3 回叩いても無駄）
     //   - 429 / 5xx（一時障害）→ retryableFail
     //   - その他 4xx（不正リクエスト）→ fatalFail
     throw new Error('not implemented');
   }

   // attempt は 0 始まり。バックオフは 1s, 2s, 4s（指数 = 2^attempt 秒）。
   export function backoff(attempt: number): number {
     // ここを自分で実装: 2 の attempt 乗（ミリ秒）を返す。
     throw new Error('not implemented');
   }
   ```
2. リトライ実行の小さなヘルパ（`submit` 用）を同ファイルか別ファイルに置く。**冪等性が無い起票なので、リトライは「送信前に確実に失敗が分かったケース（接続失敗・5xx で本文未到達）」に限る**方針をコメントで明記。外部リトライライブラリを使ってもよいが、MVP は自前ループで十分:
   ```typescript
   // 擬似コード方針（実装は各アダプタ内 or 共通ヘルパ）:
   // for attempt in 0..MAX_ATTEMPTS-1:
   //   送信 → classify
   //   success      → return 成功
   //   fatalFail    → return 失敗（即）
   //   retryableFail→ 最終試行なら失敗 return、そうでなければ await sleep(backoff(attempt)) して continue
   ```
3. 認証エラー（`fatalFail` のうち 401/403）は `TicketSubmitResult.errorMessage` に「auth」と分かる文言を入れ、UI が destination 切替提案を出せるようにする（[`06_destinations.md:161`](../06_destinations.md)）。

**完了確認**
- [ ] `classify` の単体テスト（200/401/403/400/429/500/タイムアウト）を自分で 1 つ書いて全分岐確認
- [ ] 「リトライは冪等性の無い起票で二重起票を生まない範囲に限る」コメントがコード上にある

**詰まったら**
- 429 を fatalFail にすべきか迷う → retryableFail（Retry-After を尊重するのが理想だが MVP は固定バックオフでよい）
- リトライライブラリを入れたい → 可。ただし依存追加は `package.json` に明記。MVP は自前で十分

**AI 依頼テンプレ**: なし（分類の境界を自分で決める範囲。`classify` のテストだけ AI に増やしてもらってよい）

---

## Day2-2. `RedmineDestination` を実装（既存 `redmine_client.py` から移植）= 最初の 1 個 [自分] [BE]

**目的**
**Adapter パターンの「最初の 1 個」を自分の手で書く**（[`09_task_split.md:81`](../09_task_split.md) で明示）。既存 Streamlit 版 `redmine_client.py` の REST 呼出パターンを `ITicketDestination` 実装に再構成する。これが GitHub Issues 複製のテンプレになる。

**自分で書く理由**
「最初の 1 個」は型を確定させる作業で、ここを自分で通せば 2 個目を AI に複製させても挙動を保証できる。Redmine REST の認証ヘッダ・優先度マッピング・URL 組立を自分の手で通すことで、面接で「Adapter の中身まで説明できる」状態になる。

**前提確認**
- [ ] Day2-1 完了（`retryPolicy.ts` がある）
- [ ] [`06_destinations.md:74-90`](../06_destinations.md)（Redmine の field_mapping 例）を読んだ
- [ ] 既存 `redmine_client.py` を参照できる（無ければ 06 章の例 + Redmine REST 公式仕様で代替）

**手順**
1. アダプタは HTTP クライアントをコンストラクタ注入で受ける（内部で `new` しない）。`apps/api/src/destinations/adapters/RedmineDestination.ts`:
   ```typescript
   import type { ITicketDestination, DestinationConfig, Ticket,
                  TicketSubmitResult, TestConnectionResult } from '../types';

   export class RedmineDestination implements ITicketDestination {
     readonly kind = 'redmine';

     // HTTP クライアント（fetch ラッパ or axios インスタンス）はコンストラクタ注入。
     // テストでモック差し替えできるようにするため。
     constructor(private readonly http: /* fetch 互換の型 */ unknown) {}

     async testConnection(config: DestinationConfig): Promise<TestConnectionResult> {
       // publicConfig から base url を取り出し、GET /users/current.json 等で疎通＋認証確認。
       // X-Redmine-API-Key: {config.secretValue} ヘッダで認証。
       // 200 → success / 401 → invalidApiKey / 403 → forbidden / 接続不可 → unreachable
     }

     async submit(ticket: Ticket, config: DestinationConfig): Promise<TicketSubmitResult> {
       // 1. publicConfig から base url / project_id を取得
       // 2. fieldMapping['ticket_priority'] で ticket.priority を priority_id に変換
       //    （default_tracker_id / default_assigned_to_id も fieldMapping から）
       // 3. POST {base}/issues.json { issue: { project_id, subject: ticket.title,
       //       description: ticket.bodyMarkdown, priority_id, tracker_id, assigned_to_id } }
       //    ヘッダ X-Redmine-API-Key: {config.secretValue}
       // 4. retryPolicy で送信＋分類＋リトライ
       // 5. 成功 → externalId=issue.id, externalUrl={base}/issues/{id}
     }
   }
   ```
2. 優先度変換は `DestinationConfig.fieldMapping`（`Record<string, unknown>`）から引く。06 章の Redmine 例の形（`ticket_priority.field` / `ticket_priority.values[priority]`）に従う。**マッピングに無い優先度が来たら、設定不備として `fatalFail` 相当のエラーメッセージ**を返す。
3. DI/ファクトリ（`bootstrap.ts`）でこのアダプタ用の HTTP クライアントを渡して生成し、`createDestinationRegistry` の配列に追加する。
4. **API キーは `config.secretValue` からのみ取る**。アプリ設定ファイルや環境変数にベタ書きしない（BYOK）。ログにキーを出さない。

**完了確認**
- [ ] `DestinationRegistry.resolve("redmine")` が `RedmineDestination` を返す
- [ ] モック HTTP（後述 Day2-4 のテスト）で「正常起票 → externalId/externalUrl が埋まる」
- [ ] 優先度マッピングが fieldMapping 経由で priority_id に変換される
- [ ] コード・ログのどこにも API キーがベタ書き/出力されていない

**詰まったら**
- Redmine の認証ヘッダ → `X-Redmine-API-Key`。Basic 認証併用版もあるが MVP は API キーヘッダ一本
- `Record<string, unknown>` から値を取りにくい → `(config.publicConfig as Record<string,unknown>)['base_url']` の形。キーが無い場合のガードを入れる
- 二重起票が怖い → Day2-1 の方針通り「送信成功（2xx）後はリトライしない」。タイムアウトで本文到達が不明なケースは retryableFail だが、面接では「本来は冪等キーが欲しい」と課題として語れる

**AI 依頼テンプレ**: なし（最初の 1 個は自分。テストは Day2-4 で AI）

---

## Day2-3. `GitHubIssuesDestination` を実装（同パターン複製）[AI] [BE]

**目的**
`RedmineDestination` をテンプレに、GitHub Issues 版を AI に複製させる。`ITicketDestination` の契約と `retryPolicy` は共有なので、差分は「エンドポイント・認証ヘッダ・優先度→labels 変換」だけ。

**前提確認**
- [ ] Day2-2 完了（`RedmineDestination` がローカルでテスト green）
- [ ] [`06_destinations.md:92-107`](../06_destinations.md)（GitHub の field_mapping 例 = `labels`）を AI に見せられる

**自分が先に決めること**
- [ ] 認証は GitHub PAT（`Authorization: Bearer {secretValue}` + `User-Agent` 必須）
- [ ] 対象 repo は `publicConfig` の `owner` / `repo` から組む（`POST /repos/{owner}/{repo}/issues`）
- [ ] 優先度は `default_labels` + マッピング `labels` を結合して `labels` 配列に入れる

**AI 依頼テンプレ**
```
apps/api/src/destinations/adapters/RedmineDestination.ts を参考に、同じ ITicketDestination
契約を実装する GitHubIssuesDestination.ts を apps/api/src/destinations/adapters/ に書いてほしい。

仕様（design/06_destinations.md の GitHub Issues 例に準拠）:
- kind = "github_issues"（DB の CHECK 制約と一致）
- HTTP クライアントはコンストラクタ注入（内部で new しない）
- testConnection: GET https://api.github.com/repos/{owner}/{repo}
    ヘッダ Authorization: Bearer {config.secretValue} / User-Agent: easy-chatbot-maker /
    Accept: application/vnd.github+json
    200→success / 401→invalidApiKey / 403→forbidden / 404→forbidden(repo無権限扱い) / 接続不可→unreachable
- submit: POST https://api.github.com/repos/{owner}/{repo}/issues
    body { title: ticket.title, body: ticket.bodyMarkdown, labels: [...] }
    labels は fieldMapping の default_labels と ticket_priority.values[priority] を結合
    送信・分類・リトライは retryPolicy.ts を Redmine と同じく使う
    成功→ externalId=issue.number(文字列), externalUrl=issue.html_url
- owner / repo は config.publicConfig から取得（存在チェック付き）
- 外部ライブラリは最小限。API キーはログに出さない。アプリ設定から読まない。

DI/ファクトリ（bootstrap.ts）も Redmine と同じ形で追加してほしい:
createDestinationRegistry の配列に GitHubIssuesDestination インスタンスを追加
```

**自分の確認ポイント**
- [ ] `DestinationRegistry.resolve("github_issues")` が解決される
- [ ] `User-Agent` ヘッダが付いている（無いと GitHub API は 403。複製時に落としやすい）
- [ ] 優先度 → labels の結合が 06 章の例どおり（`urgent` は 2 ラベル）
- [ ] リトライ/即失敗が Redmine と同じ `retryPolicy.ts` を共有している（独自実装になっていない）
- [ ] API キーがログ/アプリ設定に出ていない

**詰まったら**
- 403 が消えない → `User-Agent` 欠落か PAT のスコープ不足。`testConnection` で `forbidden` に落ちることを確認
- AI がリトライを独自実装した → Day2-1 の `retryPolicy.ts` を使うよう再依頼（境界の二重管理を防ぐ）

---

## Day2-4. アダプタ単体テスト（msw/nock でモック HTTP、リトライ/即失敗を検証）[AI 一次実装 → 自分レビュー] [TEST]

**目的**
両アダプタの「正常起票 / 401 即失敗 / 5xx でリトライ後失敗 / 接続テスト各分岐」を、外部 API に繋がず検証する。リトライ回数（最大 3 回）が実際に守られることをテストで固定する。

**前提確認**
- [ ] Day2-2 / Day2-3 完了
- [ ] Vitest（または Jest）が動く（Sprint 1 で構築済み）

**自分が先に決めること（ケース定義）**
- [ ] 正常: 2xx → `success: true`、`externalId`/`externalUrl` が埋まる
- [ ] 認証: 401 → 1 回で `success: false`（**リトライしない** = ハンドラ呼出 1 回）、errorMessage に auth と分かる文言
- [ ] 一時障害: 500 を返し続ける → ハンドラ呼出 3 回（MAX_ATTEMPTS）で `success: false`
- [ ] 一時障害からの回復: 500 → 500 → 200 → `success: true`（呼出 3 回）
- [ ] 接続テスト: 200/401/403/接続不可 で `TestConnectionResult.failureReason` が期待値

**AI 依頼テンプレ**
```
RedmineDestination と GitHubIssuesDestination の単体テストを
apps/api/src/destinations/__tests__/ に Vitest（または Jest）で書いてほしい。実 API には繋がない。

方法: msw（または nock）で HTTP をモックし、呼出回数を記録してレスポンス列を順に返す。
バックオフ待ちでテストが遅くならないよう、待機時間を注入できる形にする
（retryPolicy.ts の backoff 関数をテストでは 0ms を返す関数に差し替える、
あるいは sleep 関数を注入可能にする。実装の都合に合わせて提案して）。

ケース（Redmine / GitHub 双方）:
1. 2xx → success: true、externalId/externalUrl が期待値
2. 401 → success: false、ハンドラ呼出は 1 回のみ（リトライしない）、errorMessage に "auth" を含む
3. 500 を毎回 → success: false、ハンドラ呼出は 3 回（MAX_ATTEMPTS）
4. 500,500,200 → success: true、ハンドラ呼出は 3 回
5. testConnection: 200→success, 401→invalidApiKey, 403→forbidden, 接続例外→unreachable

ファイル: apps/api/src/destinations/__tests__/RedmineDestination.test.ts /
          apps/api/src/destinations/__tests__/GitHubIssuesDestination.test.ts
DestinationConfig.secretValue にはダミー文字列を渡す。
```

**自分の確認ポイント**
- [ ] 全ケース green
- [ ] **わざと `classify` の 401 を retryableFail に変えると、401 のリトライ回数テストが red になる** ことを一度確認（green が偶然でない証拠）
- [ ] テスト全体が数秒で終わる（バックオフ実待ちでハングしていない）

**完了確認**
- [ ] `pnpm test` が green
- [ ] リトライ上限と認証即失敗が両アダプタで検証済み

**詰まったら**
- バックオフでテストが遅い → sleep 関数を引数で注入するか、vi.useFakeTimers() でタイマーを制御する
- モックのリクエスト回数が合わない → `testConnection` と `submit` でモックを共有していないか確認

---

## Day 2 終了チェックリスト

- [ ] `RedmineDestination` / `GitHubIssuesDestination` が `kind` で `DestinationRegistry` から解決できる
- [ ] `retryPolicy.ts` が両アダプタ共有で、指数バックオフ最大 3 回・認証/不正リクエスト即失敗
- [ ] 優先度変換が `fieldMapping`（JSONB）経由（Redmine=priority_id / GitHub=labels）
- [ ] アダプタ単体テストが green、「分類を壊すと red」を一度確認
- [ ] コード・ログ・アプリ設定のどこにも API キーが無い
- [ ] **「RedmineDestination を見せて『同じ契約で別の起票先も書いて』で AI が複製できる」**状態になった

## Day 3 への引き継ぎメモ（自分宛て）

- アダプタは「`secretValue` に取得済みキーが入っている」前提。Day 3 で Secret Manager から取得して `DestinationConfig` を組む配管をつなぐ
- 起票実行時に `inquiries.status` を更新する（成功 `'created'` / 失敗 `'failed'`）。`status` は `inquiries` の NOT NULL 列（`0001_schema.sql:152`）。`'created'` 遷移時にトリガーがある（`0001_schema.sql:224-238`）ので値を合わせる
- 失敗時 `inquiries.draft_fields`（jsonb）保持、成功時 NULL クリアは Day3-4
