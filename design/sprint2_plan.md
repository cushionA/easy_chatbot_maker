# Sprint 2 実装計画（3 日分）

> 想定読者: 駆け出し Web エンジニアの自分。AI（先輩）にレビューや一次実装を頼みながら進める。
> 期間: 2026-05-22 〜 2026-05-26（3 日、連番でなくて良い／目安）
> ゴール: **`query`（自然文）+ `tenantId` + `categoryId?` を入力に、分類候補リストを返すサービス層 `ClassifyService` が動く**状態。
> 主題の設計書: [`05_search_classification.md`](05_search_classification.md)。分類フロー④〜⑥（キーワード完全一致 / BM25+Embedding ハイブリッド RRF + match_count / LLM フォールバック）と閾値判定が範囲。
> Done の定義は各日末尾のチェックリスト。

## Sprint 2 の境界（やる / やらない）

- **やる**: 分類のサービス層ロジック（④⑤⑥ と閾値判定）、検索 SQL、RRF + match_count 重み付け式、Gemini 構造化出力フォールバック、ユニットテスト。
- **やらない**: チャット UI / コンボボックス（Sprint 4）、起票・動的フォーム生成（Sprint 3）、未分類キュー画面、暗黙シグナル集計。`ClassifyService` は **候補リストを返すところまで**で止める。
- **前提**: Sprint 1（認証 + RLS + Category CRUD + `DbConnectionInterceptor`）は完了済み。`AppDbContext` 経由のクエリは `SET LOCAL app.tenant_id` で自動的にテナント分離される。

## 全体マップ

| 日 | テーマ | 主成果物 |
|---|---|---|
| Day 1 | 検索基盤の足場 | 詳細: [`sprint2/day1.md`](sprint2/day1.md) — 残 CRUD テンプレ展開[AI]、`search_text` 動作確認、`Portfolio.Search` 新規ライブラリ、`ExactMatch` の最初の 1 個[自分]、Embedding の `query:`/`passage:` プレフィクス整理[自分] |
| Day 2 | ハイブリッド検索 | 詳細: [`sprint2/day2.md`](sprint2/day2.md) — BM25 検索 SQL[AI]、Embedding(pgvector) 検索 SQL[AI]、RRF 結合の実装[自分]、match_count 重み付け式[自分] |
| Day 3 | 閾値判定 + LLM + 統合 | 詳細: [`sprint2/day3.md`](sprint2/day3.md) — 閾値判定[自分]、LLM フォールバック移植[AI 一次→自分レビュー]、`ClassifyService` 統合[自分]、ユニットテスト[AI] |

各 day ファイルは、タスクごとに「**目的 / 前提確認 / 手順 / 完了確認 / 詰まったら / AI 依頼テンプレ**」の節を持つ作業指示書。明日朝は [`sprint2/day1.md`](sprint2/day1.md) を開いて Day1-1 から着手する。

「自分で書く（説明責任が重い箇所）」と「AI に委譲（仕様だけ握る）」の区分は [`09_task_split.md`](09_task_split.md) を継承する。各タスクに **[自分]** / **[AI]** を明記する。

---

## Day 1 — 検索基盤の足場

> 「検索の前提を全部そろえる」日。Sprint 1 の残 CRUD を AI に複製させてリハビリしつつ、検索の入口になる `ExactMatch` の最初の 1 個と、検索品質の根幹である `query:`/`passage:` プレフィクスを自分の手で固める。

- Day1-1. 残 CRUD（Knowledge / FieldDefinition）テンプレ展開 [AI]
- Day1-2. `search_text`（tsvector）と検索用インデックスの動作確認 [自分]
- Day1-3. `Portfolio.Search` クラスライブラリと `ClassifyResult` / `ICandidateSearch` の骨子定義 [自分]
- Day1-4. `ExactMatch`（キーワード完全一致）の最初の 1 個 [自分]
- Day1-5. Embedding 呼び出しの `query:`/`passage:` プレフィクス整理 [自分]

## Day 2 — ハイブリッド検索

> 「2 系統の検索を 1 本のランキングに束ねる」日。BM25 と Embedding の SQL は型が決まれば複製なので AI に投げ、**RRF と match_count の式は自分で書く**（面接で「なぜこの式か」を語る中核）。

- Day2-1. BM25 検索（tsvector / ts_rank）SQL [AI]
- Day2-2. Embedding 検索（pgvector コサイン距離）SQL [AI]
- Day2-3. RRF（Reciprocal Rank Fusion）結合の実装 [自分]
- Day2-4. match_count 重み付け式と top-N 整形 [自分]

## Day 3 — 閾値判定 + LLM フォールバック + 統合

> 「分類フローを 1 本につなぐ」日。閾値分岐と `ClassifyService` の組み立ては自分、Gemini 構造化出力の移植は AI 一次実装→自分レビュー、テストは AI。

- Day3-1. 閾値判定（confident / 中間 / low）ロジック [自分]
- Day3-2. LLM フォールバック（既存 `llm_client.py` の Gemini 構造化出力移植）[AI 一次→自分レビュー]
- Day3-3. `ClassifyService` 統合（④〜⑥を 1 メソッドに）[自分]
- Day3-4. `ClassifyService` のユニットテスト [AI]

---

## 進めるときの 1 サイクル

各タスクで [`09_task_split.md:107`](09_task_split.md) のワークフローに従う:

1. 該当する `design/` ファイルを読む（仕様の正。Sprint 2 は [`05_search_classification.md`](05_search_classification.md)）
2. 仕様を 5〜10 行の箇条書きにする（**この明文化が一番大事**）
3. インターフェース・型・SQL 雛形を自分で書く（[自分] タスクの中身）
4. AI に「この仕様で実装して」と依頼（[AI] タスク）
5. 出来たコードをレビューし、テストも AI に依頼
6. ローカルで動作確認、必要なら再依頼
7. PR にまとめてマージ（1 タスク 1 PR を基本に）

## つまづいたらここを見る

| 症状 | 見るべき場所 |
|---|---|
| `search_text` が空 / マッチしない | [`05_search_classification.md:39-57`](05_search_classification.md)（tsvector の作り方）+ `AppDbContext.cs:40-44`（`HasComputedColumnSql`） |
| Embedding 検索で 0 件 | `embedding_model` が `current_model` と一致していない（[`05_search_classification.md:59-70`](05_search_classification.md)） |
| query/passage の使い分け | [`embedding/CLAUDE.md`](../embedding/CLAUDE.md)（プレフィクス規約）+ `EmbeddingClient.cs:17`（`mode` 固定の落とし穴） |
| RRF のスコアが全部同じ | rank（順位）ではなく score を式に入れている。順位 1,2,3... を使う |
| pgvector の `<=>` がビルドエラー | EF Core では生 SQL（`FromSql`）で書く。LINQ に持ち込まない |
| LLM フォールバックが呼ばれない | BYOK 未設定時はスキップが正（[`05_search_classification.md:111`](05_search_classification.md)） |

## Sprint 2 完了後に残るタスク

Day 3 まで終わると `ClassifyService` が候補リストを返せる。残るのは:

- **チャット UI / コンボボックス / 「わからない」フォールバック導線**（Sprint 4、UI）
- **確定後の 3 段階エスカレーション + 動的フォーム + 起票**（Sprint 3、[`06_destinations.md`](06_destinations.md)）
- **未分類キュー → マスタ反映の運用フロー**（[`09_task_split.md:27`](09_task_split.md)、Phase 2）
- **閾値のテナント別チューニング**（`THRESHOLD_CONFIDENT` / `THRESHOLD_LOW` を `app_settings` で持つ。MVP は環境変数で固定）
