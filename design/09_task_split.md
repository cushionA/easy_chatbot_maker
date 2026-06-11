# 09. タスク分担：自分で書く vs AI に任せる

## 切り分けの基準

> **「面接で『これどうやって作った？』と聞かれて、その場で説明できる必要があるか」**

- YES → 座布団さん自身が書く
- NO → AI に任せる（仕様だけ握って、コード生成は委譲）

TrendScope の核は **収集パイプライン・用語正規化・F2 検知ロジック・3 層データ基盤**。この核の「なぜこの設計か」を語れる箇所は自分で握り、定型実装（CRUD・型生成・UI・CI YAML）は委譲する。

## 層ラベル（凡例）

委譲タグ（[自分]/[AI]）とは別軸で、各タスクが触れる **フルスタックの層** を明記する。研修・実務で偏りがちな層（特に `[INFRA]` `[TEST]`）を意識的に取りに行くための可視化。各 Sprint プラン（`sprintN_plan.md`）と day ファイル（`sprintN/dayX.md`）のタスク見出しで使用する。

| ラベル | 範囲 |
|---|---|
| `[FE]` | フロントエンド: UI ページ/コンポーネント/トレンド可視化・チャート/ドリルダウン/ルーティング・レイアウト/フォーム描画 |
| `[BE]` | バックエンド: API/認証・認可/収集・検知ロジック/Source Adapter/サービス層/データアクセス/サーバ側バリデーション |
| `[INFRA]` | インフラ: Docker/K8s/CI・CD/クラウド・ホスティング/DB ロール・拡張・マイグレーション・RLS ポリシー/シークレット/監視 |
| `[TEST]` | テスト: 単体/結合/E2E/RLS 越境/テストデータ seed |
| `[ML]` | 機械学習: 用語抽出(NER)・正規化/検知ロジック/Embedding サービス・ベクトル推論 |
| `[設計]` | 上流設計: 要件定義/スキーマ設計/仕様明文化（コード実装を伴わない設計タスク） |

委譲タグの後ろに併記する（例: `[自分] [BE]`）。複数層にまたがるタスクは主たる層を先頭に（最大 2、稀に 3。収集ワーカー基盤 = `[BE] [INFRA]`、抽出＋埋め込み = `[BE] [ML]`、検知バッチ = `[BE] [ML]`）。

## 座布団さん自身が書く（説明責任が重い領域）

### 設計判断系

- [x] **技術スタック確定**（TypeScript/Node + Python + React、収集ワーカー BullMQ/Redis）← 完了
- [x] **軽量マルチテナント方針**（共有グローバル + テナントオーバーレイ RLS）← 完了
- [x] **3 層データ配置**（Postgres メタ / ES 文書 / BigQuery ファクト）← 完了
- [x] **F2 検知方式の選定**（新出=クロスソース裏取り / 急上昇=シェア正規化+z-score / 廃れ）← 完了
- [x] **DB スキーマ全体**← 設計完了、SQL 生成は AI に委譲
- [x] **データ最小化戦略**（派生データのみ保存・本文全文は持たない）← 完了
- [x] **収集コンプラ方針**（API 主軸・クロール脇役・robots/ToS 遵守）← 完了

### 実装系（自分の手で書く）

- [ ] **`SourceAdapter` インターフェース定義**（`discover` / `collect`、`DiscoveredRef` / `CollectedItem`）（実装は AI）
- [ ] **`FetchContext` の設計**（robots 遵守・レート制御・条件付き GET・指数バックオフの責務集約。最初の 1 実装も自分）
- [ ] **用語正規化ロジック**（別名→正規 term・曖昧性解消・除外語・新規 term 登録条件）← F9 の核
- [ ] **F2 検知の判定式**（emerging の `N_min`/`M_min`、rising の EWMA+z-score、declining の減衰判定）の TypeScript 実装
- [ ] **検知パラメータの較正**（`ε / N_min / M_min / Z_TH / halflife / K` を固定データセットで調整）
- [ ] **`daily_term_stats` の集計クエリ設計**（share 総量正規化・distinct_sources 裏取り）
- [ ] **認証・テナント解決フロー**（OIDC `sub` → `user_tenants` 照合 → `SET LOCAL app.tenant_id`、JWT クレーム設計）
- [ ] **RLS ポリシーテスト項目の定義**（テナントオーバーレイで漏洩したらアウトな箇所）
- [ ] **F3 要約プロンプト設計**（Gemini 用、スニペット+メタのみ・本文全文は入れない・構造化出力）

