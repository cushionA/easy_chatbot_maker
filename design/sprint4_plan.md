# Sprint 4 実装計画（3 日分）

> 想定読者: 駆け出し Web エンジニアの自分。AI（先輩）にレビューや一次実装を頼みながら進める。
> 期間: 2026-06-01 〜 2026-06-03（3 日、目安）
> ゴール: **利用者が `/t/{slug}/chat` で「カテゴリ選択 → コンボボックス → 自然言語入力」で問題を特定し、3段階エスカレーション（auto_resolution / guidance_message / 直接起票）に応じた挙動が出る。動的フォーム入力 → 確認画面 → 起票連携、該当なしは未分類キュー登録、admin がレビューできる。**
> Done の定義は各日末尾のチェックリスト。

## 主題の設計書

- [`05_search_classification.md`](05_search_classification.md) — フロー①〜③、3段階エスカレーション、動的フォーム、引用元ハイライト、未分類キュー（**仕様の正**）
- [`08_features.md`](08_features.md) — 分類フロー / 3段階エスカレーション / 動的フォーム / 引用元表示 / 未分類キュー のチェックリスト

## 前提（Sprint 2 / 3 の成果物に依存する）

- **`ClassifyService`**（Sprint 2）: `query` + `categoryId?` → 候補 `KnowledgeEntry` のランク済みリストと `match_strategy` / `confidence_score` を返す。**内部実装（BM25/Embedding/RRF）は作り直さず、UI から呼ぶだけ。**
- **`ITicketDestination` / `SubmitAsync`**（Sprint 3）: 確定フィールド値 → 外部起票（Redmine / GitHub Issues）。**Adapter 内部は触らない。UI から呼んで成功/失敗 UI と `draft_fields` 退避を結線するだけ。**

