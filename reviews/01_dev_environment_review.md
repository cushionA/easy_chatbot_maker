# 01 開発環境品質レビュー — easy_chatbot_maker

レビュー対象コミット: ワーキングツリー（2026-05-15 時点）
スコープ: Claude Code 活用状況 / 開発ライフライン（dev lifecycle）

---

## 概要

`easy_chatbot_maker` は Blazor Server (.NET 8) + FastAPI 埋め込みサービス + Postgres(pgvector) を Docker Compose で束ねる、社内向けマルチテナント RAG プラットフォームである。dev lifecycle は `Makefile` / `pre-commit` / `GitHub Actions` / `Dependabot` / `CodeQL` がそろい、PR テンプレ・Issue テンプレ・CODEOWNERS まで整備されている水準で、業務 SaaS リファレンス実装として相応に成熟している。一方で **ルート `CLAUDE.md` の不在** と **`.claude/` ディレクトリの完全欠落**（settings.json / agents / commands / hooks / SessionStart）が顕著なギャップで、Claude Code on the Web で動かす準備という観点では未着手に近い。サブプロジェクト側 (`backend/CLAUDE.md`, `embedding/CLAUDE.md`) は内容が濃く、規約・禁止事項・テスト方針が具体的で実用度が高い。

---

## 良い点

### dev lifecycle 周り

- **README.md** (`/home/user/easy_chatbot_maker/README.md`) が技術スタック表、ディレクトリ構成、ローカル起動・個別実行・テスト・デプロイ方針までワンストップで揃っており、初見オンボーディングが完結する。
- **CONTRIBUTING.md** (`/home/user/easy_chatbot_maker/CONTRIBUTING.md`) でブランチ戦略・Conventional Commits・コード品質ゲート表が明文化されており、レビュー基準（テナント境界・BREAKING・セキュリティ）まで踏み込んでいる。
- **Makefile** (`/home/user/easy_chatbot_maker/Makefile`) が `.SHELLFLAGS := -eu -o pipefail -c` を設定、`help` ターゲットで `## コメント` を自動抽出する形式で UX が良い。`install-tooling` / `lint` / `test` / `format` / `up` / `secrets` / `scan` まで網羅。
- **docker-compose.yml** (`/home/user/easy_chatbot_maker/docker-compose.yml`) で `postgres.healthcheck` + `depends_on.condition: service_healthy` を使い起動順を担保。`caddy` は `profiles: [prod]` で本番だけ起動する分離が綺麗。
- **.env.example** (`/home/user/easy_chatbot_maker/.env.example`) で Plan A/B 切替、BYOK 方針（`GEMINI_API_KEY` は空でコミット）まで含めて記述されている。
- **.editorconfig** (`/home/user/easy_chatbot_maker/.editorconfig`) と **backend/.editorconfig** が二段階で構成され、C# / YAML / Markdown ごとに正しく粒度分けされている。
- **.gitignore** (`/home/user/easy_chatbot_maker/.gitignore`) は `.env`, `appsettings.*.json`（ただし `Development.json` は許可）, `.vscode/settings.json`, `*.pfx` まで含む丁寧な構成。
- **pre-commit** (`/home/user/easy_chatbot_maker/.pre-commit-config.yaml`) に trailing-whitespace / detect-private-key / ruff / gitleaks / dotnet-format / プロンプトインジェクションスキャンを設定。`.pre-commit-config.yaml:25-28` の gitleaks 統合は秘密混入を防ぐ実効的措置。
- **CI** (`/home/user/easy_chatbot_maker/.github/workflows/ci.yml`) は backend / embedding / docker-build / pr-security の 4 ジョブ構成。`concurrency.cancel-in-progress: true`、NuGet/pip キャッシュ、GHA キャッシュ付き docker buildx まで使われており CI 時間最適化が済んでいる。
- **CodeQL** (`/home/user/easy_chatbot_maker/.github/workflows/codeql.yml`) が C# / Python マトリクス + 週次スケジュール（月 18:00 UTC）で構成済み。
- **dependabot.yml** (`/home/user/easy_chatbot_maker/.github/dependabot.yml`) で nuget / pip / docker / github-actions 5 種、`groups` を使った ASP.NET Core / FastAPI / ML 依存のまとめ更新まで設計済み。
- **CODEOWNERS** / **PULL_REQUEST_TEMPLATE.md** / **ISSUE_TEMPLATE/bug_report.yml & feature_request.yml** が全部揃っており、PR テンプレには Security checklist（外部入力検証 / SQL パラメータ化 / LLM プロンプトサニタイズ）まで含まれる。
- **.vscode/extensions.json** (`/home/user/easy_chatbot_maker/.vscode/extensions.json`) に `Anthropic.claude-code` 拡張機能の推奨と、`unwantedRecommendations` で flake8/black/pylint を明示的に排除している。`.vscode/tasks.json` に build / test / lint / compose タスクが揃う。
- **Dockerfile (backend)** (`/home/user/easy_chatbot_maker/backend/Dockerfile`) は SDK→aspnet マルチステージ、`USER app` で非 root 化、`-p:UseAppHost=false` も適切。
- **Dockerfile (embedding)** (`/home/user/easy_chatbot_maker/embedding/Dockerfile`) も `python:3.11-slim`、非 root ユーザ作成、HEALTHCHECK 設定、`HF_HOME` / `SENTENCE_TRANSFORMERS_HOME` の永続化先設定までできている。
- **backend/Directory.Build.props** で `TreatWarningsAsErrors=true` / `AnalysisMode=AllEnabledByDefault` / `EnforceCodeStyleInBuild=true` が一括設定され、品質ゲートを MSBuild で担保。
- **embedding/pyproject.toml** で `ruff` ルール `[E,W,F,I,B,UP,S,SIM,RUF,TID,PT]`、`mypy --strict` 相当（`disallow_untyped_defs=true` 等）、`pytest --strict-markers --strict-config` まで設定済み。
- **テスト**: `backend/Portfolio.Web.Tests/HealthTests.cs` は `WebApplicationFactory<Program>` + `WithWebHostBuilder` で接続設定をテスト時上書きしており、CLAUDE.md の指針 (`environment globally に変えるな`) と整合。`embedding/tests/conftest.py` で `FAKE_EMBEDDER=1` を強制し、`tests/test_main.py` で healthz / embed / batch / バリデーション(422/400) を網羅。

