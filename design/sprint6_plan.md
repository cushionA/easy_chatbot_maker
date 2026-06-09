# Sprint 6 実装計画（2 日分）

> 想定読者: 駆け出し Web エンジニアの自分。AI（先輩）にレビューや一次実装を頼みながら進める。
> 期間: 2026-06-12 〜 2026-06-13（2 日、目安）
> テーマ: **マスタ管理の作り込み（MVP のマスタ管理を締める Sprint）**
> ゴール: **admin がマスタ（KnowledgeEntry / FieldDefinition / ValidationRule）を画面から CRUD でき（KnowledgeEntry は `example_queries` / `auto_resolution` / `guidance_message` / `ticket_priority` / `required_field_codes` も編集）、Excel または JSON でナレッジを一括取込（取込時 embedding を `passage:` で計算）できる**状態。
> Done の定義は各日末尾のチェックリスト。

## 主題の設計書

- [`08_features.md`](08_features.md) — マスタ管理のチェックリスト
- [`05_search_classification.md`](05_search_classification.md) — 動的フォーム・`required_field_codes` 結合（**仕様の正**）
- [`10_existing_streamlit.md`](10_existing_streamlit.md) — `data.xlsx` の構造（knowledge/field_types/categories/validations/settings）

## 前提（Sprint 1〜4 の成果物に依存する。作り直さず利用する）

- **Sprint 1**: 認証 + RLS + `tenantMiddleware` + Category CRUD 3 ページ（`apps/web/src/pages/categories/`）。React フォームの手本はここ。
- **Sprint 2**: `ClassifyService` が ④〜⑥ をつなぐ。本 Sprint は取込したマスタが検索に乗ることを確認するために参照するのみ（内部は触らない）。
- **Sprint 4**: 動的フォーム（`required_field_codes` 結合 → `DynamicForm`）。本 Sprint で編集する `field_definitions` / `required_field_codes` がこのフォーム描画の入力になる。

## Sprint 6 の境界（やる / やらない）

- **やる**: KnowledgeEntry のリッチ編集 UX（配列列 + 3 段階エスカレーション列 + 優先度 + `required_field_codes` + embedding 再計算トリガ）、その一覧/作成/削除、FieldDefinition / ValidationRule CRUD、Excel/JSON 一括取込（取込時 embedding を `passage:` で計算）。
- **やらない**: Sprint 2 day1 が扱った「Knowledge / FieldDefinition の**雛形 CRUD テンプレ展開**」の再実装（重複させない。本 Sprint は雛形の上に**リッチ編集 UX を仕上げる**）。⑥ LLM フォールバックの UI 結線（BYOK + Gemini 鍵が前提のため MVP 後送り。末尾「残るタスク」参照）。`ClassifyService` の内部ロジック（Sprint 2）。動的フォーム描画本体（Sprint 4）。閾値のテナント別チューニング（Phase 2）。

## 全体マップ

| 日 | テーマ | 主成果物 |
|---|---|---|
| Day 1 | マスタ CRUD の本命（KnowledgeEntry リッチ編集） | 詳細: [`sprint6/day1.md`](sprint6/day1.md) — `KnowledgeEntry` リッチ編集ページ（`ExampleQueries` 配列 / `AutoResolution` / `GuidanceMessage` / `TicketPriority` / `RequiredFieldCodes` / embedding 再計算トリガ）[自分]、その一覧[AI]・作成[AI]・削除[AI] |
| Day 2 | 残マスタ + 一括取込 | 詳細: [`sprint6/day2.md`](sprint6/day2.md) — FieldDefinition CRUD[AI]、ValidationRule CRUD[AI]、取込スキーマ/突合キー定義[自分]、Excel/JSON 一括取込 UI（取込時 embedding を `passage:` で計算）[AI] |

各 day ファイルは、タスクごとに「**目的 / 自分で書く理由 or AI 依頼テンプレ / 前提確認 / 手順 / 完了確認 / 詰まったら**」の節を持つ作業指示書。明日朝は [`sprint6/day1.md`](sprint6/day1.md) を開いて Day1-1 から着手する。

「自分で書く（説明責任が重い箇所）」と「AI に委譲（仕様だけ握る）」の区分は [`09_task_split.md`](09_task_split.md) を継承する。各タスクに **[自分]** / **[AI]** を明記する。

さらに各タスクに **層ラベル**（`[FE]` フロントエンド / `[BE]` バックエンド / `[INFRA]` インフラ / `[TEST]` テスト / `[ML]` 機械学習 / `[設計]` 上流設計）を付け、フルスタックの守備範囲を可視化する。複数層にまたがるタスクは主たる層を先頭に併記する。

---

