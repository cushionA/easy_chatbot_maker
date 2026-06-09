# 設計記録（Service A：RAGチャットボット生成サービス）

## ステータス

- **フェーズ**：設計フェーズ **完了** / 実装フェーズ **Sprint 0 完了、Sprint 1 着手前**
- **対象**：Service A（RAGチャットボット生成サービス）のみ
- **Service B（Ronkaku）**：並行度低、Service A 構築中の流用候補としてのみ意識
- **技術スタック再構築（設計層）完了**：C#/.NET + Supabase 構成から、**TypeScript / Node.js 中心フルスタック**（React + Node API、E2E テストは Playwright）+ Elasticsearch + BigQuery + Docker/Kubernetes（マルチクラウド）構成へ。ML 推論のみ Python。Web クロール収集は製品ドメインに噛み合わないため不採用。**PR2–PR4 完了**：設計章 01–13・09 タスク分担・10 PoC マッピング・各 Sprint plan（1–6, plan+day 全 23 ファイル）を新スタックへ整合（PostgreSQL メタ + Elasticsearch 検索 + BigQuery 分析 + Secret Manager + OIDC + Node データ層、RLS・2 ロール・BYOK は維持）。残りは **実コード**（backend C#→Node/TS、各 CLAUDE.md、CI）。
- **最終更新**：2026-06-10

## ドキュメント構成

| ファイル | 内容 |
|---|---|
| [01_overview.md](01_overview.md) | サービス概要、差別化、訴求先 |
| [02_architecture.md](02_architecture.md) | 技術スタック、システム構成、ホスティング |
| [03_db_schema.md](03_db_schema.md) | DBスキーマ全体（SQL）、インデックス、RLS |
| [04_security_multitenant.md](04_security_multitenant.md) | 認証、RLS、Secret Manager、テナント分離 |
| [05_search_classification.md](05_search_classification.md) | 分類フロー、ハイブリッド検索、ランキング |
| [06_destinations.md](06_destinations.md) | 起票先抽象化、Adapter、フィールドマッピング |
| [07_data_strategy.md](07_data_strategy.md) | データ配置3層、最小化戦略 |
| [08_features.md](08_features.md) | MVP / Phase 2 / Phase 3 機能リスト |
| [09_task_split.md](09_task_split.md) | 座布団さん自身が書く部分 vs AI に任せる部分 |
| [sprint1_plan.md](sprint1_plan.md) | Sprint 1（認証 + RLS + 最初の CRUD）を 3 日分に分解した実装計画（2026-05-17〜19） |
| [sprint2_plan.md](sprint2_plan.md) | Sprint 2（分類エンジン: ハイブリッド検索 + 閾値 + LLM フォールバック）を 3 日分に分解した実装計画（2026-05-22〜26） |
| [sprint3_plan.md](sprint3_plan.md) | Sprint 3（起票: ITicketDestination + Redmine/GitHub + Secret Manager）を 3 日分に分解した実装計画（2026-05-27〜29） |
| [sprint4_plan.md](sprint4_plan.md) | Sprint 4（チャット UI + 動的フォーム + 3段階エスカレーション + 未分類キュー）を 3 日分に分解した実装計画（2026-06-01〜03） |
| [sprint5_plan.md](sprint5_plan.md) | Sprint 5（埋め込みウィジェット + 利用ログ分析 + 無料枠運用）を 3 日分に分解した実装計画（2026-06-04〜06） |
| [sprint6_plan.md](sprint6_plan.md) | Sprint 6（マスタ管理の作り込み: KnowledgeEntry リッチ編集 + FieldDefinition/ValidationRule CRUD + Excel/JSON 取込）を 2 日分に分解した実装計画（2026-06-12〜13） |
| [10_existing_streamlit.md](10_existing_streamlit.md) | 既存 Streamlit 版からの流用・発展 |
| [11_open_questions.md](11_open_questions.md) | 未確定の運用判断・要検証項目 |
| [12_interview_narratives.md](12_interview_narratives.md) | 面接訴求ポイント集 |
| [13_testing_strategy.md](13_testing_strategy.md) | テスト戦略・テスト仕様（ピラミッド / E2E / RLS 越境 / 検索回帰 / CI）|

## クイックリファレンス（主要決定事項）

