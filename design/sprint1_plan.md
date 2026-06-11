# Sprint 1 実装計画（TrendScope スパイク・3 日分）

> 想定読者: 駆け出し Web エンジニアの自分。AI（先輩）にレビューや一次実装を頼みながら進める。
> 期間: 2026-06-12 〜 2026-06-14（3 日）
> ゴール: **スパイクの問い「Web の言及データから、意味あるトレンド信号（新出・急上昇）が本当に立つか」に Yes/No で答える**。
> 副産物: 実データで検証済みのスキーマ・抽出ノイズ率・検知パラメータの実測値 → design/03・05・06・11 へ反映。
> Done の定義は各日末尾のチェックリスト。

## スパイクの位置づけ（重要）

- `spike/`（Node22 + tsx、依存最小、**DB/Docker なし**）は **throwaway**。本実装に持ち込むのは「学び」だけ。
- テスト・型の厳密さは免除。代わりに **`spike/findings.md` への記録が義務**（記録なきスパイクはただの遊び）。
- **Day 3 の最後に必ず TDD モードへ戻る宣言をする**（antipattern #5: Forgotten Spike Mode 防止）。
- 設計（design/）はスパイク中に直接書き換えない。findings に反映案 → 確認 → 反映の順。

## 全体マップ

| 日 | テーマ | 詳細指示書 | 主成果物 |
|---|---|---|---|
| Day 1 | 実データを手元に置く | [`sprint1/day1.md`](sprint1/day1.md) | `out/hn-raw.jsonl`（時間窓スライドで30日）/ `out/qiita-raw.jsonl` / normalizer（UTC 正規化）/ `out/verify.md` |
| Day 2 | 抽出・正規化・集計 | [`sprint1/day2.md`](sprint1/day2.md) | `dict/`（seed 辞書 150+ 語・aliases・excluded・ambiguous）/ 2 層抽出器 / `out/stats.json` / ノイズ率の実測 |
| Day 3 | 検知と評価、設計反映 | [`sprint1/day3.md`](sprint1/day3.md) | `out/detections.json`（新出/急上昇）/ 目視評価とパラメータ感度 / findings 完成 → design 反映 / Sprint 2 ゴール |

骨格ファイルは作成済み: [自分-B] タスクは `spike/types.ts` / `spike/sources/hn.ts` / `spike/extract.ts` / `spike/detect.ts`（シグネチャ + 手順コメント入り）、[自分-A] は `spike/aggregate.ts`（ヒントのみ。答え合わせは [`sprint1/refs/aggregate.ref.ts`](sprint1/refs/aggregate.ref.ts)、**書いてから見る**）。

委譲タグは [`09_task_split.md`](09_task_split.md) を継承: **[自分]**（A=ヒントのみ / B=骨格あり）・**[AI]**（依頼テンプレ付き）。層ラベル（`[FE]`/`[BE]`/`[INFRA]`/`[TEST]`/`[ML]`/`[設計]`）を併記。

## Sprint 全体ロードマップ（切り出し）

Sprint 2 以降は**スパイクの所見で再計画する前提**の仮置き。日割り詳細は各 Sprint 着手時に `sprint-plan` で生成する。

| Sprint | テーマ | 主な内容 | 中心の設計書 |
|---|---|---|---|
| **1（本書）** | スパイク: 信号は立つか | HN+Qiita(+Trending) → 抽出 → 集計 → 検知 → 評価 → 設計反映 | 14 / 05 |
| 2 | 土台: monorepo + DB/RLS + CI | `apps/api`・`workers` scaffold、migrations（schema / 2 ロール / RLS+FORCE）、RLS 越境テスト（Testcontainers）、CI の Node 化、docker compose | 03 / 04 / 13 |
| 3 | 収集パイプライン本実装 | `FetchContext`（SSRF 検証・robots・レート・条件付き GET）、言及系 SourceAdapter 5 本（HN/Qiita/dev.to/SO/Lobsters）、BullMQ ワーカー、dedup、F8 収集ヘルス、`occurrences`→BigQuery | 06 / 14 |
| 4 | 抽出・検知・metrics | F9 辞書 + 正規化 + `term_identities`、ES `documents` + Embedding（FastAPI）、`daily_term_stats` スケジュールクエリ、F2 検知バッチ + golden 回帰（D1〜D9）、`term_metrics` + MetricsSourceAdapter（npm/PyPI/crates/GH Archive） | 05 / 03 / 13 |
| 5 | API + フロント | OIDC + テナント解決 + `SET LOCAL`、F1 可視化、F6 ドリルダウン、F9 管理 UI、ウォッチリスト（RLS）、Playwright E2E | 04 / 08 / 13 |
| 6 | 要約 + 運用 + デプロイ | F3 要約（RAG + injection 対策 + レート上限）、F8 ダッシュボード、GitHub Trending クロール本実装、K8s デプロイ、デモ準備（11 Q16） | 05 / 02 / 11 |
| fast-follow | F5 JP/Global・F7 配信・ムーブメント検知 | JP 源泉拡充（ja.SO / Zenn）を含む | 08 / 14 |

## 進めるときの 1 サイクル

各タスクで [`09_task_split.md`](09_task_split.md) のワークフローに従う:

1. 該当する `design/` ファイルを読む（仕様の正。源泉まわりは **14 が正**）
2. 仕様を 5〜10 行の箇条書きにする（この明文化が一番大事）
3. [自分] タスク: 骨格/ヒントから自分で書く（**完成コードを AI に求めない**）
4. [AI] タスク: 依頼テンプレを投げて一次実装させる
5. 出来たものをレビュー・動作確認、必要なら再依頼
6. findings.md にメモ（スパイクではこれがテストの代わり）

## つまづいたらここを見る

| 症状 | 見るべき場所 |
|---|---|
| HN の窓スライドが進まない / 0 件 | [`14_data_sources.md`](14_data_sources.md) §1（numericFilters 実例・1000 件天井） |
| Qiita 401 / レート枯渇 | [`14_data_sources.md`](14_data_sources.md) §3（トークン・Rate-Remaining） |
| 日付が 1 日ズレる | UTC 正規化の順序（ISO 化 → `slice(0,10)`。day1.md Day1-4 詰まったら） |
| 抽出の誤爆（java↔javascript, go） | [`05_search_classification.md`](05_search_classification.md) §抽出 2 層・曖昧性解消 |
| 検知が 0 件 / 全部検知 | `detect.ts` の `PARAMS`（spike は N_MIN=2）と baseline 窓のフィルタ |
| Trending のセレクタが壊れた | [`14_data_sources.md`](14_data_sources.md) §6（要再検証前提）。壊れ方自体が F8 の学び |

## Sprint 1 完了後に残るタスク

- **本実装はゼロから書き直す**（spike は import しない）。Sprint 2 で monorepo + DB/RLS + CI の土台から。
- N_MIN の本番較正（源泉 5+ が揃う Sprint 3 以降）。
- 検知 golden データセット（13 の D1〜D9）を spike の stats 断面から切り出す。
- 旧チャットボット時代の `sprint2〜6` ファイルは stale のまま残っている。各 Sprint 着手時に `sprint-plan` で置換する。