### Claude Code 周り（できている部分）

- **backend/CLAUDE.md** (`/home/user/easy_chatbot_maker/backend/CLAUDE.md`) が「Build/test commands」「C# conventions（file-scoped namespace, primary constructor, sealed, async + CancellationToken）」「Blazor の `@rendermode InteractiveServer` 明示」「EF Core / RLS」「Forbidden（Newtonsoft, AutoMapper, Task.Run の擬似 async）」まで具体的・実行可能で、エージェントへの指示として実効性が高い。
- **embedding/CLAUDE.md** (`/home/user/easy_chatbot_maker/embedding/CLAUDE.md`) も同様で、PEP 695 generics, PEP 604 unions, e5-base の `query:` / `passage:` プレフィクス慣習、CORS デフォルト閉じる、テスト時のモデル読み込み禁止、まで網羅。実装上の落とし穴をエージェントに伝える非常に良い CLAUDE.md。
- 両 CLAUDE.md とも先頭で「Scope: ... Global rules in `~/.claude/CLAUDE.md` still apply on top.」と明示し、グローバル設定との合成方針を示している。

---

## 問題点 / リスク

### [重要度: 高] ルート `CLAUDE.md` が存在しない

- 確認結果: `/home/user/easy_chatbot_maker/CLAUDE.md` は **存在しない**（`ls -la` で確認、`platform_proposal.md` は別物）。
- 影響: Claude Code がリポジトリ直下で動いたとき、最初に読むべき俯瞰情報（プロジェクト全体像 / 主要ディレクトリ / 共通ルール / どの CLAUDE.md を見るべきか）が無く、毎セッションで `backend/` と `embedding/` のどちらに居るかでしか文脈が得られない。
- 根拠: `backend/CLAUDE.md` は冒頭で `~/.claude/CLAUDE.md` を参照させるが、これは個人のグローバル設定でありリポジトリ固有のクロスサービス規約（テナント境界・BYOK・design 文書の優先順位）を共有できない。

### [重要度: 高] `.claude/` ディレクトリが完全に欠落