| 項目 | 決定 |
|---|---|
| 技術スタック | **TypeScript / Node.js 中心フルスタック**（React フロント + Node API + Playwright E2E テスト）、ML のみ Python |
| ホスティング | **マルチクラウド**（AWS / GCP / Azure 可）、Docker / Kubernetes で可搬。BigQuery は GCP |
| DB | PostgreSQL + RLS（メタ/テナント）、Elasticsearch / OpenSearch（検索）、BigQuery（DWH）|
| テナント分離 | Row Level Security (RLS) + `current_setting('app.tenant_id')` 直接方式 |
| 認証 | OIDC（JWT 検証 + JWKS）、Node API が DB に直接接続するためテナント解決はアプリ層で完結 |
| シークレット | Secret Manager（AWS / GCP、BYOK の LLM キー暗号化保管）|
| DB ロール分離 | `portfolio_owner`（マイグレーション）/ `portfolio_app`（アプリ・`NOBYPASSRLS`）|
| LLM | Gemini API（BYOK専用） |
| テスト | Playwright（E2E: 主要フロー + RLS 越境検証）+ Vitest / Jest（単体・結合）+ GitHub Actions CI |
| Embedding | intfloat/multilingual-e5-base、Python FastAPI 推論サービス（唯一の Python、ONNX/Node 化で TS 統一可）|
| 検索戦略 | Elasticsearch BM25 + kNN ハイブリッド (RRF) + match_count 重み |
| 分類フロー | カテゴリ → コンボボックス → 自然言語 → キーワード完全一致 → ハイブリッド → LLM(BYOK) → 未分類キュー |
| 起票先 | ITicketDestination 抽象、Redmine + GitHub Issues、プライマリ＋切替 |
| データ戦略 | 本文は外部システム(Redmine/GitHub)、サーバはメタ + インデックス(ES) + 利用ログ(BigQuery) |
| URL形式 | `/t/{slug}/chat` |
| ロール | admin / member の2階層 |
| 月額 | 無料枠中心（収集・検索・DWH のスケールで段階課金）|

## 明示的に却下した設計

| 却下した案 | 理由 |
|---|---|
| KNN over 過去問い合わせ | Embedding と効果重複、複雑度倍化に見合わず → `match_count` 重みで代替 |
| 👍/👎 フィードバック | 回答が事前定義で生成型でない → 暗黙シグナルで代替 |
| 別テーブル `tenant_synonyms` | `example_queries` 列に統合 |
| Schema-per-tenant | 無料枠で1000テナント不可、RLS で十分 |
| Git連携マスタ取込（MVP） | 非エンジニア利用者に酷 → Phase 2 |
| fan-out 起票 | 部分失敗対応が重い → Phase 2 |
| LLM 全部依存 | コスト爆発、BYOK で利用者負担 |

## 次のステップ（Sprint 1）

Sprint 0（DB スキーマ・TypeScript エンティティ/型・FastAPI 雛形・Docker・CI）は 2026-05-15 に完了。次は L1 + L2 の基礎を入れる:

1. managed Postgres + OIDC プロバイダ + Secret Manager のプロビジョニング（JWKS エンドポイント確認）
2. `portfolio_owner` / `portfolio_app` 2 ロール分離の migration を追加（`0002_rls_roles.sql`）
3. 全テーブルへの RLS ポリシー適用 migration（`0003_rls_policies.sql`、`current_setting(..., true)` + FORCE RLS）
4. Node API（NestJS/Express）の JWKS 検証 + テナント解決ミドルウェア
5. Node データ層がリクエスト単位トランザクション先頭で `SET LOCAL app.tenant_id` / `app.user_id` を発行
6. Category / KnowledgeEntry / FieldDefinition の最小 CRUD（React + Node API）
7. Excel 取込（既存 Streamlit 版 `data.xlsx` 流用）でデモテナントを作成
8. CI/CD パイプラインを新スタックで整備（既存 `ci.yml` / `codeql.yml` / pre-commit を Node/TS へ、RLS E2E を必須ゲートに）

Sprint 2 以降の予定は [09_task_split.md](09_task_split.md)。

---

設計判断の責任者：座布団さん。本記録はAIとの対話を経た合意事項を整理したもの。