### 採用面接向け資料

- [ ] **訴求ポイント整理**（[12_interview_narratives.md](12_interview_narratives.md) 参照）
- [ ] **デモシナリオ作成**（サインイン → トレンド閲覧 → 用語ドリルダウン → 急上昇/新出の表示）

## AI に任せていい（仕様だけ握れば実装は委譲できる）

### コード生成

- [ ] **`migrations/0001_init.sql`**（[03_db_schema.md](03_db_schema.md) から SQL ファイル化）
- [ ] **TypeScript の型/エンティティ定義**（schema から自動生成、ソース定義・抽出結果・検知結果のスキーマ共有）
- [ ] **RLS ポリシーの SQL**（方針が固まったあと、テナント単位テーブル分の実 SQL）
- [ ] **各 `SourceAdapter` 実装**（GitHub API / Hacker News / Qiita / dev.to / npm DL / GitHub Trending crawl / 記事本文 crawl / CHANGELOG crawl）（インターフェース仕様から複製）
- [ ] **本文抽出（ボイラープレート除去）+ 用語候補抽出（辞書 + NER パターン）**（仕様から）
- [ ] **dedup 実装**（`content_hash` 完全一致 + embedding kNN 近重複）
- [ ] **`occurrences` → BigQuery 取込ローダ**（`doc_id`+`term_slug` 冪等追記）
- [ ] **`daily_term_stats` スケジュールクエリ**（自分が設計した集計式を SQL 化）
- [ ] **F2 検知バッチの足回り**（BigQuery 読み出し・`detections` upsert。判定式は自分実装を組み込む）
- [ ] **FastAPI Embedding 推論サーバ**（`multilingual-e5-base`、`query:`/`passage:` プレフィクス）

### UI

- [ ] **React コンポーネント実装**（F1 トレンドチャート・用語ドリルダウン・関連トピック表示）
- [ ] **F8 収集ヘルス ダッシュボード**（ソース別 鮮度/失敗率/`parser_broken` 一覧）
- [ ] **F9 用語辞書管理 UI**（別名マージ・除外語・曖昧性解消メモ・検知レビュー confirm/dismiss）
- [ ] **ウォッチリスト管理 UI**（テナント単位、追加/削除）
- [ ] **CSS / レイアウト**（Tailwind 等で標準化。UI の作り込みは優先しない）

### インフラ・運用

- [ ] **GitHub Actions CI/CD YAML**（lint → unit → integration → e2e、Node/TS 構成）
- [ ] **Dockerfile / docker-compose.yml**（API / 収集ワーカー / Redis / OpenSearch / Embedding のローカル一式）
- [ ] **Kubernetes マニフェスト**（収集ワーカーの Deployment、水平スケール・レート制御）
- [ ] **収集ジョブのスケジューラ**（日次 Discovery トリガ・週次 CHANGELOG ウォッチ cron）
- [ ] **監視・アラート連携**（`consecutive_failures` 閾値・`parser_broken` 通知、Phase 2）

### テスト

- [ ] **ユニットテスト**（座布団さんがケースを指定、AI が書く）
- [ ] **E2E テスト**（特に RLS テナント越境テスト、座布団さんがケースを指定）
- [ ] **F2 検知の回帰テスト**（固定データセット、期待結果は自分が定義）

