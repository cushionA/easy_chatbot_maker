# 10. 旧チャットボット設計からの流用マッピング

先行して設計していた **RAG チャットボット（社内ナレッジ起票補助）platform** から、TrendScope へ「何を引き継ぎ、何を差し替え、何を捨てたか」を整理する。本書は新規ドメイン設計ではなく、**設計資産の継承関係**を示すものである。

## 転用の経緯

当初は社内ナレッジ起票補助の RAG チャットボットを、転職ポートフォリオの評価対象として設計していた。入社が確定しポートフォリオ評価の縛りが外れたため、目的を「転職アピール用の体裁」から「**入社後の実務に直結するスキルの実証・予習**」へ振り直した（[01_overview.md](01_overview.md)）。その結果、入社先の技術スタック（TypeScript / Node.js / Docker / Kubernetes / BigQuery、マルチクラウド）に全振りし、加えて **ML 推論** と **クローリング** を主役級の題材に据えて再ピボットした。

この再ピボットで重要なのは、**横断インフラ（土台）はほぼそのまま使え、差し替えたのはドメインだけ**だった点である。RLS によるマルチテナント分離、OIDC、Secret Manager、Elasticsearch、BigQuery、Docker / K8s、CI、テスト戦略、BYOK、Source / Destination の Adapter パターン — これらは「チャットボット」固有ではなく「マルチテナント型データプロダクト」共通の土台である。チャットボットの頭（問い合わせ分類・起票）を外し、クロール収集 + トレンド検知の頭に付け替えた。

> PoC だった Streamlit 版 helpdesk_bot は、もはや本サービスの基盤ではない。そこからのコード流用ストーリー（Excel マスタ・動的フォーム・起票本文生成）は廃止し、本書では**横断インフラの継承**のみを扱う。

## 流用マッピング（土台 / ドメイン / 捨てたもの）

| 区分 | 旧設計（RAG チャットボット） | TrendScope での扱い |
|---|---|---|
| **流用したもの（土台 = そのまま）** | マルチテナント RLS（`SET LOCAL app.tenant_id` + `FORCE ROW LEVEL SECURITY` + フェイルセーフ） | **そのまま流用**。テナント単位テーブルが `inquiries` → `watchlists` / `tenant_settings` に変わっただけ（[04_security_multitenant.md](04_security_multitenant.md)） |
| | OIDC（JWT / JWKS 検証 → `user_tenants` 照合をアプリ層で完結） | **そのまま流用**。認証フローは不変 |
| | Secret Manager（BYOK の LLM キーは参照のみ DB 保持・実体は外部） | **そのまま流用**。`tenant_settings.llm_secret_ref` |
| | Elasticsearch（BM25 + kNN・kuromoji・TS クライアント） | **そのまま流用**。用途が「分類候補検索」→「エビデンス文書検索 + 関連トピック」に変化 |
| | BigQuery（DWH） | **役割を拡張して流用**。旧設計では補助的、新設計ではトレンド・検知の主役（出現ファクト + 日次集計） |
| | Docker / Kubernetes（コンテナ運用・水平スケール・マルチクラウド可搬） | **そのまま流用**。スケール対象に収集ワーカーが加わった |
| | CI（GitHub Actions）/ テスト戦略（Playwright E2E + Vitest、RLS 越境の E2E 検証） | **そのまま流用**。回帰対象に「検知ロジック」が加わった（[02_architecture.md](02_architecture.md)） |
| | BYOK（Gemini を必須依存にせずプラガブル化） | **そのまま流用**。用途が「分類フォールバック」→「技術サマリ生成（F3）」に変化 |
| | Adapter パターン + DI（差し替え可能な外部接続の抽象化） | **構造を流用、向きを反転**。`ITicketDestination`（出力）→ `SourceAdapter`（入力）。詳細は次節 |
| | 2 ロール分離（`portfolio_owner` / `portfolio_app` NOBYPASSRLS） | **そのまま流用** |
| **差し替えたもの（ドメイン）** | 問い合わせ分類フロー（Embedding + BM25 + match_count + LLM の多段分類） | **削除**。代わりに「用語抽出 → 正規化 → 出現集計 → ライフサイクル検知（新出 / 急上昇 / 廃れ）」（[05_search_classification.md](05_search_classification.md)） |
| | ナレッジマスタ（`knowledge_entries`）＝検索対象 | **差し替え**。`terms` / `term_aliases`（用語辞書 F9）+ ES `documents`（収集文書） |
| | 起票（`destinations` / Redmine / GitHub Issues への書き出し）＝出力先 | **差し替え**。`sources`（収集元）＝入力。プロダクトの向きが「出力」から「収集」へ反転 |
| | LLM の役割：問い合わせの分類 | **差し替え**。LLM の役割：用語の技術サマリ生成（RAG）+ 曖昧性解消の補助 |
| | データの量的中心：問い合わせ・起票レコード | **差し替え**。データの量的中心：出現ファクト（BigQuery `occurrences`） |
| **捨てたもの** | 3 段階エスカレーション（自動回答 / ガイダンス / 直接起票） | **廃止**。チャットボット固有の概念で TrendScope に対応物なし |
| | 動的フォーム（テーブル駆動の `<DynamicField>` + 型別バリデーション） | **廃止**。起票画面が無いため不要 |
| | 埋め込みウィジェット（`<script>` 1 行で自社サイトに常駐するチャット UI） | **廃止**。対人チャット UI 自体が無い |
| | 未分類キュー（`unclassified_queue`） | **廃止**。誤検知レビューは `detections.status`（confirmed / dismissed）で代替（[05_search_classification.md](05_search_classification.md)） |
| | Streamlit PoC（helpdesk_bot）からのコード・デモデータ流用 | **廃止**。Excel マスタ・session_state・Ollama 呼び出し等は一切引き継がない |

