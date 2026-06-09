# 02. アーキテクチャ

## 技術スタック

本サービスは「**組織のナレッジマスタを 取込 → 構造化 → 検索 → 回答 / 起票補助**」する、マルチテナント型の AI / LLM フルスタック Web プロダクトとして設計する。スタックはこのドメインの実務標準である **TypeScript / Node.js を主軸としたフルスタック**（フロント＋API＋インフラ＋テスト）に合わせて選定し、ML 推論のみ独立サービスに分離した。

| レイヤー | 技術 | 役割 |
|---|---|---|
| **フロント** | TypeScript + React | 管理画面・チャット UI・動的フォーム描画 |
| **API / バックエンド** | Node.js + TypeScript（NestJS / Express） | 認証・分類フロー・RAG オーケストレーション・起票 Adapter |
| **マスタ取込** | TypeScript（Excel / JSON パーサ） | マスタの取込・正規化・インデックス投入（社内システム由来） |
| **検索エンジン** | Elasticsearch / OpenSearch | BM25 + kNN ベクトルのハイブリッド検索（RRF） |
| **Embedding 推論** | Python + FastAPI（独立 ML サービス） | `multilingual-e5-base`、query / passage プレフィクス。唯一の非 TS コンポーネント |
| **メタ / テナント DB** | PostgreSQL + RLS | テナント・ユーザー・ナレッジメタ・設定の永続化、テナント分離 |
| **分析基盤（DWH）** | BigQuery | 利用ログ・検索品質指標の集計・可視化 |
| **シークレット** | Secret Manager（AWS / GCP） | テナント別 LLM API キー（BYOK）の暗号化保管 |
| **認証** | OIDC + JWT 検証 | サインアップ・JWT 発行 |
| **LLM** | Gemini API（BYOK） | クエリ書き換え・動的フォーム推論・低確信度フォールバック |
| **テスト / 品質** | Playwright（E2E）+ Vitest / Jest（単体・結合）+ GitHub Actions CI | 主要フロー E2E・RLS 越境検証・回帰防止 |
| **インフラ** | Docker / Kubernetes | API / 検索 / 推論のコンテナ運用・スケール |
| **クラウド** | AWS / GCP（BigQuery）・Azure 可 | マルチクラウド対応、Docker / Kubernetes で可搬 |

## 技術選定の理由

### なぜ TypeScript / Node.js 中心

- **プロダクトドメインの実務スタック**：対象プロダクト領域（自社 Web アプリ）の開発は TypeScript / Node.js によるフルスタックが標準。フロント・API・インフラ・テストまで一気通貫で関わる体制に合わせた。
- **型をフロント〜バックで共有**：TypeScript で UI と API のスキーマ（DTO・バリデーション）を共有でき、フルスタックでの整合性とリファクタ耐性を確保する。
- **背伸びの最小化**：既存スキルを土台に、フロント・API・テストを 1 言語（TS）で完結させ、学習コストと開発速度を両立する。

### なぜ Elasticsearch / OpenSearch（自前 Postgres 全文検索からの移行）

- ナレッジはテナント横断で文書数が伸びる。Postgres `tsvector` 単体では転置インデックス運用・アナライザ・スケールアウトに限界がある。
- Elasticsearch は **BM25（全文）と kNN（ベクトル）を同一エンジンで** 扱え、ハイブリッド検索（RRF）をマネージドに寄せられる。日本語アナライザ（kuromoji）や同義語辞書も実務装備。
- 「取込 → インデックス → 検索」がプロダクトの核なので、検索基盤を専用エンジンに置くことで運用とチューニングが素直になる。TS クライアント（`@elastic/elasticsearch`）でアクセスする。詳細：[05_search_classification.md](05_search_classification.md)。

### なぜ Embedding だけ Python の独立サービスにするか

- `multilingual-e5-base` の推論は Python エコシステム（`sentence-transformers`）が最も手早い。API に同居させると推論負荷がリクエスト処理を圧迫するため、FastAPI の小さな推論サーバに切り出し HTTP 経由で呼ぶ。
- query には `query:`、文書には `passage:` プレフィクスを付ける規約は維持する。
- **スタックを TypeScript に一本化したい場合の発展余地**：`onnxruntime-node` で ONNX 化したモデルを Node 内蔵にすれば Python を排除できる（インターフェース不変）。MVP では実装速度を優先し Python サイドカーに倒す。

### なぜ E2E テストに Playwright を据えるか

