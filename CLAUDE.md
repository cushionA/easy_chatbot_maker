# easy_chatbot_maker — Project rules

マルチテナント RAG チャットボット SaaS（社内ナレッジ起票補助）。設計の全体像は [`design/README.md`](design/README.md)。サブシステムごとの規約は各サブディレクトリの `CLAUDE.md` を参照する。

## サブプロジェクト

| パス | 役割 | 規約 |
|---|---|---|
| `embedding/` | FastAPI + sentence-transformers (multilingual-e5-base) | [`embedding/CLAUDE.md`](embedding/CLAUDE.md) |
| `infra/db/` | Postgres init + 0001_schema.sql（pgvector / pg_trgm / GIN / HNSW） | — |
| `infra/caddy/` | 本番リバースプロキシ（profiles=prod） | — |
| `design/` | 設計ドキュメント 12 章（仕様の **正**） | — |

## 横断ルール

- **テナント境界**: 全テーブルに `tenant_id`、Postgres RLS でアプリ層から強制分離（[`design/04_security_multitenant.md`](design/04_security_multitenant.md)）。クライアント由来の tenant id は信頼しない — JWT クレームから取る。
- **BYOK**: LLM (Gemini) API キーはテナントごとに Vault 保管。サーバの `appsettings.*` には保持しない。
- **Embedding 規約**: `multilingual-e5-base` は query には `query:`、文書には `passage:` プレフィクスを付ける。`/embed` の `mode` パラメータで切り替える。
- **正の情報源**: コードと `design/` が食い違ったら `design/` を確認し、必要なら設計を更新してからコードを直す。
- **言語**: コミュニケーション・コミットメッセージは日本語で良いが、コードコメント・識別子・PR タイトルは英語。
- **コーディング規約**: スタック別の書き方・定義順・コメント・レビュー基準は [`docs/conventions/`](docs/conventions/README.md)、品質ツールの使い方は [`docs/conventions/TOOLING.md`](docs/conventions/TOOLING.md)。

## 主要コマンド

```bash
make lint          # 全サブシステムの lint
make test          # 全サブシステムの test
make up            # docker compose up --build
make logs          # 起動中サービスのログ追跡
make scan          # プロンプトインジェクション検査 (staged diff)
make secrets       # gitleaks
```

詳細ターゲットは `make help` で一覧。

## プロジェクト固有スキル（`.claude/skills/`）

- **`sprint-plan`** — Sprint ゴールから `design/sprintN_plan.md` と `design/sprintN/dayX.md` を生成。タスク 1 PR 粒度に分解し [自分]/[AI] 委譲タグを付ける。
- **`pair-start`** — `design/sprint*/day*.md` からタスクを 1 つ選んで伴走モードでペアプロ開始。前提確認を実機チェックしてから 1 ステップずつ進める。

参照実装は [`design/sprint1_plan.md`](design/sprint1_plan.md) と [`design/sprint1/`](design/sprint1/)。

## CI / pre-commit

- `.github/workflows/ci.yml`: embedding (ruff + mypy + pytest) / node (eslint + tsc) / sql (sqlfluff) / docker-build / pr-security の 5 ジョブ。
- `.github/workflows/codeql.yml`: Python マトリクス、weekly schedule、`security-extended` クエリ。
- `.pre-commit-config.yaml`: trailing-whitespace / detect-private-key / gitleaks / ruff / pr-validate（`.claude/scripts/pr-validate.py` を vendored）。
- `pre-commit install` を実行してから作業を開始する。

## Forbidden / 全体方針

- Secrets を `appsettings.json` / `.env.example` / コード本文にコミットしない。
- 設計の方針を勝手に変えない（特にテナント分離・BYOK・query/passage 規約）。
- `appsettings.*.json` は `Development.json` だけが gitignore 例外。Production 値は環境変数で注入。
- 横断的に変える変更（10 ファイル以上 or 複数サブシステム）は PR を分割する。