- 確認結果: `/home/user/easy_chatbot_maker/.claude/` は **存在しない**。
- 影響:
  - `settings.json` が無いため、`permissions.allow` で許可コマンドが事前定義されておらず、Claude Code on the Web では多数のコマンドで permission prompt が発生する。
  - `agents/` が無く、`CONTRIBUTING.md:69` が要求している「Security Engineer agent でセルフレビュー」を実行する受け皿がリポジトリ内に無い（個人グローバルにしか存在し得ない＝チーム共有不可）。
  - `commands/` が無く、`make lint && make test` などをワンショットで実行するスラッシュコマンドが定義されていない。
  - `hooks/` が無く、特に **SessionStart hook が未設定** のため、Web セッションで `dotnet restore` / `pip install -e ".[dev]"` / `pre-commit install` が自動実行されない。Web 版で開いた瞬間に lint/test を走らせる準備ができていない。
  - `.pre-commit-config.yaml:38-43` と `Makefile:93-98`, `.github/workflows/ci.yml:108-115` がいずれも `$HOME/.claude/scripts/pr-validate.py` または `.claude/scripts/pr-validate.py` を参照しているが、**リポジトリにはこのスクリプトが無い**。CI ログには `::warning::.claude/scripts/pr-validate.py not present in repo; skipping` が出続け、pre-commit ローカル実行も常時 no-op になる。プロンプトインジェクション検査が事実上機能していない。

### [重要度: 中] CI と pre-commit の整合性ギャップ

- pre-commit (`/home/user/easy_chatbot_maker/.pre-commit-config.yaml`) は `mypy` を実行しない。一方 `CONTRIBUTING.md:57` と `Makefile:57-58` (`lint.embedding`) は `mypy app` を含む。pre-commit / Makefile / CI のいずれかで mypy が抜けると、PR 後に CI で初めて型エラーが露見しがち。
  - 具体: `.github/workflows/ci.yml:58-61` も `ruff check` と `ruff format --check` のみで `mypy` を実行していない。**CI で mypy が走っていない** ことが最大のギャップ。
- pre-commit に `check-toml` が無い（`pyproject.toml` を変更する PR で破壊しても引っかからない）。
- pre-commit に CodeQL のローカル相当（例: bandit）が無いが、これは CodeQL を CI で回しているので低優先で良い。

### [重要度: 中] CI が embedding のビルドだけで sentence-transformers の依存 (~500MB) を pull する

- `.github/workflows/ci.yml:42-63` は `pip install -e ".[dev]"` をフルで実行する。テスト自体は `FAKE_EMBEDDER=1` だが、依存解決で `torch` / `sentence-transformers` をインストールしているため CI 時間とキャッシュサイズを浪費する。
- 対策: `pyproject.toml` に `test` extras を切る、または CI 用 `requirements-test.txt` を用意する。

### [重要度: 中] backend テストカバレッジが healthz の 1 本のみ

- `/home/user/easy_chatbot_maker/backend/Portfolio.Web.Tests/HealthTests.cs` は 1 テストのみ。`backend/CLAUDE.md:37-40` で要求している「One test class per production class」を満たしていない。
- Codecov / カバレッジ収集も CI 未設定（`ci.yml` は `trx` ファイルを upload するのみで、PR コメントや閾値検査が無い）。

### [重要度: 中] embedding Dockerfile に dev 依存 (pytest 等) が混入する可能性

- `Dockerfile:14-15` で `pip install .` （非 dev）になっている。正しい。ただし `pyproject.toml` の `dependencies` に `sentence-transformers` 等の重い依存が常時含まれるため、`FAKE_EMBEDDER` 用の軽量イメージは別ターゲットになっていない。本番では正しいが CI イメージビルドが重い。
- マルチステージ化されておらず、build ツールキャッシュをそのまま runtime に残している。

### [重要度: 中] docker-compose のシークレット運用

- `docker-compose.yml:9` でデフォルト `POSTGRES_PASSWORD=changeme_dev_only` がコミットされており、`.env` 未作成のまま `docker compose up` するとこの弱パスワードで起動する。`.env.example` には注意書きがあるが、compose 側に required marker（`${POSTGRES_PASSWORD:?...}` 構文）を使うほうが安全。

### [重要度: 中] embedding CLAUDE.md の Windows 専用コマンドが残っている

- `/home/user/easy_chatbot_maker/embedding/CLAUDE.md:8` の `. .venv/Scripts/activate` は Windows / Git Bash 専用。Linux/macOS では `. .venv/bin/activate`。Claude Code が Web (Linux) で動く前提を考えるとパス指定が誤誘導になりうる。

### [重要度: 低] `.gitignore` に `coverage.xml` / `*.trx` / `.dotnet/` などが無い

- 現状 `TestResults/` は入っているが、`coverage.xml`, `*.cobertura.xml`, `.dotnet/`（ローカル SDK install）が未指定。

### [重要度: 低] `.vscode/launch.json` がリポジトリに無く `gitignore` 側で除外