### ドキュメント

- [ ] **README**（プロジェクト概要、セットアップ手順）
- [ ] **API ドキュメント**（OpenAPI / Swagger）
- [ ] **デモ用 seed データ**（用語辞書・ソース定義・サンプル occurrences）

## グレーゾーン：座布団さんが「最初の1個」を書き、AI が「残り」を書く

設計判断と実装の境目にあるもの。最初の1個を自分で書いて型を作れば、AI が同パターンで複製できる。

| 対象 | 最初の1個 | 残り |
|---|---|---|
| **`SourceAdapter` 実装** | GitHub API Source（API 系の手本）+ GitHub Trending crawl（crawl 系の手本） | 他ソースは AI |
| **`FetchContext`** | robots/レート/条件付き GET の骨格 1 実装 | リトライ・バックオフの詰めは AI |
| **React コンポーネント** | F1 トレンドチャート 1 画面 | 他ページは AI |
| **RLS ポリシー** | `watchlists` 1 テーブル分 | 他テナント単位テーブルは AI |
| **DB マイグレーション（SQL）** | 最初の1つを設定 | 後続は AI が増分生成 |

## 学習目的・成長機会

このプロジェクトでの **「美味しい経験」** は以下：

| 領域 | 学べること |
|---|---|
| 収集パイプライン | Adapter パターン、礼儀正しいクローラ（robots/レート/条件付き GET）、キュー + ワーカー |
| 軽量マルチテナント | RLS, Secret Manager, OIDC/JWT, 共有コーパス + テナントオーバーレイ |
| ML 検知 | 新出/急上昇/廃れの統計的検知、シェア正規化、z-score、ベイズ平滑化、パラメータ較正 |
| 用語正規化（NER） | 別名名寄せ、曖昧性解消、近重複除去（embedding kNN） |
| 3 層データ基盤 | Postgres（メタ）/ Elasticsearch（検索・エビデンス）/ BigQuery（時系列 DWH） |
| BigQuery | パーティション/クラスタリング、スケジュールクエリ、スキャン量とコスト |
| TypeScript フルスタック | React + Node + 収集ワーカーでの型共有 |
| 無料運用 | コスト感覚、スケール時の有料化判断 |
| 合法設計 | データ最小化（派生データのみ）、robots/ToS 遵守をアーキに内蔵 |

これらすべて職務経歴書で語れる **「実プロダクト経験」** になる。

## 実装バックログ（Sprint × 層ラベル）

Sprint 1〜6 の全タスクを層ラベル付きで一覧化したもの。**Sprint 2 以降の委譲タグ・分割は仮**（各 Sprint 着手時に `sprint-plan` でスパイク所見を反映して確定する）。Sprint 1 の正は [sprint1/day1〜3.md](sprint1/day1.md)。

### Sprint 1 — スパイク（確定・指示書あり）

| タスク | 委譲 | 層 |
|---|---|---|
| spike 環境の起動確認 | [自分] | [INFRA] |
| HN Algolia 時間窓スライド 30 日取得 | [自分-B] | [BE] |
| Qiita 30 日取得 | [AI] | [BE] |
| 正規化スキーマ + normalizer（UTC） | [自分-B] | [設計] [BE] |
| データ品質レポート | [AI] | [TEST] |
| seed 辞書の候補生成 | [AI] | [ML] |
| 辞書キュレーション（aliases/excluded/ambiguous） | [自分] | [ML] [設計] |
| 2 層抽出器（タグ直接 + タイトル辞書マッチ） | [自分-B] | [ML] |
| 集計（term×day×locale, share） | [自分-A] | [BE] |
| パイプライン結線 + 品質ダンプ | [AI] | [BE] [TEST] |
| 検知（emerging / rising） | [自分-B] | [ML] |
| 検知レポート出力 | [AI] | [BE] |
| 目視評価・パラメータ感度 | [自分] | [ML] [TEST] |
| （任意）GitHub Trending 3 本目 | [AI] | [BE] |
| findings → 設計反映 → Sprint 2 ゴール | [自分] | [設計] |

