# 設計記録（Service A：RAGチャットボット生成サービス）

## ステータス

- **フェーズ**：設計フェーズ **完了** / 実装フェーズ **未着手**
- **対象**：Service A（RAGチャットボット生成サービス）のみ
- **Service B（Ronkaku）**：並行度低、Service A 構築中の流用候補としてのみ意識
- **最終更新**：2026-05-15

## ドキュメント構成

| ファイル | 内容 |
|---|---|
| [01_overview.md](01_overview.md) | サービス概要、差別化、訴求先 |
| [02_architecture.md](02_architecture.md) | 技術スタック、システム構成、ホスティング |
| [03_db_schema.md](03_db_schema.md) | DBスキーマ全体（SQL）、インデックス、RLS |
| [04_security_multitenant.md](04_security_multitenant.md) | 認証、RLS、Vault、テナント分離 |
| [05_search_classification.md](05_search_classification.md) | 分類フロー、ハイブリッド検索、ランキング |
| [06_destinations.md](06_destinations.md) | 起票先抽象化、Adapter、フィールドマッピング |
| [07_data_strategy.md](07_data_strategy.md) | データ配置3層、最小化戦略 |
| [08_features.md](08_features.md) | MVP / Phase 2 / Phase 3 機能リスト |
| [09_task_split.md](09_task_split.md) | 座布団さん自身が書く部分 vs AI に任せる部分 |
| [10_existing_streamlit.md](10_existing_streamlit.md) | 既存 Streamlit 版からの流用・発展 |
| [11_open_questions.md](11_open_questions.md) | 未確定の運用判断・要検証項目 |
| [12_interview_narratives.md](12_interview_narratives.md) | 面接訴求ポイント集 |

## クイックリファレンス（主要決定事項）

| 項目 | 決定 |
|---|---|
| 技術スタック | C# (Blazor Server + ASP.NET Core) + Python (FastAPI Embedding) + 最小JS |
| ホスティング | Oracle Cloud Always Free（プランA）/ Azure F1 + Supabase + HF Spaces（プランB） |
| DB | Postgres + pgvector + Vault |
| テナント分離 | Row Level Security (RLS) |
| 認証 | Supabase Auth |
| LLM | Gemini API（BYOK専用） |
| Embedding | intfloat/multilingual-e5-base、サーバ計算 |
| 検索戦略 | BM25 + Embedding ハイブリッド (RRF) + match_count 重み |
| 分類フロー | カテゴリ → コンボボックス → 自然言語 → キーワード完全一致 → ハイブリッド → LLM(BYOK) → 未分類キュー |
| 起票先 | ITicketDestination 抽象、Redmine + GitHub Issues、プライマリ＋切替 |
| データ戦略 | 本文は外部システム、サーバはメタ+Embedding、推論はクライアント |
| URL形式 | `/t/{slug}/chat` |
| ロール | admin / member の2階層 |
| 月額 | $0 |

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

## 次のステップ（実装フェーズの最初の一歩）

1. Oracle Cloud Always Free アカウント取得試行
2. `migrations/0001_init.sql` 生成（[03_db_schema.md](03_db_schema.md) から AI に書かせる）
3. EF Core エンティティ生成（同上）
4. プロジェクト雛形作成（ASP.NET Core + Blazor Server）
5. FastAPI Embedding サービス雛形

---

設計判断の責任者：座布団さん。本記録はAIとの対話を経た合意事項を整理したもの。
