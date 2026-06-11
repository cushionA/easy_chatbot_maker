# 02. アーキテクチャ

## 技術スタック

TrendScope は「**開発系 Web の言及を 収集 → 抽出・正規化 → 集計 → 検知 → 可視化 / 要約**」する、マルチテナント型のデータ収集 + 分析プロダクトとして設計する。スタックは入社先プロダクト領域の実務標準である **TypeScript / Node.js 主軸**に寄せ、ML 推論のみ独立サービスに分離する。**スタックは寄せる、コストは逃がす**（各要素に無料枠 / ローカル開発パスを併記）を方針とする。

| レイヤー | 技術 | 役割 |
|---|---|---|
| **フロント** | TypeScript + React | トレンド可視化・ドリルダウン・収集ヘルス・用語辞書管理 UI |
| **API / バックエンド** | Node.js + TypeScript（NestJS / Express） | 認証・検索/検知 API・要約オーケストレーション・ウォッチリスト |
| **収集ワーカー** | Node.js + TypeScript + キュー（BullMQ / Redis） | Discovery・Fetch・Extract・Dedup を非同期ジョブで実行 |
| **クロール取得** | `undici`/`fetch`（静的）+ **Playwright**（JS レンダリング要時） | 公式 API が無いページ（GitHub Trending 等）の HTML 取得 |
| **抽出 / NER** | TypeScript（辞書 + ルール）+ ML（用語抽出・名寄せ） | 本文 → 技術用語の抽出・正規化・近重複判定 |
| **Embedding 推論** | Python + FastAPI（独立 ML サービス） | `multilingual-e5-base`、query / passage プレフィクス。唯一の非 TS |
| **検索エンジン** | Elasticsearch / OpenSearch | 文書（エビデンス）検索 BM25 + 関連トピック kNN |
| **メタ / テナント DB** | PostgreSQL + RLS | エンティティ（用語・別名・ソース・設定・ウォッチリスト）、テナント分離 |
| **分析基盤（DWH）** | BigQuery | 出現ファクト + 日次集計（トレンド・検知の素） |
| **シークレット** | Secret Manager（GCP / AWS） | テナント別 LLM API キー（BYOK）の暗号化保管 |
| **認証** | OIDC + JWT 検証（JWKS） | サインイン・JWT 検証 |
| **LLM** | Gemini API（BYOK） | 技術サマリ生成（F3）・曖昧性解消の補助 |
| **テスト / 品質** | Playwright（E2E）+ Vitest / Jest（単体・結合）+ GitHub Actions CI | 主要フロー・RLS 越境・検知ロジック回帰 |
| **インフラ** | Docker / Kubernetes | API / 収集ワーカー / 検索 / 推論のコンテナ運用・スケール |
| **クラウド** | GCP 主軸（BigQuery）/ AWS / Azure 可搬 | クラウド非依存設計、Docker / Kubernetes で可搬 |

## 技術選定の理由

### なぜ TypeScript / Node.js 中心

- **入社先プロダクト領域の実務スタック**（自社 Web プロダクトのフルスタックが TS/Node）。フロント・API・収集ワーカー・テストまで 1 言語で一気通貫。
- フロント〜バック〜ワーカーで**型（ソース定義・抽出結果・検知結果のスキーマ）を共有**でき、リファクタ耐性が高い。
- I/O バウンドな収集（多数の HTTP 取得を並行）と相性が良い。

### なぜ収集をキュー + ワーカーに分けるか

- 収集は「多数の URL を礼儀正しく（レート制御しつつ）取得 → 抽出 → 保存」する**長時間・部分失敗前提**の処理。API リクエスト処理から分離し、**キュー（BullMQ / Redis）+ ワーカー**で非同期化する。
- ワーカーは Kubernetes で**水平スケール**でき、ソース別レート制御・リトライ（指数バックオフ）・並列度を制御しやすい。詳細は [06_destinations.md](06_destinations.md)（Source Adapter）。

