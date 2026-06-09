# Sprint 5 Day 3 作業指示書（2026-06-06）

> テーマ: **運用の締め**
> 完了時の状態: admin がナレッジギャップ（自信なく回答した問い合わせ）を見て改善候補を判断でき、マネージド Postgres のコールドスタート対策（任意ウォームアップ cron）が入り、エラーが Sentry に飛び、匿名ポリシーを足しても既存テナント分離が壊れていないことが E2E で証明されている
> 推定所要: 6〜8 時間

---

## 5-3-1. ナレッジギャップ検出の指標定義 + 集計骨子 [自分] [設計]

**目的**
「分類はしたが自信が低かった問い合わせ」を集計し、admin が「マスタに足すべき問題」を見つけられる指標を定義する。`inquiries.confidence_score` 集計の閾値・並び・グルーピングを自分で確定し、UI（5-3-2）は AI に渡す。

**自分で書く理由**
これは**指標設計**そのもの。「ナレッジギャップをどう定義した？未分類キューと何が違う？」は面接で確実に問われる。設計書（`05_search_classification.md:156-162`）の「自信低い vs 分類不能」の軸を、自分の言葉と SQL で説明できる必要がある。

**前提確認**
- [ ] `design/05_search_classification.md:156-176`（ナレッジギャップ検出・暗黙シグナル）を読んだ
- [ ] Day2-4 の `THRESHOLD_LOW`（低確信度の閾値）を流用する（新しい閾値を作らない）
- [ ] `inquiries` の `matched_knowledge_id` / `confidence_score` / `raw_query` / `category_id`（`apps/api/src/types/inquiry.ts`）を確認

**指標定義（自分が確定し、5-3-2 の AI 依頼にそのまま渡す）**

ナレッジギャップ = 「分類できた（`matched_knowledge_id IS NOT NULL`）が、確信度が閾値未満（`confidence_score < ThresholdLow`）」の問い合わせ。
未分類キューとの違い: 未分類は `matched_knowledge_id IS NULL`（そもそも当てられなかった）= `unclassified_queue` 側の話。こちらは「当てたが自信がない」。

(G1)(G2) の 2 本を**自分で SQL に起こす**。構造と制約だけ示す（完成 SQL は置かない。閾値・並び・グルーピングを自分で確定するのが本タスク）:

```sql
-- (G1) 低確信度の問い合わせリスト（admin が個別に見て改善判断する）
--   FROM: inquiries を主に、matched_knowledge_id で knowledge_entries、
--         category_id で categories を LEFT JOIN（当てられなかった行も拾えるよう LEFT）
--   選ぶ列: id / raw_query / confidence_score / match_strategy / matched_name / category_name / created_at
--   ここを自分で実装: WHERE 句
--     - confidence_score が NULL でない（= スコア付き）かつ ThresholdLow 未満に絞る
--   ここを自分で実装: 並びと件数
--     - 自信が低い順（confidence_score 昇順）→ 新しい順（created_at 降順）、直近 100 件

-- (G2) マスタ改善候補の集計: どの既存問題が「低確信でばかり当たっているか」
--      = その問題の example_queries / keywords が実クエリと噛み合っていない兆候
--   FROM: inquiries を matched_knowledge_id で knowledge_entries に JOIN、categories は LEFT JOIN
--   選ぶ列: knowledge の id / name、category 名、低確信ヒット数、平均 confidence
--   ここを自分で実装: WHERE で低確信（< ThresholdLow）に絞る
--   ここを自分で実装: group by（問題単位）+ HAVING でノイズ除去
--     - 「たまたま 1 回低かった」を落とす閾値を自分で決める（指標判断のメモに残す）
--   ここを自分で実装: 低確信ヒット数の多い順に並べる
```

ヒント:
- 閾値は Day2-4 の `THRESHOLD_LOW`（暫定 0.5）を流用する。**新しい閾値をここで作らない**
- (G2) の `HAVING` の下限は「example_queries を増やすべき問題」だけを浮かせる目的。低すぎるとノイズ、高すぎると見落とす。自分で決めた根拠を書けるように

> 指標判断: (G2) の `HAVING`（低確信ヒット数の下限）は「たまたま 1 回低かった」をノイズとして落とすため。これにより「example_queries を増やすべき問題」が浮き上がる。これが `unclassified_queue`（新規に作るべき問題）との運用上の使い分け = 「(G2) は既存問題の表現を磨く / 未分類キューは新問題を足す」。

