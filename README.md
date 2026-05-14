# Portfolio - Service A

Web エンジニア転職用のポートフォリオ。**ナレッジ起票補助 RAG チャットボット** をマルチテナント SaaS として実装する。Streamlit 製 PoC（`チャットボット/helpdesk_bot`）の運用知見を、業務 SaaS 相当のアーキテクチャに作り直したもの。

設計の全体像は [`design/README.md`](design/README.md) を参照。

---

## 技術スタック

| レイヤー | 採用技術 |
|---|---|
| フロント / バックエンド | Blazor Server + ASP.NET Core 8 (C#) |
| Embedding 推論 | FastAPI + sentence-transformers (`intfloat/multilingual-e5-base`) |
| DB | Postgres 16 + pgvector + pg_trgm |
| 認証 | Supabase Auth（Plan B 構成時） |
| LLM | Gemini API（BYOK） |
| インフラ | Docker Compose / Oracle Cloud Always Free |
| CI | GitHub Actions (lint / test / build) + CodeQL + Dependabot |

詳細は [`design/02_architecture.md`](design/02_architecture.md)。

---

## ディレクトリ構成

```
.
├─ backend/                ASP.NET Core 8 + Blazor Server
│  ├─ Portfolio.Web/       本体
│  └─ Portfolio.Web.Tests/ 統合テスト (xUnit)
├─ embedding/              FastAPI 推論サービス
│  ├─ app/
│  └─ tests/               pytest（FAKE_EMBEDDER でモデルロード回避）
├─ infra/
│  ├─ db/init.sql          pgvector / pg_trgm 拡張作成
│  └─ caddy/Caddyfile      Plan A 用 リバプロ
├─ design/                 設計ドキュメント（12 章）
├─ docker-compose.yml
├─ .github/workflows/      CI / CodeQL
└─ .pre-commit-config.yaml
```

---

## ローカル開発

### 前提
- Docker Desktop / Docker Engine
- .NET SDK 8.0
- Python 3.11+
- pre-commit (`pip install pre-commit && pre-commit install`)

### 起動

```bash
cp .env.example .env
docker compose up --build
```

| サービス | URL |
|---|---|
| Blazor (Web) | http://localhost:8080 |
| FastAPI (Embedding) | http://localhost:9000/healthz |
| Postgres | localhost:5432 |
| Swagger UI | http://localhost:9000/docs |

### 個別実行

```bash
# Embedding 単体（モデル DL 不要、フェイク埋め込み）
cd embedding
pip install -e ".[dev]"
FAKE_EMBEDDER=1 uvicorn app.main:app --reload --port 9000

# Backend 単体
cd backend
dotnet run --project Portfolio.Web
```

---

## テスト

```bash
# Backend
cd backend && dotnet test

# Embedding (FAKE モード)
cd embedding && FAKE_EMBEDDER=1 pytest
```

CI（`.github/workflows/ci.yml`）は push / PR で同等のジョブを実行する。

---

## デプロイ方針

| プラン | 想定環境 | 用途 |
|---|---|---|
| A | Oracle Cloud Always Free VM + Docker Compose + Caddy | 本命（コールドスタートなし） |
| B | Azure App Service F1 + Supabase + HF Spaces | フォールバック |

詳細は [`design/02_architecture.md#ホスティング構成`](design/02_architecture.md)。

---

## セキュリティ

- マルチテナント分離は Postgres **Row Level Security** で実装（[`design/04_security_multitenant.md`](design/04_security_multitenant.md)）
- API キー類は **Supabase Vault (pgsodium)** で暗号化保管
- LLM キーは **BYOK**（サーバ側に保持しない）
- 依存性: **Dependabot** weekly + **CodeQL** で C# / Python 静的解析
- PR 単位で `pr-validate.py`（プロンプトインジェクション検出）を CI で実行

---

## ライセンス

[MIT](LICENSE)