### なぜクロールは脇役か

- 開発系の信号の大半は **API / フィードで合法かつ綺麗に取れる**（GitHub・Hacker News・Qiita・dev.to・Stack Exchange・npm/PyPI DL 数、GitHub Archive on BigQuery）。
- クロールは**公式 API が無い対象だけ**（GitHub Trending、記事本文、CHANGELOG）。静的は `fetch`、JS レンダリングが要る所だけ Playwright。負荷は日次・数百フェッチ規模で、礼儀正しく回せる。

### なぜ Elasticsearch / OpenSearch

- F6（エビデンス: 用語 → 出典記事・例文）と関連トピック（kNN 近傍）を**同一エンジン**で扱える。BM25（全文）と kNN（ベクトル）を併用でき、日本語アナライザ（kuromoji）も装備。
- 文書は**派生データ（メタ + 短い文脈スニペット + 抽出用語 + embedding）のみ**を格納し、本文全文は持たない（[07_data_strategy.md](07_data_strategy.md)）。TS クライアント（`@elastic/elasticsearch`）でアクセス。

### なぜ Embedding だけ Python の独立サービスか

- `multilingual-e5-base` の推論は Python（`sentence-transformers`）が最も手早い。API / ワーカーに同居させず FastAPI の小さな推論サーバへ分離し HTTP で呼ぶ。
- 用途: 文書 embedding（関連トピック・近重複 dedup）、用語/クエリ embedding。`query:` / `passage:` プレフィクス規約は維持。
- **TS 一本化の余地**: `onnxruntime-node` で ONNX 化すれば Node 内蔵にできる（インターフェース不変）。MVP は実装速度優先で Python サイドカー。

### なぜ BigQuery を DWH の主役に据えるか

- トレンドと検知の素は「**用語 × 日 × ソース × ロケール**の出現集計」という時系列ファクト。これはメタ DB（Postgres）ではなく **DWH（BigQuery）**に置くのが素直。
- **GitHub Archive 等の公開データセットが最初から BigQuery 上にあり**、自前の出現ファクトと同じ場所で結合・集計できる。F1 可視化・F2 検知・F5 JP/Global 比較はすべて BigQuery クエリで実装する。
- 無料枠（クエリ 1TB/月・ストレージ 10GB）に収まりやすい。

### なぜ E2E テストに Playwright を据えるか

- 求人の必須要件が「Web アプリ開発の**コーディングからテストまで**」。テストを**後付けでなく設計の一部**にする。
- 主要フロー（サインイン → トレンド閲覧 → ドリルダウン → ウォッチリスト）を Playwright で E2E 自動化。**RLS のテナント越境が無いことの E2E 検証**は必ず自動化。
- 加えて**検知ロジック（新出 / 急上昇 / 廃れ）の回帰テスト**を固定データセットで担保（[13_testing_strategy.md](13_testing_strategy.md)）。単体・結合は Vitest / Jest、CI は GitHub Actions。

## システム構成図

```
[収集パイプライン（Node ワーカー / BullMQ）]
  Discovery（フィード / sitemap / リスト / API ページング）
    ↓ URL / API 参照をキューへ
  Fetch（礼儀正しい取得: robots 遵守・レート制御・条件付き GET・必要時 Playwright）
    ↓
  Extract（本文抽出 → 用語抽出 NER → 別名正規化）   ──→ [Embedding Service (Python/FastAPI)]
    ↓                                                      └ multilingual-e5-base
  Dedup（content_hash + embedding 近傍で近重複除去）
    ↓
  Store ──→ [PostgreSQL+RLS] エンティティ（用語/別名/ソース/設定/ウォッチリスト）
        ──→ [Elasticsearch]  文書（メタ + スニペット + 用語 + embedding）= F6/関連トピック
        ──→ [BigQuery]       出現ファクト → 日次集計（用語×日×ソース×ロケール）

[検知 / 配信]
  Detect（BigQuery 集計を読み 新出/急上昇/廃れ を算出）→ detections（Postgres）
  Summarize（F3: ES から該当文書を取り Gemini[BYOK]で要約）→ summaries（キャッシュ）

[ユーザーブラウザ] React/TS
  │ HTTPS
  ↓
[Node.js API（NestJS/Express）]
  - OIDC JWT 検証 → テナント解決（アプリ層）
  - トレンド/検知/エビデンス/関連トピック API（BigQuery + ES 読み）
  - ウォッチリスト・用語辞書管理（Postgres、SET LOCAL app.tenant_id）
  - 要約要求（Gemini BYOK）

[テスト / CI] GitHub Actions → Vitest/Jest + Playwright（主要フロー + RLS 越境 + 検知回帰）
```