**完了確認**
- [ ] (G1)(G2) を psql または BigQuery コンソールで実行して期待どおりに返る
- [ ] 閾値 0.5 が Day2-4 の `THRESHOLD_LOW` と同じ値（別管理にしない）
- [ ] 「ナレッジギャップ（低確信）」と「未分類キュー（分類不能）」の違いを 1 文で説明できる

**AI 依頼テンプレ**: なし（指標を自分で定義する範囲）

---

## 5-3-2. ナレッジギャップ画面（低確信度リスト + 改善候補可視化）[AI] [FE] [BE]

**目的**
5-3-1 で定義した (G1)(G2) を admin 向けページ `/t/{slug}/knowledge-gaps` に表示する。

**前提確認**
- [ ] 5-3-1 完了、(G1)(G2) の定義が手元にある

**AI 依頼テンプレ**
```
React（TypeScript、apps/web/）で admin 向けナレッジギャップ画面 apps/web/src/pages/KnowledgeGaps.tsx（ルート /t/:slug/knowledge-gaps）を書いてほしい。データは Node API（apps/api/）の GET /api/knowledge-gaps/:slug/* エンドポイント経由で取得する。Node API 側は BigQuery または Postgres で集計クエリを発行し、JWT の tenant_id で絞る（パラメータ化）。JWT を持たないアクセスは 401 を返す。

2 ブロック（定義は以下に固定。指標を勝手に変えない）:
1) 低確信度の問い合わせリスト（直近 100 件）:
   inquiries で confidence_score IS NOT NULL AND confidence_score < THRESHOLD_LOW(=0.5)、
   matched_knowledge_id で knowledge_entries を、category_id で categories を LEFT JOIN、
   confidence_score 昇順 → created_at 降順。
   列: raw_query / confidence_score / match_strategy / matched_name / category_name / created_at。
   各行から該当 knowledge_entry のマスタ編集ページへのリンク（admin が example_queries を足せるよう導線）。
2) マスタ改善候補（集計）:
   confidence_score < 0.5 の inquiries を matched_knowledge_id で group by、
   HAVING count(*) >= 3、low_conf_hits 降順。
   列: name / category_name / low_conf_hits / avg_conf。

注意:
- THRESHOLD_LOW は Day2 の Analytics と同じ定数を共有する（重複定義しない。共通定数モジュールに寄せる）
- グラフライブラリは足さない。<table> で十分
```

**自分の確認ポイント**
- [ ] `THRESHOLD_LOW` が Analytics 画面（Day2-4）と共有されている
- [ ] (G2) の `HAVING >= 3` が入っている
- [ ] マスタ編集への導線がある（改善アクションにつながる）
- [ ] BigQuery/Postgres クエリに `tenant_id` パラメータが渡っており別テナントが混ざらない

**完了確認**
- [ ] `/t/{slug}/knowledge-gaps` に低確信リストと改善候補が当該テナント分で出る
- [ ] 行から該当マスタの編集ページに飛べる

---

## 5-3-3. Keep-alive cron（マネージド Postgres ウォームアップ）[AI] [INFRA]

**目的**
マネージド Postgres は自動停止しない。ただしコールドスタート（接続プールの初期化遅延）対策として、任意でウォームアップ ping を GitHub Actions cron で入れる。必須ではないが入れておくと本番の初回レスポンスが安定する。

**前提確認**
- [ ] `.github/workflows/ci.yml` の既存ジョブ構成（手本）を確認
- [ ] 叩く対象（本番 Node API の `/healthz`、またはマネージド Postgres への軽いクエリ）を決める。**秘匿情報は GitHub Secrets 経由**で、ワークフロー本文にベタ書きしない

**AI 依頼テンプレ**
```
GitHub Actions のワークフロー .github/workflows/keepalive.yml を新規作成してほしい。目的はマネージド Postgres のコールドスタート対策（接続プールのウォームアップ）と本番 Node API の死活確認。

要件:
- on: schedule の cron で 1 日 1〜2 回（例: '17 3 * * *' UTC、日本の昼前後）。workflow_dispatch も付ける（手動実行用）
- permissions: contents: read のみ
- ジョブ keepalive:
  1. 本番ヘルスチェック URL を curl で叩く（--fail --silent --show-error、リトライ 3 回）。URL は secrets.KEEPALIVE_HEALTH_URL から読む
  2. 任意でマネージド Postgres への軽量クエリ（SELECT 1）。接続文字列は secrets.DB_URL_KEEPALIVE（読み取り専用ロール想定）から読む。psql が無ければ skip でよい
- URL/接続文字列はすべて secrets.* 経由。ワークフロー本文に値をベタ書きしない
- 失敗時にジョブが赤くなる（異常に気づける）

既存 .github/workflows/ci.yml の書式（actions/checkout@v4 等のバージョン、concurrency の付け方）に合わせて。
```