## Adapter パターンの「向きの反転」

旧設計の中核資産だった Adapter パターンは、**抽象化の構造はそのまま、データの向きだけ反転**して流用した。これが「土台は同じ、ドメインだけ違う」を最も端的に示す。

```
[旧: 出力 Adapter]                      [新: 入力 Adapter]
ITicketDestination                       SourceAdapter
  ├ RedmineDestination                     ├ github-api-source
  └ GitHubIssuesDestination                ├ hackernews-api-source
                                           ├ qiita-api-source
  分類結果 → 外部チケットへ「書き出す」      └ github-trending-crawl-source
  フィールドマッピングは JSONB             外部 Web から「収集する」
                                           HTTP の作法は FetchContext に集約
```

- 共通点: インターフェースで外部接続を抽象化し、DI / レジストリで `kind` から実装を解決、設定は JSONB（`config`）で柔軟に持つ。新接続先は「実装 1 つ + 設定行」で増やせる。
- 相違点: 旧は**1 件を外部へ送る**（冪等・即時）。新は**多数を外部から取る**（長時間・部分失敗前提・礼儀正しさが要る）。このため新設計では `FetchContext`（robots 遵守・レート制御・条件付き GET・指数バックオフ・必要時 Playwright）という共通チョークポイントを Adapter から切り出した（[06_destinations.md](06_destinations.md)）。

## データ最小化方針の継承と強化

旧設計の「データ最小化（起票本文は外部チケット側が真の保管先、当方はメタのみ保持）」という方針は、TrendScope で**合法性の一級市民**へ昇格した。

| 旧設計 | TrendScope |
|---|---|
| 起票本文は Redmine / GitHub 側が source of truth、当方は ID + URL + メタのみ | 収集文書の本文全文は相手サイトが source of truth、当方は**派生データのみ**（用語頻度・メタ・短いスニペット・embedding・要約）。本文は抽出後破棄 |
| 動機: DB 軽量化 + GDPR 削除要求の転送 | 動機: 上記に加え **著作権法 30 条の 4（情報解析利用）+ robots / ToS 遵守**という収集の合法ライン（[07_data_strategy.md](07_data_strategy.md)） |

## まとめ

TrendScope は「ゼロから作った別物」ではなく、「**RAG チャットボット platform の横断インフラを土台に、ドメインだけクロール + トレンド検知へ差し替えたもの**」である。土台（RLS / OIDC / Secret Manager / ES / BigQuery / Docker・K8s / CI / テスト / BYOK / Adapter）の再利用が、再ピボットを短期で成立させた。面接では「**マルチテナント型データプロダクトの土台は同じで、頭だけ載せ替えられる設計にしてあった**」点が、設計の汎用性・再利用性の証明になる（[12_interview_narratives.md](12_interview_narratives.md)）。
