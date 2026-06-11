# 設計記録（TrendScope：技術トレンド・レーダー）

## ステータス

- **フェーズ**：設計フェーズ — **新ドメインへ全面ピボット完了**（`design/01–13` + 本 README）。実装フェーズ未着手。
- **プロダクト**：TrendScope。開発系 Web の言及を **API 主軸 + クロール脇役**で収集し、技術用語の「**新出・急上昇・廃れ**」を時系列で検知・可視化するマルチテナント型データ収集 + 分析プロダクト。
- **再ピボットの経緯**：入社確定でポートフォリオ評価の縛りが外れたため、目的を「体裁」から「**会社スタック全振り + ML 活用 + クロール実務の予習**」へ振り直し、先行設計の RAG チャットボットから**横断インフラを流用しドメインだけ差し替えた**（流用マッピングは [10_existing_streamlit.md](10_existing_streamlit.md)）。会社名は資料に出さない。
- **Sprint 1（スパイク）の作業指示書を生成済み**: [sprint1_plan.md](sprint1_plan.md)（全体ロードマップ Sprint 1〜6 含む）+ [sprint1/day1〜3.md](sprint1/day1.md)。**sprint2〜6 のファイルは旧チャットボットのまま stale** — 各 Sprint 着手時に `sprint-plan` で置換する。
- **最終更新**：2026-06-11

## ドキュメント構成

| ファイル | 内容 |
|---|---|
| [01_overview.md](01_overview.md) | サービス概要、合法方針、機能、差別化、訴求先 |
| [02_architecture.md](02_architecture.md) | 技術スタック、収集パイプライン構成、ホスティング、コスト |
| [03_db_schema.md](03_db_schema.md) | 3 層データモデル（Postgres / Elasticsearch / BigQuery）、RLS |
| [04_security_multitenant.md](04_security_multitenant.md) | OIDC、軽量マルチテナント RLS、Secret Manager、収集コンプラ |
| [05_search_classification.md](05_search_classification.md) | 抽出・正規化、**検知（F2）**、エビデンス検索（F6）、要約（F3） |
| [06_destinations.md](06_destinations.md) | **収集ソース（Source Adapter）**、礼儀正しいクローラ、収集ヘルス |
| [07_data_strategy.md](07_data_strategy.md) | 3 層データ配置、**派生データのみ保存**、合法、BigQuery コスト |
| [08_features.md](08_features.md) | MVP / fast-follow / Phase 2 / 却下した機能 |
| [09_task_split.md](09_task_split.md) | 自分が書く部分 vs AI 委譲（[自分]/[AI] + 層ラベル） |
| [10_existing_streamlit.md](10_existing_streamlit.md) | 旧チャットボット設計からの流用マッピング |
| [11_open_questions.md](11_open_questions.md) | 未確定の運用判断・要検証項目 |
| [12_interview_narratives.md](12_interview_narratives.md) | 面接訴求ポイント集 |
| [13_testing_strategy.md](13_testing_strategy.md) | テスト戦略（ピラミッド / E2E / RLS 越境 / 検知回帰 / CI） |
| [14_data_sources.md](14_data_sources.md) | データソース取得仕様書（実エンドポイント確認: 認証 / レート / スキーマ / セレクタ） |
| [sprint1_plan.md](sprint1_plan.md) | Sprint 1（スパイク）全体マップ + Sprint 1〜6 ロードマップ（2026-06-12〜14） |

## クイックリファレンス（主要決定事項）