- `.vscode/launch.json` を `.gitignore:57` で除外しているが、推奨デバッグ構成（Blazor 起動 / uvicorn デバッグ）をチームで共有する手段がない。`launch.json.example` の同梱を検討。

### [重要度: 低] `.vscode/portfolio.code-snippets` の品質未確認

- 中身は読まなかったが、`extensions.json` に紐づくスニペットの整合性をレビューしておく価値はある。

### [重要度: 低] README に Make ターゲット一覧が無い

- `make help` が機能するのでドキュメント側からの誘導があると良い。

---

## 改善提案

優先順に列挙。コマンド例は当該ディレクトリ (`/home/user/easy_chatbot_maker`) を cwd と仮定。

### P0 — Claude Code on the Web 対応の最小セット

1. **ルート `CLAUDE.md` を新規作成**。内容のテンプレ:

   ```markdown
   # easy_chatbot_maker

   マルチテナント RAG チャットボット SaaS。詳細は design/README.md。

   ## サブプロジェクト
   - `backend/`  Blazor Server + ASP.NET Core 8 — backend/CLAUDE.md を読む
   - `embedding/` FastAPI + sentence-transformers — embedding/CLAUDE.md を読む
   - `infra/`    Postgres init.sql / Caddyfile

   ## 横断ルール
   - テナント境界は tenant_id + RLS（design/04_security_multitenant.md）
   - LLM キーは BYOK（サーバ保持しない）
   - 設計ドキュメントが正、コードと食い違ったら design/ を確認

   ## 主要コマンド
   - make lint test  全体 lint+test
   - make up         docker compose 起動
   - make scan       プロンプトインジェクション検査
   ```

2. **`.claude/settings.json` を作成**して頻出コマンドを `permissions.allow` 化。`/fewer-permission-prompts` スキルで自動生成できる。最低限:

   ```json
   {
     "permissions": {
       "allow": [
         "Bash(make *)", "Bash(dotnet *)", "Bash(pytest *)",
         "Bash(ruff *)", "Bash(mypy *)", "Bash(docker compose *)",
         "Bash(pre-commit *)", "Bash(git status)", "Bash(git diff *)", "Bash(git log *)"
       ]
     }
   }
   ```

