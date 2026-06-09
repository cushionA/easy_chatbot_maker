# Sprint 5 実装計画（3 日分）

> 想定読者: 駆け出し Web エンジニアの自分。AI（先輩）にレビューや一次実装を頼みながら進める。
> 期間: 2026-06-04 〜 2026-06-06（3 日、目安）
> テーマ: **埋め込みウィジェット（embed.js）+ 利用ログ分析 + 無料枠運用の締め**
> ゴール: 利用者サイトに `<script>` 一行でチャットボットを埋め込め（shadow DOM 隔離・CORS/Origin チェック・レートリミット・匿名用の限定 RLS）、admin が利用ログ分析とナレッジギャップを見られ、死活対策（Keep-alive ping・Sentry）が入った状態。
> Done の定義は各日末尾のチェックリスト。

## 全体マップ

| 日 | テーマ | 主成果物 |
|---|---|---|
| Day 1 | 匿名アクセスの防御層 | 詳細: [`sprint5/day1.md`](sprint5/day1.md) — `0004_anon_widget_rls.sql`（`app.widget_tenant_id` 限定ポリシー）、公開鍵検証 Node ミドルウェア、`embed.js` 配信エンドポイント（CORS/Origin）、匿名チャット用最小 API（`apps/api/`） |
| Day 2 | ウィジェット本体と分析 | 詳細: [`sprint5/day2.md`](sprint5/day2.md) — `embed.js`（TypeScript バンドル・shadow DOM）、レートリミット（テナント/Origin 単位）、利用ログ分析画面（BigQuery 集計・件数・match_strategy 分布・上位 N 問題・未分類推移・低確信度比率） |
| Day 3 | 運用の締め | 詳細: [`sprint5/day3.md`](sprint5/day3.md) — ナレッジギャップ検出（BigQuery/Postgres 集計・React 画面）、Keep-alive cron（マネージド Postgres 向け任意ウォームアップ）、Sentry 連携、匿名ポリシー込みの RLS E2E 回帰 |

各 day ファイルは、タスクごとに「**目的 / 前提確認 / 手順（コマンド・コード片レベル）/ 完了確認 / 詰まったら / AI 依頼テンプレ**」の節を持つ作業指示書。明日朝は [`sprint5/day1.md`](sprint5/day1.md) を開いて着手する。

「自分で書く（説明責任が重い箇所）」と「AI に委譲（仕様だけ握る）」の区分は [`09_task_split.md`](09_task_split.md) を継承する。各タスクに **[自分]** / **[AI]** を明記する。

さらに各タスクに **層ラベル**（`[FE]` フロントエンド / `[BE]` バックエンド / `[INFRA]` インフラ / `[TEST]` テスト / `[ML]` 機械学習 / `[設計]` 上流設計）を付け、フルスタックの守備範囲を可視化する。複数層にまたがるタスクは主たる層を先頭に併記する。

> 前提: Sprint 1〜4 が完了している（RLS 2 ロール構成、`app.tenant_id` セッション変数方式、Node ミドルウェア（`TenantResolutionMiddleware`）、JWT 認証、CRUD、ハイブリッド検索 + 分類フロー、未分類キュー、起票 Adapter が動いている）。本 Sprint は「呼ぶ/利用する」前提でそれらに触れない。

---

## Day 1 — 匿名アクセスの防御層

> 「ログイン済みユーザー用の `app.tenant_id` 経路とは**別の鍵束**を作る」日。匿名ウィジェットは漏れたら全テナントアウトな境界なので、限定 RLS と公開鍵検証は自分の手で型を作り、結線だけ AI に渡す。

- **5-1-1. `0004_anon_widget_rls.sql`（匿名用限定 RLS のお手本）[自分] [INFRA]** — `app.widget_tenant_id` 参照の SELECT/INSERT 限定ポリシーを `knowledge_entries` 1 テーブル分だけ書く
- **5-1-2. 残り 2 テーブルへ匿名ポリシー展開（`inquiries` / `unclassified_queue`）[AI] [INFRA]** — お手本パターンの複製、書込は当該テナント分のみ
- **5-1-3. 公開鍵検証 + widget セッション変数発行ミドルウェア [自分] [BE]** — `tenant_public_keys.key_hash` 照合 → Node ミドルウェアで `SET LOCAL app.widget_tenant_id` を立てる中核（`apps/api/src/middleware/widgetAuth.ts`）
- **5-1-4. `embed.js` 配信エンドポイント + CORS/Origin チェック [自分] [BE] [FE]** — `allowed_origins` 照合の配信・プリフライト応答（Node API + TypeScript/JS バンドル）
- **5-1-5. 匿名チャット用最小 API の結線 [AI] [BE]** — 既存の分類/検索/未分類登録サービスを匿名コンテキストから呼ぶ最小エンドポイント（`apps/api/`）