- 求人の必須要件が「Web アプリ開発の**コーディングからテストまで**」、担当工程にも「テスト」が明記。テストを **後付けではなく設計の一部**として最初から組み込む。
- 主要ユーザーフロー（サインアップ → マスタ取込 → 検索 → 回答 / 起票）を **Playwright で E2E 自動化**。Playwright はマルチブラウザ・トレース・並列実行が標準で、CI 親和性が高い。
- 特に **RLS のテナント越境がないことの E2E 検証**は漏洩したらアウトなので必ず自動テスト化する。単体・結合は Vitest / Jest、すべて GitHub Actions CI で回す。詳細なテスト仕様は [13_testing_strategy.md](13_testing_strategy.md)。

### なぜ BigQuery を足すか

- 利用ログ・検索品質指標（ヒット率・未分類率・低確信度率）は時系列で増えるため、メタ DB（PostgreSQL）とは分離し DWH（BigQuery）へ寄せる。
- 「プロダクト → 計測 → 改善」までを一気通貫で説明できる構成にする。

## システム構成図

```
[ユーザーブラウザ]
  │  React + TypeScript（管理画面 / チャット UI / embed.js ウィジェット）
  │
  ↓ HTTPS / WebSocket
  │
[Node.js + TypeScript バックエンド（NestJS / Express）]
  │  - 認証（OIDC JWT 検証 → テナント解決）
  │  - マスタ取込（Excel / JSON 正規化 → インデックス投入）
  │  - 分類フロー / RAG オーケストレーション
  │  - 動的フォーム描画データ
  │  - 起票 Adapter 呼出
  │
  ├─→ [Elasticsearch / OpenSearch]
  │     └ BM25 + kNN ハイブリッド（RRF）
  │
  ├─→ [Embedding Service（Python / FastAPI）]
  │     └ multilingual-e5-base（query / passage）
  │
  ├─→ [PostgreSQL + RLS]
  │     ├ tenants, users, knowledge_meta, ...
  │     └ RLS でテナント分離
  │
  ├─→ [Secret Manager]（BYOK の LLM キー）
  │
  ├─→ [Gemini API]（BYOK 時のみ、利用者のキー使用）
  │
  └─→ [外部起票先]（Redmine / GitHub Issues）

[テスト / CI]
  GitHub Actions
   ├─→ Vitest / Jest（単体・結合）
   └─→ Playwright（E2E: 主要フロー + RLS 越境がないことの検証）
```

## ホスティング構成（マルチクラウド / Docker・Kubernetes）

Docker / Kubernetes でコンテナ化し、AWS・GCP・Azure いずれにも載せられる可搬構成にする。DWH（BigQuery）は GCP を利用。

| 役割 | サービス例 | 備考 |
|---|---|---|
| フロント / API | Cloud Run / ECS / App Runner | コンテナ・従量・無料枠あり |
| 検索 | GKE / EKS（または小型 VM 上の Docker） | OpenSearch |
| メタ DB | Cloud SQL / RDS for PostgreSQL | RLS でテナント分離 |
| Embedding 推論 | Cloud Run / ECS（CPU） | multilingual-e5-base |
| DWH | BigQuery | 1TB/月クエリ無料枠（GCP） |
| シークレット | Secret Manager / AWS Secrets Manager | BYOK キー暗号化保管 |

**接続パターン**:
- Node.js バックエンドは PostgreSQL に**直接接続**し、確定した `tenant_id` をセッション変数（`SET LOCAL app.tenant_id`）で発行 → RLS が参照（[04_security_multitenant.md](04_security_multitenant.md)）。
- 認証は OIDC プロバイダの JWT 検証のみ利用し、テナント解決はアプリ層で完結させる。

## 月額予算とコスト感覚

専用検索エンジン・DWH を持つ構成は、純粋な $0 運用より production 寄りになる。無料枠を最大限使いつつ、**どこから課金が始まるか**を設計時に把握しておく。

| 項目 | 無料枠での配置 | スケール時の課金ポイント |
|---|---|---|
| フロント / API | Cloud Run / ECS 無料枠 | リクエスト増 → 従量 |
| 検索 | 小型 VM 上に OpenSearch 自前 | 文書 / QPS 増 → Elastic Cloud / OpenSearch Service |
| メタ DB | Cloud SQL / RDS 最小 | 容量・接続数 → インスタンス昇格 |
| DWH | BigQuery 1TB/月無料 | クエリ量超過 → 従量 |
| Embedding | Cloud Run / ECS CPU | 同時推論増 → GPU / 常駐 |
| LLM | 利用者 BYOK | サービス側負担なし |

「**検索負荷・DWH クエリ量・推論負荷のどれが先に効くか**」を予測できる状態で持つ。「**コスト感覚のあるエンジニア**」の証明として、これらを語れる状態にする。
