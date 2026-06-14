# CONTRIBUTING

## ブランチ戦略
- `main`: 常にデプロイ可能。直接 push 不可、PR のみ。
- `feature/<short-slug>`: 機能追加。例: `feature/rls-policies`
- `fix/<short-slug>`: バグ修正。
- `chore/<short-slug>`: 依存更新・設定変更など。

PR は 1 つの目的に絞る（Kitchen Sink PR 禁止）。

## コミットメッセージ
[Conventional Commits](https://www.conventionalcommits.org/ja/v1.0.0/) に準拠。

```
<type>(<scope>): <subject>

<body — optional, why / context>
```

`type`:

| type | 用途 |
|---|---|
| feat | 機能追加 |
| fix | バグ修正 |
| refactor | 挙動を変えない構造変更 |
| test | テストのみの変更 |
| docs | ドキュメントのみ |
| chore | ビルド・依存更新・設定 |
| ci | CI 設定 |
| perf | パフォーマンス改善 |
| security | セキュリティ修正 |

例:
```
feat(embedding): add /embed/batch endpoint with input validation
fix(api): handle null tenant_id from JWT claim
chore(deps): bump fastapi 0.115.0 → 0.115.2
```

## 開発フロー

1. `make install-tooling` で pre-commit と npm 依存をセットアップ
2. ブランチ作成 → 実装 → `make lint test`
3. `make scan` でプロンプトインジェクション検査（任意）
4. push → PR
5. CI 通過後にレビュー

## コード品質ゲート

| 層 | チェック | コマンド |
|---|---|---|
| embedding | ruff check + format | `make lint.embedding` |
| embedding | mypy --strict | `make lint.embedding` |
| embedding | pytest | `make test.embedding` |
| ts | eslint (type-aware) + prettier check | `make lint.ts` |
| ts | tsc 型チェック | `make typecheck.ts` |
| sql | sqlfluff lint | `make lint.sql` |
| 全体 | commitlint (Conventional Commits) | commit-msg フック |
| 全体 | docker build | `make up` |
| 全体 | gitleaks | `make secrets` |
| 全体 | CodeQL (python) | CI |

すべて pre-commit + GitHub Actions で自動実行される。

## レビュー基準
- スタック別の書き方・定義順・コメント方針は [`docs/conventions/`](docs/conventions/README.md) を基準にする（各章末のチェックリストをレビュー観点に使う）
- 設計意図がコミットメッセージ or PR 本文から読み取れること
- マルチテナント境界（`tenant_id` / RLS）を越える変更がある場合は本文に明記
- 公開 API の入出力スキーマ変更は PR タイトルに `BREAKING:` を付ける
- セキュリティに関わる変更（認証・認可・SQL・外部呼出し）は **必ず** Security Engineer agent でセルフレビューしてから出す

## ローカル環境
詳細は [README.md](README.md)。