**自分の確認ポイント**
- [ ] URL / 接続文字列が `secrets.*` 経由でベタ書きされていない
- [ ] `workflow_dispatch` で手動実行できる（初回検証用）
- [ ] Keep-alive 用ロールは最小権限（`SELECT 1` だけ。`portfolio_app` の鍵を流用しない方が望ましい）

**完了確認**
- [ ] `workflow_dispatch` で手動実行 → green
- [ ] GitHub Secrets に `KEEPALIVE_HEALTH_URL`（必要なら `DB_URL_KEEPALIVE`）を登録した

---

## 5-3-4. Sentry 連携（無料枠エラー監視）[AI] [INFRA]

**目的**
Node API（`apps/api/`）の未処理例外を Sentry に送り、無料枠で本番エラーに気づけるようにする。DSN は Secret Manager / 環境変数で注入し、コード・`.env.example` には書かない。

**前提確認**
- [ ] Sentry の無料プロジェクトを作成し DSN を控えた（`.env.local` / 環境変数へ。コミットしない）
- [ ] `09_task_split.md:62`（Sentry は AI 委譲・Phase 2 想定）を確認

**AI 依頼テンプレ**
```
Node/Express（TypeScript、apps/api/）に Sentry（@sentry/node）を導入してほしい。

要件:
- Sentry.init() を apps/api/src/instrument.ts に切り出し、エントリポイントで最初に import する
- DSN は環境変数 SENTRY_DSN（実値は Secret Manager / .env.local で注入）。.env.example にはプレースホルダのみ。DSN 未設定なら Sentry を無効化して通常起動する（ローカル開発でクラッシュさせない）
- 環境名（environment）と release を設定（release は package.json バージョン or 環境変数 SENTRY_RELEASE）
- tracesSampleRate は無料枠を食い潰さないよう低め（0.1 程度）
- 個人情報・秘匿情報を送らない: beforeSend で Authorization ヘッダ・X-Widget-Key・JWT・SQL パラメータをスクラブ
- 匿名ウィジェット経路（/api/widget）の例外も拾うが、利用者のクエリ本文（raw_query）はスクラブ対象に含める（PII の可能性）

.env.example / コード本文に DSN の実値を書かないこと。プレースホルダのみ。
```

**自分の確認ポイント**
- [ ] DSN が `.env.example` / コード本文にベタ書きされていない（プレースホルダのみ）
- [ ] `beforeSend` で Authorization / `X-Widget-Key` / `raw_query` をスクラブ
- [ ] DSN 未設定でもローカルが落ちずに起動する
- [ ] `tracesSampleRate` が低め（無料枠保護）

**完了確認**
- [ ] わざと例外を投げるテスト用エンドポイントを叩く → Sentry に届く（確認後そのエンドポイントは削除）
- [ ] 送信ペイロードに JWT / 鍵 / SQL パラメータが含まれない

---

## 5-3-5. 匿名ポリシー込みの RLS E2E 回帰 [自分がケース定義 → AI 実装] [TEST]

**目的**
`0004_anon_widget_rls.sql` で `app.widget_tenant_id` 経路を足したことにより、**既存の `app.tenant_id` 分離が壊れていないこと**、かつ**匿名経路自体が越境しないこと**を E2E で証明する。Sprint 1 の `RlsIsolationTests` に匿名ケースを追加する形。

**自分で書く理由**
匿名ポリシー追加は「既存の防御線に穴を空けかねない変更」。どのケースが green であるべきか（= 漏れたらアウトな組合せ）は人間が定義する。`04_security_multitenant.md:168-183` のテスト戦略を匿名軸に拡張する。

**前提確認**
- [ ] Day1〜Day3 のここまで完了
- [ ] Sprint 1 の `apps/api/src/__tests__/rlsIsolation.test.ts`（`@testcontainers/postgresql`）が green
- [ ] `design/04_security_multitenant.md:168-209`（テスト戦略 + 匿名アクセス）を再読