## ホスティング構成（マルチクラウド / Docker・Kubernetes）

Docker / Kubernetes でコンテナ化し AWS・GCP・Azure いずれにも載る可搬構成。DWH（BigQuery）は GCP。**主軸は GCP**（BigQuery 重力）だが、ストレージ / シークレットは抽象化してマルチクラウド可搬を保つ。

| 役割 | サービス例 | 無料枠 / ローカル開発パス |
|---|---|---|
| フロント / API | Cloud Run / ECS / App Runner | コンテナ無料枠。ローカルは `docker compose` |
| 収集ワーカー + キュー | GKE / EKS 上の Deployment + Redis | ローカルは compose、本番は 1〜数ノード。`kind` で K8s も再現 |
| 検索 | 小型 VM / ノード上に OpenSearch 自前（単一ノード） | ローカルは compose。スケール時に managed |
| メタ DB | Cloud SQL / RDS PostgreSQL 最小 | ローカルは Postgres コンテナ |
| Embedding 推論 | Cloud Run / ECS（CPU） | ローカルは FastAPI コンテナ |
| DWH | BigQuery（GCP） | クエリ 1TB/月・10GB 無料枠 |
| シークレット | Secret Manager（GCP / AWS） | dev は `.env`（gitignore） |
| LLM | 利用者 BYOK（Gemini） | サービス側負担なし |

**接続パターン**:
- Node はリクエスト / ジョブ単位トランザクションの先頭で、確定した `tenant_id` を `SET LOCAL app.tenant_id` で発行 → RLS が参照（[04_security_multitenant.md](04_security_multitenant.md)）。
- 認証は OIDC プロバイダの JWT（JWKS）検証のみ利用、テナント解決はアプリ層で完結。
- グローバル（共有）データ（用語・出現・集計・公開ソース・文書）はテナント非依存で読み取り、テナント単位データ（ウォッチリスト・設定・プライベートソース）のみ RLS で分離する（**軽量マルチテナント**）。

## 月額予算とコスト感覚

| 項目 | 無料枠での配置 | スケール時の課金ポイント |
|---|---|---|
| フロント / API | Cloud Run / ECS 無料枠 | リクエスト増 → 従量 |
| 収集ワーカー + Redis | 小型ノード自前 | 収集ソース / 頻度増 → ノード増 |
| 検索 | 単一ノード OpenSearch 自前 | 文書 / QPS 増 → managed |
| メタ DB | Cloud SQL / RDS 最小 | 容量・接続数 → 昇格 |
| DWH | BigQuery 1TB/月無料 | クエリ量 / スキャン量超過 → 従量（パーティション・集計で抑制） |
| Embedding | Cloud Run / ECS CPU | 同時推論増 → GPU / 常駐 |
| LLM | 利用者 BYOK | サービス側負担なし |

**「収集頻度・BigQuery スキャン量・推論負荷のどれが先に効くか」**を予測できる状態で持つ。特に BigQuery は**パーティション（日付）+ 事前集計テーブル**でスキャン量を抑えるのがコスト勘所（[07_data_strategy.md](07_data_strategy.md)）。