> ⚠️ 着手前に「`ClassifyService` と起票 Adapter が実在し、想定シグネチャで呼べるか」を Day4-1 の前提確認で必ず実機チェックする（[Day1 引き継ぎメモ](#)参照）。無ければ Sprint 2/3 に戻る。

## 全体マップ

| 日 | テーマ | 主成果物 |
|---|---|---|
| Day 1 | チャット画面の足場と分類結線 | 詳細: [`sprint4/day1.md`](sprint4/day1.md) — `Chat.razor`（画面の型）、カテゴリ選択 UI、コンボボックス、`ClassifyService` 結線 |
| Day 2 | 3段階エスカレーション分岐と動的フォーム | 詳細: [`sprint4/day2.md`](sprint4/day2.md) — 分岐ロジック、`field_definitions` 結合→フォーム描画、`is_multi` 行追加、バリデーション（client+server） |
| Day 3 | 確認画面・起票連携・引用元・未分類キュー・admin レビュー | 詳細: [`sprint4/day3.md`](sprint4/day3.md) — 確認画面、`SubmitAsync` 結線、引用元ハイライト、未分類キュー登録、admin レビュー画面 |

各 day ファイルは、タスクごとに「**目的 / 自分で書く理由 or AI 依頼テンプレ / 前提確認 / 手順 / 完了確認 / 詰まったら**」の節を持つ作業指示書。明日朝は [`sprint4/day1.md`](sprint4/day1.md) を開いて Day4-1 から着手する。

「自分で書く（説明責任が重い箇所）」と「AI に委譲（仕様だけ握る）」の区分は [`09_task_split.md`](09_task_split.md) を継承する。各タスクに **[自分]** / **[AI]** を明記する。

---

## Day 1 — チャット画面の足場と分類結線

> フロー①②③（[`05:5-35`](05_search_classification.md)）の入口を立てる日。チャット画面の「型」を自分の手で作り、カテゴリ選択とコンボボックスを置き、自然言語入力を `ClassifyService` に結線する。

- **Day4-1.** チャット画面の足場 `Chat.razor` を作る [自分（最初の1個=画面の型）]
- **Day4-2.** カテゴリ選択 UI（ボタン式、「わからない」で全件フォールバック）[自分]
- **Day4-3.** コンボボックス（カテゴリ内問題名の入力フィルタ可能ドロップダウン）[自分（最初の1個）]
- **Day4-4.** 自然言語入力 → `ClassifyService` 結線 [AI]

## Day 2 — 3段階エスカレーション分岐と動的フォーム

> 確定後の挙動を決める日。3段階エスカレーション分岐（[`05:113-128`](05_search_classification.md)）が中核なので自分で書く。動的フォームの描画と `is_multi`、バリデーションは AI に複製させる。

- **Day4-5.** 3段階エスカレーション分岐ロジック [自分（分岐ロジックが中核）]
- **Day4-6.** 動的フォーム生成（`required_field_codes` 結合 → UI 描画）[AI]
- **Day4-7.** `is_multi` 行追加 UI [AI]
- **Day4-8.** バリデーション（既存 `forms.py` の `validate_field` 移植、client + server）[AI]

## Day 3 — 確認画面・起票・引用元・未分類キュー・admin レビュー

> フローの出口を全部つなぐ日。確認画面の型を自分で作り、起票連携・引用元・admin レビューは AI。未分類キュー登録（運用フローの起点）は自分で書く。

- **Day4-9.** 確認画面 `ConfirmStep` [自分（最初の1個）]
- **Day4-10.** 起票連携（`SubmitAsync` 呼び出し、成功/失敗 UI、`draft_fields`）[AI]
- **Day4-11.** 引用元ハイライト（matched `KnowledgeEntry` 表示 + admin リンク）[AI]
- **Day4-12.** 未分類キュー登録（「新規問題として」自由入力 → `unclassified_queue`）[自分]
- **Day4-13.** admin レビュー画面（マスタ追加 or 破棄 + コメント）[AI]

---

## 進めるときの 1 サイクル

各タスクで [`09_task_split.md:107`](09_task_split.md) のワークフローに従う:

1. 該当する `design/` ファイルを読む（仕様の正）
2. 仕様を 5〜10 行の箇条書きにする（**この明文化が一番大事**）
3. インターフェース・型・分岐ロジックの骨子を自分で書く（[自分] タスクの中身）
4. AI に「この仕様で実装して」と依頼（[AI] タスク）
5. 出来たコードをレビューし、テストも AI に依頼
6. ローカルで動作確認、必要なら再依頼
7. PR にまとめてマージ（1 タスク 1 PR を基本に）

## つまづいたらここを見る

| 症状 | 見るべき場所 |
|---|---|
| `ClassifyService` のシグネチャが分からない | Sprint 2 の実装（`backend/Portfolio.Web/Services/`）。無ければ Sprint 2 に戻る |
| 起票 `SubmitAsync` の引数が分からない | Sprint 3 の `ITicketDestination` 実装。無ければ Sprint 3 に戻る |
| `field_definitions` の型の意味 | [`08_features.md:39`](08_features.md)（型一覧）と `Data/Entities/FieldDefinition.cs` |
| 3段階の分岐条件 | [`05_search_classification.md:113-128`](05_search_classification.md)（auto_resolution / guidance_message の真偽値表） |
| バリデーション仕様 | 既存 Streamlit `forms.py` の `validate_field`（[`10_existing_streamlit.md`](10_existing_streamlit.md)）と `Data/Entities/ValidationRule.cs` |
| tenant_id をどこから取るか | クライアント由来は信頼しない。`HttpContext.Items["TenantId"]`（middleware が入れる）から取る |

## Sprint 4 完走後に残るタスク

- LLM フォールバック（⑥、BYOK 時のみ）の UI 結線 — フローでは ⑤ と ⑦ の間。Vault と Gemini 結線が別 Sprint なので本 Sprint では ⑤ → ⑦ の直結で良い。
- 埋め込みウィジェット（`embed.js`、Shadow DOM、匿名 RLS）— 別 Sprint。
- ナレッジギャップ検出ダッシュボード（`inquiries.confidence_score` 集計）— 別 Sprint。
- 暗黙シグナルの集計・可視化 — `inquiries` 各列には本 Sprint で値が乗るので、可視化のみ残る。
