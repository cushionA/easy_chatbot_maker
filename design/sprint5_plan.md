# Sprint 5 実装計画（3 日分）

> 想定読者: 駆け出し Web エンジニアの自分。AI（先輩）にレビューや一次実装を頼みながら進める。
> 期間: 2026-06-04 〜 2026-06-06（3 日、目安）
> テーマ: **埋め込みウィジェット（embed.js）+ 利用ログ分析 + 無料枠運用の締め**
> ゴール: 利用者サイトに `<script>` 一行でチャットボットを埋め込め（shadow DOM 隔離・CORS/Origin チェック・レートリミット・匿名用の限定 RLS）、admin が利用ログ分析とナレッジギャップを見られ、死活対策（Keep-alive ping・Sentry）が入った状態。
> Done の定義は各日末尾のチェックリスト。

## 全体マップ

| 日 | テーマ | 主成果物 |
|---|---|---|
| Day 1 | 匿名アクセスの防御層 | 詳細: [`sprint5/day1.md`](sprint5/day1.md) — `0004_anon_widget_rls.sql`（`app.widget_tenant_id` 限定ポリシー）、公開鍵検証ミドルウェア、`embed.js` 配信エンドポイント（CORS/Origin）、匿名チャット用最小 API |
| Day 2 | ウィジェット本体と分析 | 詳細: [`sprint5/day2.md`](sprint5/day2.md) — `embed.js`（shadow DOM）、レートリミット（テナント/Origin 単位）、利用ログ分析画面（件数・match_strategy 分布・上位 N 問題・未分類推移・低確信度比率） |
| Day 3 | 運用の締め | 詳細: [`sprint5/day3.md`](sprint5/day3.md) — ナレッジギャップ検出、Keep-alive ping（GitHub Actions cron）、Sentry 連携、匿名ポリシー込みの RLS E2E 回帰 |

各 day ファイルは、タスクごとに「**目的 / 前提確認 / 手順（コマンド・コード片レベル）/ 完了確認 / 詰まったら / AI 依頼テンプレ**」の節を持つ作業指示書。明日朝は [`sprint5/day1.md`](sprint5/day1.md) を開いて着手する。

「自分で書く（説明責任が重い箇所）」と「AI に委譲（仕様だけ握る）」の区分は [`09_task_split.md`](09_task_split.md) を継承する。各タスクに **[自分]** / **[AI]** を明記する。

> 前提: Sprint 1〜4 が完了している（RLS 2 ロール構成、`app.tenant_id` セッション変数方式、`DbConnectionInterceptor`、JWT 認証、CRUD、ハイブリッド検索 + 分類フロー、未分類キュー、起票 Adapter が動いている）。本 Sprint は「呼ぶ/利用する」前提でそれらに触れない。

---

## Day 1 — 匿名アクセスの防御層

> 「ログイン済みユーザー用の `app.tenant_id` 経路とは**別の鍵束**を作る」日。匿名ウィジェットは漏れたら全テナントアウトな境界なので、限定 RLS と公開鍵検証は自分の手で型を作り、結線だけ AI に渡す。

- **5-1-1. `0004_anon_widget_rls.sql`（匿名用限定 RLS のお手本）[自分]** — `app.widget_tenant_id` 参照の SELECT/INSERT 限定ポリシーを `knowledge_entries` 1 テーブル分だけ書く
- **5-1-2. 残り 2 テーブルへ匿名ポリシー展開（`inquiries` / `unclassified_queue`）[AI]** — お手本パターンの複製、書込は当該テナント分のみ
- **5-1-3. 公開鍵検証 + widget セッション変数発行ミドルウェア [自分]** — `tenant_public_keys.key_hash` 照合 → `SET LOCAL app.widget_tenant_id` を立てる中核
- **5-1-4. `embed.js` 配信エンドポイント + CORS/Origin チェック [自分]** — `allowed_origins` 照合の配信・プリフライト応答
- **5-1-5. 匿名チャット用最小 API の結線 [AI]** — 既存の分類/検索/未分類登録サービスを匿名コンテキストから呼ぶ最小エンドポイント

## Day 2 — ウィジェット本体と分析

> 「利用者サイトに刺さる JS」と「admin が数字を見る画面」を作る日。集計クエリの定義（何を確信度低と呼ぶか等）は自分が握り、JS と画面実装は AI。

- **5-2-1. 前提確認 + 集計クエリ定義のメモ化 [自分]** — Day1 の API 疎通確認 + 分析に使う SQL 定義の明文化
- **5-2-2. `embed.js`（shadow DOM 隔離・`<script>` 一行）[AI]** — 利用者サイトの CSS と衝突しないウィジェット本体
- **5-2-3. レートリミット（テナント/Origin 単位）[AI]** — `tenant_public_keys.rate_limit_rpm` ベースの固定窓 or トークンバケット
- **5-2-4. 利用ログ分析画面 [AI、集計クエリ定義は自分]** — 件数（日次/週次/月次）・match_strategy 分布・上位 N 問題・未分類推移・低確信度比率

## Day 3 — 運用の締め

> 「無料枠で落とさない・気づける」運用レイヤと、匿名ポリシー追加で既存分離が壊れていないことの回帰。指標定義と回帰ケース定義は自分、実装は AI。

- **5-3-1. ナレッジギャップ検出の指標定義 + 集計骨子 [自分]** — `inquiries.confidence_score` 集計の閾値とリスト定義
- **5-3-2. ナレッジギャップ画面（低確信度リスト + 改善候補可視化）[AI]** — 骨子クエリの UI 化
- **5-3-3. Keep-alive ping（GitHub Actions cron）[AI]** — Supabase Free の 7 日無操作停止防止
- **5-3-4. Sentry 連携（無料枠エラー監視）[AI]** — backend のエラー送信、DSN は環境変数
- **5-3-5. 匿名ポリシー込みの RLS E2E 回帰 [自分がケース定義 → AI 実装]** — `app.widget_tenant_id` 追加で `app.tenant_id` 分離が壊れていないことの保証

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
| CORS プリフライトが通らない | [`08_features.md:79-87`](08_features.md)（CORS/Origin チェックの位置づけ） |
| 低確信度の定義が曖昧 | [`05_search_classification.md:156-176`](05_search_classification.md)（ナレッジギャップ vs 未分類キューの軸の違い） |
| Supabase が勝手に停止していた | Day3-3（Keep-alive cron）、Supabase Free は 7 日無操作で一時停止 |
| cron / Actions の書き方 | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)（既存ジョブ構成が手本） |

## Sprint 5 のあとに残るタスク

- **ウィジェットのテーマ/口調カスタマイズ**（Phase 3、`08_features.md:154`）
- **チャットログのエクスポート・保存期間設定**（Phase 2、`08_features.md:134-141`）
- **PII 自動マスキング**（Phase 2、匿名入力が増えると優先度が上がる）
- **クロスエンコーダ Re-ranker / LLM Query Rewriting**（Phase 2、検索精度強化）