### Sprint 2 — 土台: monorepo + DB/RLS + CI（仮）

| タスク | 委譲（仮） | 層 |
|---|---|---|
| monorepo scaffold（apps/api・apps/web・workers・packages/shared） | [AI] | [INFRA] |
| docker compose（postgres / OpenSearch / redis / embedding） | [AI] | [INFRA] |
| migration 0001 schema（terms / sources / detections / tenants 系） | [自分-A]→残り[AI] | [INFRA] |
| migration 0002 2 ロール（owner/app・NOBYPASSRLS・**テーブル別 GRANT**） | [自分] | [INFRA] |
| migration 0003 RLS（オーバーレイ + FORCE + sources 混在 + NULL 注入ガード） | [自分] | [INFRA] |
| RLS 越境テスト（Testcontainers: マトリクス + フェイルセーフ + 複合 FK） | [自分ケース定義→AI実装] | [TEST] |
| CI の Node 化（lint/unit/integration/e2e、codeql js-ts/python、pre-commit） | [AI一次→自分レビュー] | [INFRA] [TEST] |
| ESLint 境界ルール（生 ES クライアント import 禁止） | [AI] | [INFRA] |

### Sprint 3 — 収集パイプライン本実装（仮）

| タスク | 委譲（仮） | 層 |
|---|---|---|
| `FetchContext`: SSRF 検証（scheme / private IP / メタデータ / リダイレクト再検証） | [自分-B] | [BE] |
| `FetchContext`: robots / レート / 条件付き GET / バックオフ | [自分] | [BE] |
| `SourceAdapter` IF + registry（discover/collect） | [自分] | [設計] [BE] |
| HN adapter（窓スライド本実装 = 手本） | [自分-A] | [BE] |
| Qiita / dev.to / SO / Lobsters adapters（複製 ×4） | [AI] | [BE] |
| BullMQ キュー + ワーカー（並列・リトライ・ジョブ分離） | [自分-B] | [BE] [INFRA] |
| dedup（content_hash） | [AI] | [BE] |
| F8 収集ヘルス（sources 更新・parser_broken 検知） | [AI一次→自分レビュー] | [BE] |
| occurrences → BigQuery ローダ（MERGE 冪等） | [自分-A] | [BE] [INFRA] |
| Adapter 共通テストハーネス（robots/レート/304/parser_broken/SSRF/ReDoS フィクスチャ） | [自分ケース定義→AI実装] | [TEST] |

### Sprint 4 — 抽出・検知・metrics（仮）

| タスク | 委譲（仮） | 層 |
|---|---|---|
| F9 正規化本実装（2 層抽出・曖昧性解消・excluded・RE2/上限） | [自分] | [ML] |
| seed 辞書投入 + 新規 term upsert | [AI] | [ML] [BE] |
| Embedding FastAPI（e5・query/passage 規約） | [AI] | [ML] |
| ES documents 投入（snippet 生成・popularity・embedding・kNN 近重複） | [AI一次→自分レビュー] | [BE] [ML] |
| daily_term_stats スケジュールクエリ（share 正規化・distinct_sources） | [自分-A] | [BE] [INFRA] |
| F2 検知バッチ本実装（EWMA 系統一・emerging/rising/declining） | [自分-B] | [ML] [BE] |
| 検知 golden 回帰 D1〜D9（spike の stats 断面から切り出し） | [自分定義→AI実装] | [TEST] [ML] |
| term_identities 生成（ヒューリスティック + 手動登録） | [AI] | [ML] |
| MetricsSourceAdapter（npm 手本 → pypistats/crates/GH Archive 複製） | [自分-A]→残り[AI] | [BE] |
| rising × metrics 突合（採用裏付けを evidence へ） | [自分] | [ML] |