3. **`.claude/hooks/` に SessionStart フックを追加**（Claude Code on the Web で初回セッション時に依存セットアップを完了させる）。`/session-start-hook` スキルで生成可能。スクリプト例:

   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   (cd backend && dotnet restore Portfolio.sln) &
   (cd embedding && pip install -e ".[dev]") &
   wait
   pre-commit install || true
   ```

4. **`.claude/scripts/pr-validate.py` をリポジトリに vendorings**。`.pre-commit-config.yaml:38-43`, `Makefile:93-98`, `ci.yml:108-115` がいずれも参照済みだが本体が無い。コミットして初めてプロンプトインジェクション検査が常時走るようになる。

5. **`.claude/agents/` にプロジェクト固有エージェントを 2 つ追加**:
   - `security-engineer.md`: CONTRIBUTING.md:69 が要求するレビュー観点（RLS / BYOK / SQL パラメータ化 / LLM 入力サニタイズ）を担う。
   - `blazor-reviewer.md`: backend/CLAUDE.md の禁止事項（Newtonsoft, AutoMapper, Task.Run 擬似 async, 非 typed HttpClient）に絞ったレビュアー。

6. **`.claude/commands/` にスラッシュコマンドを 2-3 個**:
   - `/qa`: `make lint test` 連続実行。
   - `/up`: `make up && make logs`。
   - `/migrate`: `dotnet ef migrations add` テンプレ。

### P1 — CI / pre-commit の穴埋め

7. **CI に `mypy` を追加**。`.github/workflows/ci.yml` の embedding ジョブに以下を追記:

   ```yaml
   - name: Type check (mypy)
     run: mypy app
   ```

8. **pre-commit に `check-toml` と `mypy`（ローカル）を追加**:

   ```yaml
   - id: check-toml
   - repo: https://github.com/pre-commit/mirrors-mypy
     rev: v1.11.0
     hooks:
       - id: mypy
         files: ^embedding/app/
   ```

9. **docker-compose の `POSTGRES_PASSWORD` を required にする**:

   ```yaml
   POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set in .env}
   ```

   `.env.example` のコピー忘れを早期検出できる。

10. **embedding CLAUDE.md の venv コマンドを OS 別に明示**:
    ```bash
    . .venv/bin/activate           # Linux / macOS / Web
    . .venv/Scripts/activate       # Windows / Git Bash
    ```

### P2 — テスト・カバレッジ・最適化

11. **backend テストを増やす**。`Program.cs` の DI 構成、`Services/` 配下のクラス、`/embed` への HTTP クライアントの統合テストを `WebApplicationFactory` 経由で追加。

12. **CI でカバレッジ収集**:
    ```yaml
    - run: dotnet test ... --collect:"XPlat Code Coverage"
    - uses: codecov/codecov-action@v4
    ```
    embedding 側も `pytest --cov=app --cov-report=xml`。

13. **embedding CI のテスト時依存を軽量化**: `pyproject.toml` の `[project.optional-dependencies]` に `test` extras を切り、`sentence-transformers` / `torch` を含めない。`FAKE_EMBEDDER=1` モードに必要なのは `fastapi`/`pydantic`/`numpy`/`httpx`/`pytest` のみ。

14. **embedding Dockerfile のマルチステージ化**: builder ステージで `pip install`、runtime ステージは `--from=builder` で site-packages のみコピー、apt の curl/ca-certificates も runtime 限定に。

### P3 — 仕上げ

15. **`.vscode/launch.json.example`** を追加。Blazor デバッグ + uvicorn デバッグ + compose 起動済み embedding へのアタッチ構成。
16. **README に `make help` の抜粋表**を追加。
17. **`.gitignore` に `coverage.xml`, `*.cobertura.xml`, `.dotnet/` を追加**。
18. **CodeQL の `query-suites` を `security-extended` に昇格**（現在は default）:
    ```yaml
    - uses: github/codeql-action/init@v3
      with:
        languages: ${{ matrix.language }}
        queries: security-extended
    ```

---

## スコア（10 点満点）

| サブカテゴリ | スコア | コメント |
|---|---|---|
| ルート CLAUDE.md | **0 / 10** | 不在。Web セッションでの横断知識が共有できない。 |
| サブプロジェクト CLAUDE.md (backend, embedding) | **9 / 10** | 内容は具体的・実用的。venv パス記述だけ要修正。 |
| .claude/ 配下（settings/agents/commands/hooks） | **0 / 10** | ディレクトリごと不在。pr-validate.py 参照だけが残り skip 状態。 |
| Claude Code on the Web 動作準備（SessionStart 等） | **0 / 10** | 何も用意されていない。 |
| README / CONTRIBUTING / LICENSE | **9 / 10** | 揃っており質が高い。Make ターゲット表があれば 10。 |
| .editorconfig / .gitignore / .env.example | **8 / 10** | 二段階 editorconfig + .env.example の Plan A/B 注釈が良い。coverage.xml 等の追加余地。 |
| Makefile | **9 / 10** | help 自動生成、.SHELLFLAGS, スコープ分離が綺麗。 |
| docker-compose.yml | **8 / 10** | healthcheck + profiles 構成は良い。POSTGRES_PASSWORD の required 化が欲しい。 |
| Dockerfile (backend, embedding) | **8 / 10** | 非 root + HEALTHCHECK は◎。embedding はマルチステージで更に最適化可能。 |
| .pre-commit-config.yaml | **7 / 10** | gitleaks/ruff/dotnet-format/trailing 等は揃う。mypy・check-toml 欠落、pr-validate.py が常時 skip。 |
| CI (ci.yml) | **8 / 10** | concurrency / cache / 4 ジョブ構成は優秀。mypy 不在 / カバレッジ未取得が痛い。 |
| CodeQL | **8 / 10** | C#/Python マトリクス + weekly schedule。security-extended で更に強化可能。 |
| Dependabot | **10 / 10** | nuget/pip/docker/actions + groups まで設計済み。 |
| CODEOWNERS / PR / Issue テンプレ | **9 / 10** | 揃っており、PR テンプレに Security checklist まである。 |
| .vscode 設定 | **8 / 10** | extensions / tasks / snippets。launch.json.example が欲しい。 |
| テスト容易性 | **6 / 10** | embedding は健全、backend は 1 テストのみ。Makefile から両方一発実行は可能。 |

**総合（単純平均）**: 約 6.6 / 10
**主観的総合**: **6.5 / 10** — dev lifecycle 単体は 8 点台だが、Claude Code 統合（.claude/ 一式 + ルート CLAUDE.md）が完全に空欄なので、本レビュー観点の合計では中位に着地。P0 を 1 日で潰せば 8 点台に引き上げ可能。
