# 品質管理ツール

各規約を**機械的に強制する**ツールの一覧と使い方。「人が守るルール」と「ツールが守るルール」の境界は [README.md](README.md) の対応表を参照。

## 全体像

| スタック | 整形 | 静的解析 / 型 | テスト | 設定ファイル |
|---|---|---|---|---|
| TypeScript / React | Prettier | ESLint(type-aware, react / hooks / jsx-a11y / vitest / playwright) + tsc | Vitest / Playwright | `.prettierrc.json` / `eslint.config.mjs` / `tsconfig*.json` / `package.json` |
| Python | ruff format | ruff check + mypy --strict | pytest | [`embedding/pyproject.toml`](../../embedding/pyproject.toml) |
| SQL | sqlfluff fix | sqlfluff lint | Vitest + Testcontainers | [`.sqlfluff`](../../.sqlfluff) |
| 全ファイル | EditorConfig | pre-commit（whitespace / secrets / 大ファイル） | — | [`.editorconfig`](../../.editorconfig) / [`.pre-commit-config.yaml`](../../.pre-commit-config.yaml) |

横断: **gitleaks**（秘密混入）/ **CodeQL**（Python の SAST、CI）/ **プロンプトインジェクション検査**（`make scan`）/ **commitlint**（Conventional Commits、commit-msg フック）。

## TypeScript ツール（今回追加）

ルートに「ツールの母艦」として最小の `package.json`（workspaces 雛形ではない）と共有設定を置いた。`apps/*` / `workers/*` / `packages/*` がこれを継承する。

| ファイル | 役割 |
|---|---|
| [`package.json`](../../package.json) | devDependencies（eslint/prettier/typescript 一式）と `lint`/`format`/`typecheck` スクリプト |
| [`tsconfig.base.json`](../../tsconfig.base.json) | 厳格な共有コンパイラ設定。各パッケージが `extends` する |
| [`tsconfig.json`](../../tsconfig.json) | solution 設定。各パッケージを `references` に足すと `tsc -b` が全体を型検査 |
| [`eslint.config.mjs`](../../eslint.config.mjs) | flat config。型情報を使う TS ルール + React/hooks。Prettier と競合する整形ルールは無効化 |
| [`.prettierrc.json`](../../.prettierrc.json) / [`.prettierignore`](../../.prettierignore) | 整形（2スペース・ダブルクォート・`printWidth 100`） |
| [`scripts/typecheck.mjs`](../../scripts/typecheck.mjs) | `references` が空（=app 未作成）なら no-op、あれば `tsc -b` |

### セットアップ

```bash
npm install          # ルートで TS ツールを入れる（make install-tooling にも含まれる）
```

### ローカルで走らせる

```bash
npm run lint         # eslint .
npm run lint:fix     # eslint . --fix
npm run format       # prettier --write（TS/JS/CSS のみ）
npm run format:check # prettier --check（CI と同じ）
npm run typecheck    # tsc -b（パッケージ未登録なら no-op）

# Makefile 経由（他スタックと揃える）
make lint.ts format.ts typecheck.ts
```

### app を作ったときに有効化される配線

設定は**今すぐ効く**が、対象コードはまだ無い。`apps/api` 等を作るとき:

1. パッケージに `tsconfig.json` を置き `{ "extends": "../../tsconfig.base.json" }`。React は `lib`/`jsx`/`moduleResolution` を上書き（[react.md](react.md)）。
2. ルート [`tsconfig.json`](../../tsconfig.json) の `references` に `{ "path": "apps/api" }` を追加 → `npm run typecheck` と CI が自動で型検査。
3. ESLint の type-aware ルールは `apps/**`・`workers/**`・`packages/**` に自動適用（`projectService` がパッケージの tsconfig を発見）。
4. pre-commit / CI の TS ジョブも自動で対象に入る（パスで絞っているだけ）。

## EditorConfig

[`.editorconfig`](../../.editorconfig) が全エディタ共通の最低限（文字コード・改行 LF・末尾空白・インデント幅）を強制。TS/JS/CSS は 2スペース、Python 等の既定は 4スペース、YAML/JSON は 2スペース。Prettier・ruff はこれと矛盾しない（Prettier は `tabWidth: 2` を明示して TS を 2スペースに固定）。

## pre-commit

[`.pre-commit-config.yaml`](../../.pre-commit-config.yaml) がコミット時に自動実行。導入:

```bash
pre-commit install -t pre-commit -t commit-msg   # make install-tooling に含まれる
pre-commit run -a    # 全ファイルに手動実行（commit-msg フックは対象外）
```

フック: 汎用（trailing-whitespace / end-of-file / check-yaml/json/toml / merge-conflict / 大ファイル / private-key / mixed-line-ending）+ **ruff**（embedding）+ **gitleaks** + **sqlfluff**（`infra/db` の SQL）+ **prompt-injection-scan** + **prettier / eslint**（TS、`apps`/`workers`/`packages` 配下を対象）+ **commitlint**（commit-msg ステージ）。

## VS Code

[`.vscode/extensions.json`](../../.vscode/extensions.json) が推奨拡張を提示（ESLint / Prettier / ruff / mypy / Vitest / Playwright / EditorConfig など）。`settings.json` は個人設定として gitignore されているので、保存時整形などの推奨設定は [`.vscode/settings.json.example`](../../.vscode/settings.json.example) をコピーして使う:

```bash
cp .vscode/settings.json.example .vscode/settings.json
```

## CI（GitHub Actions）

[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) のジョブ:

- **node (TS)**: `npm ci` → `format:check` → `lint` → `typecheck`（app が無い間も緑。コードが入ると自動でゲート化）。
- **embedding (Python)**: ruff check / ruff format --check / mypy / pytest。
- **pr-security**: プロンプトインジェクション検査（PR 時）。
- docker-build は `if: false` で無効化（Sprint 2 で `apps/api`・`apps/web` の新イメージビルドへ置換予定）。

CodeQL は [`.github/workflows/codeql.yml`](../../.github/workflows/codeql.yml)（weekly + push/PR）。

## 困ったとき

- **整形で差分が出る** → `make format.ts` / `make format.embedding` を実行（手で直さない）。
- **ESLint が型情報を見つけられない** → そのパッケージに `tsconfig.json`（base を継承）があるか確認。
- **`npm run typecheck` が "no TS packages" と出る** → 正常（app 未作成）。`tsconfig.json` の `references` に追加すると動く。
- **pre-commit が遅い / 失敗する** → `pre-commit run <hook-id> -a` で個別に切り分け。