| 項目 | 決定 |
|---|---|
| 技術スタック | **TypeScript / Node.js 中心**（React + Node API + 収集ワーカー[BullMQ/Redis]）、ML（Embedding）のみ Python FastAPI |
| ホスティング | **マルチクラウド**（GCP 主軸 / AWS / Azure 可搬）、Docker / Kubernetes。各コスト要素に無料枠 / ローカル開発パス併記 |
| データ基盤 | **3 層**: PostgreSQL（メタ・RLS）/ Elasticsearch（文書・検索）/ BigQuery（出現ファクト・日次集計） |
| マルチテナント | **軽量**: 本体コーパスは共有グローバル、テナント単位（設定・ウォッチリスト・プライベートソース）のみ RLS |
| テナント分離 | RLS + `current_setting('app.tenant_id', true)` + フェイルセーフ |
| 認証 | OIDC（JWT / JWKS 検証）、テナント解決はアプリ層 |
| シークレット | Secret Manager（GCP / AWS、BYOK Gemini キー） |
| DB ロール分離 | `portfolio_owner`（マイグレーション・グローバル書込）/ `portfolio_app`（API・`NOBYPASSRLS`）+ FORCE RLS |
| 収集 | **API 主軸 + クロール脇役**、SourceAdapter（api/feed/crawl）、robots 遵守・レート制御・条件付き GET |
| 検知（F2） | 新出（クロスソース裏取り）/ 急上昇（シェア正規化 + z-score）/ 廃れ |
| 検索 | Elasticsearch BM25 + kNN（エビデンス F6・関連トピック） |
| Embedding | multilingual-e5-base、Python FastAPI 推論サービス（ONNX/Node 化で TS 統一可） |
| LLM | Gemini API（BYOK、F3 技術サマリ生成） |
| 合法方針 | **派生データのみ保存・本文全文は持たない**・出典はリンク・robots/ToS 遵守 |
| テスト | Playwright（E2E + RLS 越境）+ Vitest / Testcontainers + **F2 検知回帰** + GitHub Actions |
| URL 形式 | `/t/{slug}/...` |
| ロール | admin / member の 2 階層 |
| 月額 | 無料枠中心（収集頻度・BigQuery スキャン量・推論負荷で段階課金） |

## 明示的に却下した設計

| 却下した案 | 理由 |
|---|---|
| 固定タクソノミ（F10 カテゴリ分類） | overkill・陳腐化 → 関連トピック軽量版（embedding 近傍 / 共起）で代替 |
| 規約でスクレイピング禁止の対象を収集 | 「需要 × 公式アクセスが無い × 合法」で判断。小説投稿サイト・pixiv・大手 SNS は見送り |
| 小説サイト / Kaggle のクロール | 規約調査の結果、なろうは API 以外の自動収集禁止、Kaggle は公式 API + Meta Kaggle で取得可（クロール不要） |
| 本文全文の保存・再配布 | 著作権・容量・削除要求の三重苦 → 派生データのみ保存 |
| 技術キャッチアップ目的のクロール | 開発界隈は API リッチで価値薄 → API 主軸に倒す |
| index-per-tenant / schema-per-tenant | 本体コーパスは共有、テナント分離は RLS で十分 |

## 次のステップ

0. **Sprint 1 = スパイク（現在地）**: 取得仕様は [14_data_sources.md](14_data_sources.md) で実機確認済み、データ構造見直し（mentions/metrics 分離・`term_identities`）も 03/05/06 に反映済み。**次は [sprint1/day1.md](sprint1/day1.md) を開いて Day1-1 から**（`spike/` に骨格ファイル作成済み）。スパイクの所見 → design 反映 → Sprint 2 を `sprint-plan` で詳細化、の順。
1. **Sprint plan の再生成**: `sprint-plan` スキルで TrendScope 用の Sprint ゴール → `sprintN_plan.md` / `dayX.md` を生成（旧チャットボットの sprint ファイルを置換）。
2. **実装フェーズ**（[09_task_split.md](09_task_split.md) 参照）:
   - `apps/web`（React/TS）/ `apps/api`（Node/TS）/ `workers`（収集ワーカー）/ `services/embedding`（Python FastAPI）/ `infra`（migrations・K8s）
   - RLS 2 ロール migration、OIDC + `SET LOCAL` テナント解決、SourceAdapter + FetchContext、用語抽出・正規化、occurrences → BigQuery、daily_term_stats、F2 検知バッチ、ES documents、F1/F6/F8/F9 UI
   - CI を Node/TS へ（`ci.yml` / `codeql.yml` / pre-commit を dotnet → Node、RLS 越境 + F2 検知回帰を必須ゲートに）

---

設計判断の責任者：座布団さん。本記録は AI との対話を経た合意事項を整理したもの。
