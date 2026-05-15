# 02. アーキテクチャ

## 技術スタック

| レイヤー | 技術 | 役割 |
|---|---|---|
| **フロント** | Blazor Server (C#) | UI全体・コンボボックス・動的フォーム描画 |
| **バックエンド** | ASP.NET Core (C#) + EF Core | API・ビジネスロジック・DB操作 |
| **DB本体** | Postgres (Supabase または自前) | 永続化 |
| **DB拡張** | pgvector | Embedding ベクトル類似度検索 |
| **DB拡張** | Supabase Vault (pgsodium) | API キー暗号化保管 |
| **DB機能** | Row Level Security (RLS) | テナント分離 |
| **認証** | Supabase Auth | サインアップ、JWT発行 |
| **LLM** | Gemini API（BYOK） | クエリ書き換え・動的フォーム推論等 |
| **Embedding 推論** | Python + FastAPI（別サービス） | C# から HTTP 経由で呼出 |
| **オフラインML** | Python（座布団さんローカル） | 将来のモデルFT |
| **JS** | 最小限 | ファイルアップロード進捗、`embed.js` 等 |

## 技術選定の理由

### なぜ C# + Python + 最小JS

- **既存スキル活用**：Unity C# 経験、既存 Streamlit 版で Python 実績
- **背伸びしない**：TypeScript一本にすると学習コストで開発速度が落ちる
- **grasys 訴求**：C# は数は少ないが質の高い案件が多い、Python ML スタックも評価される

### なぜ Blazor Server

- C# でフルスタック完結（型安全・コード共有）
- SignalR で双方向通信が標準実装、リアルタイム性も将来確保
- WebAssembly 版に比べてサーバ側ロジックがそのまま使える

### なぜ Python の Embedding を別サービスにする

- `intfloat/multilingual-e5-base` の C# 直接実行は ONNX 化が必要で MVP コスト過大
- FastAPI で小さい推論サーバを建て、C# から HTTP 呼出 する方が手早い
- Phase 2 で ONNX 化 + C# 内蔵化に切替可能（インターフェース変更不要）

### なぜ Embedding **だけ** ではないか

- Embedding 単独は固有名詞・型番・エラーコードに弱い
- BM25（Postgres `tsvector`）と組合せる現代標準（RRF）を採用
- 詳細：[05_search_classification.md](05_search_classification.md)

## システム構成図

```
[ユーザーブラウザ]
  │  Transformers.js でクエリのみ embedding（Phase 2）
  │  embed.js ウィジェット
  │
  ↓ HTTPS / SignalR (WebSocket)
  │
[Blazor Server + ASP.NET Core]
  │  - 認証（Supabase JWT 検証）
  │  - 分類フロー処理
  │  - 動的フォーム描画
  │  - 起票 Adapter 呼出
  │
  ├─→ [FastAPI Embedding Service]
  │     └ multilingual-e5-base
  │
  ├─→ [Postgres + pgvector + Vault]
  │     ├ tenants, users, knowledge_entries, ...
  │     ├ RLS でテナント分離
  │     └ Vault で API キー暗号化
  │
  ├─→ [Gemini API]（BYOK 時のみ、利用者のキー使用）
  │
  └─→ [外部起票先]
        ├ Redmine
        └ GitHub Issues
```

## ホスティング構成

> **採用構成: Plan B 確定**。Plan A（Oracle Cloud 自前運用）は MVP では追わず、Phase 2 で語る課題に格下げ。理由: 認証/Vault の自前実装（ASP.NET Core Identity / pgsodium 直叩き）はコア機能の実装時間を奪い、採用訴求にもならないため。

### Plan B（採用構成）: Azure F1 + Supabase + HF Spaces

| 役割 | サービス | 無料枠 |
|---|---|---|
| Blazor フロント | Azure App Service F1 | 60分CPU/日、コールドスタートあり |
| Embedding 推論 | Hugging Face Spaces (CPU) | 制限あるが ML 用途で実績 |
| DB / Auth / Vault | Supabase Free | 500MB DB、50,000 MAU、pgsodium 同梱 |
| Keep-alive ping | GitHub Actions cron | 寝防止用 |

**運用上の手当て**:
- GitHub Actions cron で 15 分おきにヘルスチェック（無料枠 60 分 CPU/日 との兼合いを見ながら）
- Supabase は 7 日無操作で自動一時停止 → 週 1 で API ping
- 採用面接前夜は手動で warm-up

**接続パターン**:
- ASP.NET Core は Supabase Postgres に**直接接続**（PostgREST は経由しない）
- 認証は Supabase Auth の JWT 検証のみ利用、`auth.uid()` ベースの RLS は使わない（[04_security_multitenant.md](04_security_multitenant.md) 参照）

### Plan A（Phase 2 課題）: Oracle Cloud Always Free に移行する場合

参考まで、Plan A に切替えた場合の構成:

```
Oracle Cloud Always Free VM (24GB RAM)
└ Docker Compose
   ├ Blazor Server コンテナ（ASP.NET Core）
   ├ FastAPI Embedding コンテナ
   ├ Postgres + pgvector コンテナ（pgsodium 自前セットアップ）
   └ Caddy（HTTPS 自動）
```

**Plan A の魅力**: コールドスタートなし、24GB RAM、月額 $0。**移行時の追加実装**: ASP.NET Core Identity への置換、pgsodium による Vault 相当の自前構築、ARM A1 の空き枠リトライ運用。

面接で語る:

> 「MVP は Supabase の Auth / Vault に乗って認証・秘匿情報保管の自前実装を回避し、コア機能に時間を投資した。スケールやコスト最適化の文脈では Oracle Cloud Always Free への移行案も検討済みで、pgsodium 自前構築や Identity への置換コストまで見積もっている」

## 月額予算明細

| 項目 | Plan B（採用構成） | Plan A（参考） |
|---|---|---|
| VM/フロント | $0（Azure F1） | $0（OCI Always Free） |
| Embedding 推論 | $0（HF Spaces） | $0（同居） |
| DB | $0（Supabase Free） | $0（自前 Postgres） |
| LLM | $0（利用者 BYOK） | $0（同左） |
| メール通知 | $0（SendGrid / Resend 無料枠） | $0 |
| ドメイン | $10〜15/年（Cloudflare） | $10〜15/年 |
| **合計** | **$0/月**（年 $10〜15） | **$0/月**（年 $10〜15） |

## スケール時の有料化ポイント（面接で語れる）

| ボトルネック | 切替先 | 月額 |
|---|---|---|
| 同時接続増 | Azure App Service Basic B1 | $13 |
| Embedding 計算負荷 | HF Spaces CPU Pro / GPU Space | $9〜 |
| DB 500MB 超え | Supabase Pro | $25 |
| LLM 自前提供 | Gemini API（テナント数 × 利用量） | 従量 |

「**コスト感覚あるエンジニア**」の証明として、これらを語れる状態で持つ。
