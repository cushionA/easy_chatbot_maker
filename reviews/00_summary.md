# チームレビュー統合サマリ

レビュー対象: `easy_chatbot_maker`（実体は社内ポートフォリオ／コンテンツ管理プラットフォーム。Blazor Server + .NET 8 / Python FastAPI Embedding / PostgreSQL + pgvector / Caddy）

レビュー実施日: 2026-05-15
ブランチ: `claude/team-code-review-Ff2NS`

## 各レビューの結論と総合スコア

| # | 観点 | 担当ファイル | スコア | 一言サマリ |
|---|------|--------------|--------|------------|
| 01 | 開発環境品質（Claude Code活用 / dev lifecycle） | [01_dev_environment_review.md](./01_dev_environment_review.md) | 6.5/10 | CI/Make/Docker/テンプレ類は成熟。一方ルート `CLAUDE.md` と `.claude/` 一式が未整備、CI に mypy 欠落、backend テストが healthz 1 本のみ。 |
| 02 | 設計・アーキテクチャ | [02_design_review.md](./02_design_review.md) | 8.0/10 | 設計書12章は高水準で実装雛形も忠実。ただし RLS／認証／Vault が実装未着手。`multilingual-e5` query/passage プレフィクス規約違反、Caddy が `/api/embed*` を認可バイパスする点が要修正。 |
| 03 | 機能（網羅性 / 改善余地 / 不要機能） | [03_feature_review.md](./03_feature_review.md) | - | 設計は MVP 約70項目＋Phase2/3 まで詳細。実装は Sprint 0（DB スキーマ・EF Core エンティティ10種・FastAPI 埋め込み・Docker・Health）完了段階。認証／分類／動的フォーム／起票 Adapter／RLS いずれも未着工。 |
| 04 | 現状成果物（動くもの／ハリボテ判定） | [04_current_deliverable_review.md](./04_current_deliverable_review.md) | 3/10 | スキャフォールド層は優秀。業務ロジック・画面・認証は事実上未実装。Pgvector NuGet 不足、Docker 環境での `UseHttpsRedirection` 誤動作、Caddyfile の `handle_path` でパス剥がれ、`JsonDocument` の IDisposable リーク等を file:line 付きで指摘。 |

## 横断的な重要指摘トップ5（複数レビューで共通）

1. **`multilingual-e5` のプレフィクス未対応**（02, 03 で重複指摘） — `embedding/app/embedder.py` が query/passage を区別せず固定で `query:` を付与しているため、検索品質が大幅劣化する可能性。**最優先で修正**。
2. **Caddy のリバースプロキシ設定で `/api/embed*` が認可をバイパス**（02, 04） — multi-tenant 設計の根幹を崩すリスク。
3. **認証・RLS（行レベルセキュリティ）が実装未着工**（02, 03, 04） — 設計書 `design/04_security_multitenant.md` の中心要件が雛形段階。
4. **Pgvector の NuGet パッケージ未追加で `UseVector()` が未解決**（04） — backend がそもそもビルドできない状態の可能性。
5. **Claude Code 用設定が欠落**（01） — ルート `CLAUDE.md`／`.claude/settings.json`／SessionStart hook がないため、Claude Code on the Web で快適に作業する準備が未了。

## 推奨アクション（短期 1〜2 スプリント）

優先度順:

1. **ビルド通過の確保** — Pgvector NuGet 追加、`UseHttpsRedirection` を Production のみに限定、`JsonDocument` の dispose 修正。（04 参照）
2. **embedder.py 修正** — query/passage を引数で受け取る or 2 エンドポイントに分割。（02, 03 参照）
3. **Caddyfile 修正** — `/api/embed*` を内部ネットワーク限定 or backend 経由に変更。（02, 04 参照）
4. **Claude Code 環境整備** — ルート `CLAUDE.md`、`.claude/settings.json`、テスト＆Lint用 SessionStart hook を追加。（01 参照）
5. **CI 強化** — `mypy` 追加、backend テスト拡充、`dotnet test` のカバレッジ閾値設定。（01 参照）
6. **認証 + RLS の着手** — 設計済の OIDC + Postgres RLS を MVP のクリティカルパスに。（02, 03 参照）

## 中期方針

- 機能ロードマップ（03）の P0（認証・RLS・分類本体・動的フォーム・Adapter）→ P1（管理画面・未分類キュー・ウィジェット）→ P2（分析・Vault）に沿って進行。
- 各サブシステムの CLAUDE.md は存在するが（backend/, embedding/）、ルート横断の開発手順は未整備のため、ルート `CLAUDE.md` の整備が早期効果大。

## 各レビューの詳細

- 開発環境品質: [01_dev_environment_review.md](./01_dev_environment_review.md)
- 設計・アーキテクチャ: [02_design_review.md](./02_design_review.md)
- 機能: [03_feature_review.md](./03_feature_review.md)
- 現状成果物: [04_current_deliverable_review.md](./04_current_deliverable_review.md)