## Day 2 — ウィジェット本体と分析

> 「利用者サイトに刺さる JS」と「admin が数字を見る画面」を作る日。集計クエリの定義（何を確信度低と呼ぶか等）は自分が握り、JS と画面実装は AI。

- **5-2-1. 前提確認 + 集計クエリ定義のメモ化 [自分] [設計]** — Day1 の API 疎通確認 + 分析に使う SQL/BigQuery クエリ定義の明文化
- **5-2-2. `embed.js`（shadow DOM 隔離・`<script>` 一行）[AI] [FE]** — 利用者サイトの CSS と衝突しないウィジェット本体（TypeScript バンドル、`apps/web/` 配下の専用パッケージ）
- **5-2-3. レートリミット（テナント/Origin 単位）[AI] [BE]** — `tenant_public_keys.rate_limit_rpm` ベースの固定窓（Node API、Phase2 で Redis に移行）
- **5-2-4. 利用ログ分析画面 [AI、集計クエリ定義は自分] [FE] [BE]** — 件数（日次/週次/月次）・match_strategy 分布・上位 N 問題・未分類推移・低確信度比率（BigQuery 集計 + React + Node API）

## Day 3 — 運用の締め

> 「無料枠で落とさない・気づける」運用レイヤと、匿名ポリシー追加で既存分離が壊れていないことの回帰。指標定義と回帰ケース定義は自分、実装は AI。

- **5-3-1. ナレッジギャップ検出の指標定義 + 集計骨子 [自分] [設計]** — `inquiries.confidence_score` 集計の閾値とリスト定義（BigQuery or Postgres 集計）
- **5-3-2. ナレッジギャップ画面（低確信度リスト + 改善候補可視化）[AI] [FE] [BE]** — 骨子クエリの UI 化（React + Node API）
- **5-3-3. Keep-alive cron（マネージド Postgres ウォームアップ）[AI] [INFRA]** — マネージド Postgres は自動停止なし。コールドスタート対策の任意ウォームアップ（GitHub Actions cron）
- **5-3-4. Sentry 連携（無料枠エラー監視）[AI] [INFRA]** — Node API のエラー送信、DSN は Secret Manager / 環境変数
- **5-3-5. 匿名ポリシー込みの RLS E2E 回帰 [自分がケース定義 → AI 実装] [TEST]** — `app.widget_tenant_id` 追加で `app.tenant_id` 分離が壊れていないことの保証（`@testcontainers/postgresql` + Vitest/Jest）

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
| 匿名 RLS が効かない / 全件見える | [`04_security_multitenant.md:185-209`](04_security_multitenant.md)（`app.widget_tenant_id` を別変数にする理由） |
| ログイン経路と匿名経路が混線する | [`04_security_multitenant.md:207`](04_security_multitenant.md)（変数を分ける） |
| CORS プリフライトが通らない | [`08_features.md:79-87`](08_features.md)（CORS/Origin チェックの位置づけ）、Node の `cors` パッケージの `origin` コールバック設定を確認 |
| 低確信度の定義が曖昧 | [`05_search_classification.md:156-176`](05_search_classification.md)（ナレッジギャップ vs 未分類キューの軸の違い） |
| BigQuery 権限エラー | Secret Manager の SA（サービスアカウント）に `bigquery.dataViewer` / `bigquery.jobUser` が付いているか確認 |
| Shadow DOM でスタイルが崩れる | embed.js の `attachShadow` + `<style>` が shadow root 内に閉じているか確認。`!important` を使っていないか |
| ES のテナントフィルタが抜ける | Elasticsearch クエリの `bool.filter` に `tenant_id` 一致条件が含まれているか確認（匿名経路も同様） |
| cron / Actions の書き方 | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)（既存ジョブ構成が手本） |

## Sprint 5 のあとに残るタスク

- **ウィジェットのテーマ/口調カスタマイズ**（Phase 3、`08_features.md:154`）
- **チャットログのエクスポート・保存期間設定**（Phase 2、`08_features.md:134-141`）
- **PII 自動マスキング**（Phase 2、匿名入力が増えると優先度が上がる）
- **クロスエンコーダ Re-ranker / LLM Query Rewriting**（Phase 2、検索精度強化）