## Day 1 — KnowledgeEntry リッチ編集（編集 UX の型）

> Sprint 2 day1 で雛形 CRUD は AI が複製済み。今日は KnowledgeEntry の**リッチ編集 UX を自分の手で仕上げる**日。配列列・3 段階エスカレーション列・優先度・`required_field_codes`・embedding 再計算トリガを 1 ページに同居させる「編集 UX の型」を作り、一覧/作成/削除はその型から AI に複製させる。

- **Day1-1.** KnowledgeEntry リッチ編集ページ（編集 UX の型）[自分（最初の1個）] [FE] [BE]
- **Day1-2.** KnowledgeEntry 一覧ページ（マスタ管理入口）[AI] [FE] [BE]
- **Day1-3.** KnowledgeEntry 作成ページ（編集ページの複製）[AI] [FE] [BE]
- **Day1-4.** KnowledgeEntry 削除（確認付き）[AI] [FE] [BE]

## Day 2 — 残マスタ + 一括取込

> 残るマスタ（FieldDefinition / ValidationRule）の CRUD を Day 1 と Sprint 1 の型から AI に複製させ、Excel/JSON 一括取込を入れる日。取込の**スキーマと突合キーの定義**は検索品質と冪等性に直結するので自分が握り、UI と I/O は AI。

- **Day2-1.** FieldDefinition CRUD（`field_type` / `is_multi` / `choices` / `validation_rule_id`）[AI] [FE] [BE]
- **Day2-2.** ValidationRule CRUD [AI] [FE] [BE]
- **Day2-3.** 取込スキーマ + 突合キー（upsert キー）の定義 [自分（設計判断が中核）] [設計]
- **Day2-4.** Excel/JSON 一括取込 UI（取込時 embedding を `passage:` で計算）[AI] [BE] [ML]

---

## 進めるときの 1 サイクル

各タスクで [`09_task_split.md:107`](09_task_split.md) のワークフローに従う:

1. 該当する `design/` ファイルを読む（仕様の正。Sprint 6 は [`08_features.md`](08_features.md) / [`05_search_classification.md`](05_search_classification.md) / [`10_existing_streamlit.md`](10_existing_streamlit.md)）
2. 仕様を 5〜10 行の箇条書きにする（**この明文化が一番大事**）
3. インターフェース・型・スキーマ雛形を自分で書く（[自分] タスクの中身）
4. AI に「この仕様で実装して」と依頼（[AI] タスク）
5. 出来たコードをレビューし、テストも AI に依頼
6. ローカルで動作確認、必要なら再依頼
7. PR にまとめてマージ（1 タスク 1 PR を基本に）

## つまづいたらここを見る

| 症状 | 見るべき場所 |
|---|---|
| 配列列が React の `useFieldArray` でバインドできない | [`sprint2/day1.md:32`](sprint2/day1.md)（`string[]` は `useFieldArray` + `react-hook-form` で配列管理） |
| 取込した knowledge が検索で 0 件 | embedding が `query:` で計算されている。取込は **`passage:`**（[CLAUDE.md 横断ルール], [`embedding/CLAUDE.md`](../embedding/CLAUDE.md)） |
| 取込で同じ行が重複登録される | 突合キー（Day2-3）が効いていない。`(tenant_id, category_code, name)` で upsert |
| 別テナントのマスタが見える | `SET LOCAL` が効いていない（Sprint 1 Day2-4 の tenant middleware を疑う） |

## Sprint 6 完了後に残るタスク

Day 2 まで終わると、MVP のマスタ管理（[`08_features.md`](08_features.md) の「マスタ管理」ブロック）が締まる。MVP として未着手で残るのは:

- **組織オンボーディング & メンバー管理**（サインアップ/サインイン結線、組織作成・編集、メンバー招待・ロール admin/member、ボット URL 払い出し）。[`08_features.md`](08_features.md) の「認証・組織管理」ブロック。product 判断（招待方式等）が混じるため未分解。
- **BYOK（Gemini API キー）の Secret Manager 保管 + ⑥ LLM フォールバックの UI 結線**（⑤→⑥→⑦）。Sprint 2 が ⑥ ロジック、Sprint 3 が Secret Manager 基盤を持つので、両者を結線する小 Sprint。本 MVP では ⑤→⑦ 直結のまま。

以降は Phase 2 以降（[`08_features.md`](08_features.md)）:

- **閾値のテナント別チューニング**（`app_settings` 化、Sprint 2 残タスク）
- **取込の差分 embedding / Git 同期 / webhook**（[`08_features.md:120-123`](08_features.md)）
- **クロスエンコーダ Re-ranker / HyDE**（検索精度強化）
- **非構造文書（PDF/Word）対応 `document_chunks`**