**自分が固定するケースリスト（漏れたらアウト）**
1. **既存分離の非回帰**: `app.tenant_id = A` で接続 → B の `knowledge_entries`/`inquiries`/`unclassified_queue` が SELECT/INSERT/UPDATE/DELETE で見えない・書けない（Sprint 1 のケースが `0004` 適用後も green）
2. **匿名 SELECT 分離**: `app.widget_tenant_id = A` → A の `knowledge_entries` のみ見える、B は 0 行
3. **匿名 INSERT 越境拒否**: `app.widget_tenant_id = A` で B の `tenant_id` を持つ `inquiries`/`unclassified_queue` を INSERT → `WITH CHECK` 違反で失敗
4. **匿名は書けないテーブルに書けない**: `app.widget_tenant_id = A` で `knowledge_entries` に INSERT → 失敗（匿名は SELECT のみ）／`unclassified_queue` を SELECT → 0 行（匿名に SELECT ポリシーなし）
5. **両変数フェイルセーフ**: `app.tenant_id` も `app.widget_tenant_id` も未設定 → 全テーブル 0 行
6. **混線しないこと**: `app.tenant_id = A` を立てても `app.widget_tenant_id` は未設定なら匿名ポリシー経由では 0 行（変数が独立している証明）

**AI 依頼テンプレ**
```
apps/api/src/__tests__/rlsIsolation.test.ts（@testcontainers/postgresql, postgres:16, init.sql + 0001..0004 を順に流す、Vitest or Jest）に、匿名ウィジェット RLS の回帰ケースを追加してほしい。0004_anon_widget_rls.sql を migration の流し込み順に含めること。ES テナント分離テストも同ファイルに追加する（Elasticsearch テストコンテナを使い、bool.filter に tenant_id 条件が必須であることを確認）。

追加ケース（describe('RLS', ...) または同等のグルーピング）:
1. app.tenant_id=A で B の knowledge_entries/inquiries/unclassified_queue が SELECT/INSERT/UPDATE/DELETE で不可（既存ケースが 0004 適用後も green であることの確認）
2. app.widget_tenant_id=A で SELECT → A の knowledge_entries のみ、B は 0 行
3. app.widget_tenant_id=A で B の tenant_id の inquiries/unclassified_queue を INSERT → 例外（WITH CHECK 違反）
4. app.widget_tenant_id=A で knowledge_entries に INSERT → 失敗 / unclassified_queue を SELECT → 0 行
5. 両変数未設定で全テーブル 0 行
6. app.tenant_id=A を立て app.widget_tenant_id 未設定のとき、匿名 SELECT ポリシー経由では 0 行（変数独立の確認）

各ケースを it/test で。テストヘルパで SET LOCAL を使ったセッションを張る。
```

**自分の確認ポイント**
- [ ] 6 ケースすべて green
- [ ] **わざと `0004` の `public_widget_read` の第二引数 `true` を消す（or USING を `true` にする）と一部 red になる**ことを一度確認（green が偶然でない証拠）
- [ ] CI（`.github/workflows/ci.yml`）の RLS テスト実行ステップ / ジョブに `apps/api/src/__tests__/rlsIsolation.test.ts` が含まれる

**完了確認**
- [ ] 6 ケース green + 「ポリシー壊すと red」を一度経験済み
- [ ] 既存の Sprint 1 ケースも引き続き green（非回帰）

---

## Day 3 終了チェックリスト

- [ ] `/t/{slug}/knowledge-gaps` に低確信リスト + 改善候補（`HAVING >= 3`）が出て、マスタ編集に飛べる
- [ ] 低確信閾値が Analytics（Day2-4）と一箇所で共有されている（`THRESHOLD_LOW` 定数）
- [ ] `keepalive.yml` が `workflow_dispatch` で green、URL/接続情報は Secrets 経由
- [ ] Sentry に例外が届き、JWT / 鍵 / `raw_query` 等がスクラブされている、DSN はベタ書きされていない
- [ ] RLS E2E 回帰 6 ケース green（`@testcontainers/postgresql` + Vitest/Jest）、ポリシーを壊すと red になることを確認、既存ケースも非回帰

## Sprint 5 完走後の状態

- 利用者サイトに `<script>` 一行でチャットボットが埋め込め（TypeScript バンドル・shadow DOM）、匿名アクセスは `app.widget_tenant_id` 限定 RLS + 公開鍵 + CORS/Origin + レートリミット（DB ベース）で多層に守られている
- admin が利用ログ分析（BigQuery 集計・React 画面）とナレッジギャップを数字で見られ、改善アクション（example_queries の追加）に繋げられる
- マネージド Postgres コールドスタート対策（Keep-alive cron）と本番エラー監視（Sentry for Node API）が入り、無料枠で「遅延なく起動・気づける」運用になった
- 匿名ポリシー追加後も既存テナント分離が壊れていないことが E2E で保証されている（ES テナント分離テストも含む）

次は Phase 2（Re-ranker / HyDE による検索強化、非構造文書 RAG、会話ログ管理）に着手。