### Sprint 5 — API + フロント（仮）

| タスク | 委譲（仮） | 層 |
|---|---|---|
| OIDC JWT 検証（jose / JWKS） | [自分-B] | [BE] |
| テナント解決 + `SET LOCAL` データ層 | [自分] | [BE] |
| F1 トレンド API + チャート画面（手本 1 枚） | [自分]→複製[AI] | [FE] [BE] |
| F2 検知一覧（新出 / 急上昇 / 廃れタブ） | [AI] | [FE] |
| F6 ドリルダウン（時系列 + 出典 + スニペット + 関連語、XSS エスケープ） | [自分-A] | [FE] [BE] |
| F9 辞書管理 UI（マージ / 除外 / 検知レビュー） | [AI] | [FE] [BE] |
| ウォッチリスト CRUD（RLS・admin ガード・監査ログ） | [AI一次→自分レビュー] | [BE] [FE] |
| API レート制限（per-tenant / per-user + F3 日次上限の土台） | [自分] | [BE] |
| Playwright E2E（E1〜E5・E10 + RLS 越境） | [自分ケース定義→AI実装] | [TEST] |

### Sprint 6 — 要約 + 運用 + デプロイ（仮）

| タスク | 委譲（仮） | 層 |
|---|---|---|
| F3 要約（プロンプト設計・データ/指示分離 = injection 対策） | [自分] | [ML] [BE] |
| F3 キャッシュ・システムキー上限・BYOK 切り分け | [AI] | [BE] |
| injection 回帰テスト（仕込みスニペット） | [自分ケース定義→AI実装] | [TEST] |
| F8 ダッシュボード画面 | [AI] | [FE] |
| GitHub Trending クロール本実装（セレクタ再検証 + parser_broken） | [自分-A] | [BE] |
| K8s マニフェスト + デプロイ（ワーカー水平スケール） | [AI一次→自分レビュー] | [INFRA] |
| Secret Manager 連携（BYOK・prefix 検証・IAM 最小権限） | [自分] | [INFRA] [BE] |
| 監視・アラート（収集ヘルス通知） | [AI] | [INFRA] |
| デモ準備（過去分ブートストラップ + シナリオ、11 Q16） | [自分] | [設計] [ML] |

### 層バランス（ざっくり集計）

| 層 | タスク数（主ラベル） | 備考 |
|---|---|---|
| [BE] | ~20 | 収集・API・データ層が中心の製品なので最多 |
| [ML] | ~12 | 抽出・検知・正規化・要約 |
| [INFRA] | ~11 | migration / CI / compose / K8s / Secret Manager |
| [TEST] | ~9 | RLS 越境・検知回帰・Adapter ハーネス・E2E・injection |
| [FE] | ~6 | 「UI は作り込まない」方針通り少なめ |
| [設計] | ~5 | スキーマ・IF・findings・デモ |

CI/CD は凡例どおり [INFRA]（必須ゲートは + [TEST]）に含める。

## ワークフロー：1機能の実装手順

各機能について、以下の流れで進める：

```
1. 設計記録（design/）を確認・必要なら更新（座布団さん）
   ↓
2. 仕様を箇条書きで明文化（座布団さん）
   ↓
3. インターフェース・型定義を書く（座布団さん）
   ↓
4. AI に「この仕様で実装して」と依頼
   ↓
5. AI 生成コードをレビュー、テストを依頼
   ↓
6. 動作確認、修正があれば AI に再依頼
   ↓
7. PR にして自分でマージ（GitHub）
```

ステップ3（インターフェース定義）が **座布団さんが握る最重要部分**。これさえ握れば、面接で「俺の設計で、実装は AI に書かせた」と語れる。特に `SourceAdapter` / `FetchContext` の境界と、F2 検知の判定式は自分の言葉で説明できる状態にしておく。
