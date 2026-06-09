# Sprint 6 Day 2 作業指示書（2026-06-13）

> テーマ: **残マスタ（FieldDefinition / ValidationRule）+ Excel/JSON 一括取込**
> 完了時の状態: `/t/:slug/field-definitions` と `/t/:slug/validation-rules` の CRUD が回り、Excel または JSON でナレッジを一括取込でき、取込時に embedding が `passage:` で計算される
> 推定所要: 5〜7 時間

---

## Day2-1. ValidationRule CRUD [AI] [FE] [BE]

**目的**
`field_definitions.validation_rule_id` から参照される `validation_rules` を画面から CRUD できるようにする。FieldDefinition（Day2-2）が `<select>` で選ぶ先なので先に作る。Day1 で固めた編集パターンの複製なので AI。

**前提確認**
- [ ] Day1 完了（編集パターン・配列エディタコンポーネントがある）
- [ ] `apps/api/src/entities/ValidationRule.ts` の列を確認（`name` / `minLength?: number` / `maxLength?: number` / `regex?: string` / `errorMessage?: string`）

**AI 依頼テンプレ**
```
apps/web/src/pages/knowledge/ の Index/Create/Edit と同じパターンで、
ValidationRule の CRUD 3 ページを apps/web/src/pages/validationRules/ に作って。
対応する Node API エンドポイント（GET/POST/PUT/DELETE /api/validation-rules）も apps/api/src/routes/ に追加して。

制約:
- ルート: /t/:slug/validation-rules（一覧）, /new, /:id/edit
- フォーム列: name(必須, max 100) / minLength(number?) / maxLength(number?) / regex(string?) / errorMessage(string?)
- minLength/maxLength は両方 null 可。minLength > maxLength のときは zod の refine で弾く
- regex は不正な正規表現を submit 時に new RegExp(...) で検証し、失敗ならフォームにエラー表示（実行はしない、構文チェックのみ）
- 一覧は API から取得（tenantId は JWT クレームから）
- 削除は、参照中の FieldDefinition があれば API 側で拒否して 409 を返し、フロントでメッセージ表示
- エラーハンドリングは Knowledge の Edit と同じ扱い
変更は apps/web/src/pages/validationRules/ と apps/api/src/routes/validationRules.ts に閉じる。
エンティティ定義は変えない。
```

**自分の確認ポイント**
- [ ] 一覧 → 作成 → 編集 → 削除が回る
- [ ] 不正な Regex で保存しようとするとフォームエラー（500 にしない）
- [ ] FieldDefinition から参照中の rule を削除しようとすると拒否される
- [ ] 別テナントの rule が見えない（API の RLS）

---

## Day2-2. FieldDefinition CRUD（field_type / is_multi / choices / validation_rule_id）[AI] [FE] [BE]

**目的**
動的フォームの定義元 `field_definitions` を CRUD できるようにする。`field_type` で `choices` の要否が変わり、`is_multi` で複数値入力になり、`validation_rule_id` で Day2-1 の rule を選ぶ。`choices`（`string[]`）は Day1 の配列エディタコンポーネントを流用。複製 + 軽い分岐なので AI。

**前提確認**
- [ ] Day2-1 完了（`validation_rules` が選択肢として存在）
- [ ] `apps/api/src/entities/FieldDefinition.ts` の列を確認（`code` / `fieldType` / `isRequired` / `isMulti` / `question?: string` / `choices?: string[]` / `validationRuleId?: string`）
- [ ] `fieldType` の取りうる値は [`08_features.md:39`](../08_features.md)（text/text_short/choice/radio/multi/date/time/datetime/number/bool/file）

**AI 依頼テンプレ**
```
Knowledge / ValidationRules の CRUD と同じパターンで、FieldDefinition の CRUD 3 ページを
apps/web/src/pages/fieldDefinitions/ に作って。
対応する Node API エンドポイント（GET/POST/PUT/DELETE /api/field-definitions）も apps/api/src/routes/ に追加して。

制約:
- ルート: /t/:slug/field-definitions（一覧）, /new, /:id/edit
- フォーム列:
  - code(必須, max 64, 同一テナント内ユニーク。重複なら API 側 409 → フォームにエラー表示)
  - fieldType: <select>。値は text/text_short/choice/radio/multi/date/time/datetime/number/bool/file
  - isRequired(boolean) / isMulti(boolean)
  - question(string?)
  - choices(string[]?): Day1 で作った配列エディタコンポーネント(apps/web/src/components/knowledge/)を流用。
    fieldType が choice/radio/multi のときだけ表示・必須（それ以外は非表示で null）
  - validationRuleId(string?): GET /api/validation-rules から取得して <select>、空(なし)も選べる
- 一覧列: code / fieldType / isMulti / choices 件数 / 紐づく ValidationRule 名 / isRequired
- 削除は確認ダイアログのみで可（DB 上の FK は緩い）
- エラーハンドリングは既存と同じ
変更は apps/web/src/pages/fieldDefinitions/ と apps/api/src/routes/fieldDefinitions.ts に閉じる。
エンティティ定義は変えない。
```

**自分の確認ポイント**
- [ ] `fieldType=choice/radio/multi` で `choices` 編集欄が出る、その他では隠れて保存値が null
- [ ] `validationRuleId` で Day2-1 の rule を選べる、未選択(null)も保存できる
- [ ] `code` 重複でエラー表示（500 にしない）
- [ ] 別テナントの定義が見えない（API の RLS）

---

## Day2-3. 取込スキーマ・突合キー（upsert キー）定義 [自分] [設計]

**目的**
Excel/JSON 一括取込の**スキーマ（列構成）と突合キー（再取込時に新規 INSERT か既存 UPDATE かを決めるキー）**を自分で定義する。ここを AI に決めさせると、再取込で重複が量産されたり別テナントのデータを踏む取込になり、説明できない。既存 Streamlit 版 `data.xlsx` の構造（[`10_existing_streamlit.md:121-126`](../10_existing_streamlit.md)）を踏襲しつつ、DB の配列列・3 段階エスカレーション列に対応づける。面接では「冪等な取込（upsert）の突合キーをテナント内 `category.code` + `knowledge.name` に置いた理由」を語れる。

**自分で書く理由**
取込の突合キー設計は「再取込したら何が起きるか」を決める設計判断（[`09_task_split.md` の設計判断系]）。Sprint 1 day3 の Seed ツール（[`sprint1/day3.md`](../sprint1/day3.md)）は「初回 INSERT 専用」だったが、マスタ管理 UI からの取込は**繰り返し実行される**ので冪等性が要る。

**前提確認**
- [ ] Day2-1 / 2-2 完了（取込先のマスタが全部 CRUD できる）
- [ ] [`10_existing_streamlit.md:35-46`](../10_existing_streamlit.md)（`knowledge.py` の load_* と `data.xlsx` のシート構成）を読んだ
- [ ] `KnowledgeEntry` / `Category` の実列（[`day1.md`](day1.md) で確認済み）を手元に置く
- [ ] 取込時 embedding は文書なので `passage:`（CLAUDE.md 横断ルール）

**手順（自分が書く成果物 = 取込仕様メモ。`design/` は書き換えず、この day ファイル準拠で AI に渡す）**
1. **取込形式を 2 つ定義する**（同じ論理スキーマを Excel と JSON で表す）:
   - Excel: `categories` シート + `knowledge_entries` シート（既存 `data.xlsx` 踏襲。列ヘッダ固定行）
   - JSON: `{ "categories": [...], "knowledge_entries": [...] }` の 1 ファイル
2. **論理スキーマ（列 → エンティティ列の対応）を表にする**:
   - `categories`: `code`(必須) / `name`(必須) / `emoji?` / `sort_order?` / `required_field_codes`（`;` 区切り → `string[]`）
   - `knowledge_entries`: `category_code`(必須, 上の `code` を参照) / `name`(必須) / `keywords`（`;` 区切り）/ `example_queries`（`;` 区切り）/ `required_field_codes`（`;` 区切り）/ `auto_resolution?` / `guidance_message?` / `ticket_priority?`（既定 `normal`）
   - 区切り文字は `;`（カンマは本文に混ざるため避ける）と決め、メモに明記
3. **突合キー（upsert キー）を決める**:
   - `Category`: テナント内 `code` で upsert（`code` は安定 ID）
   - `KnowledgeEntry`: テナント内 `(category_code, name)` で upsert（`name` 変更は別物扱い＝新規。これも判断として明記）
   - `tenantId` は JWT クレームから（取込 API は admin がログイン中なので JWT から取得）。**ファイル内の tenant 列は信用しない / そもそも持たせない**
4. **embedding 再計算の発火**: 新規 or `name`/`keywords`/`example_queries` が変わった行だけ Day1-4 の `knowledgeEmbeddingUpdater` を `passage:` で呼ぶ、と決める
5. **検証ルール**: `category_code` が `categories` 側に無い knowledge は取込前にエラーで弾く（孤児防止）。1 件でもエラーがあれば**全体ロールバックするか部分取込するか**を決める（MVP は「検証フェーズで全件チェック → OK なら 1 トランザクションで適用」と決める）

**完了確認**
- [ ] 取込スキーマ（Excel シート + JSON 構造）と列→エンティティ対応表をメモにした
- [ ] upsert 突合キー（category=`code`, knowledge=`(category_code, name)`）を根拠付きで決めた
- [ ] 区切り文字 `;`、tenant はファイル外（JWT クレーム）から、を明記した
- [ ] embedding 再計算の発火条件と、検証フェーズ→1 トランザクション適用の方針を決めた

**AI 依頼テンプレ**: なし（スキーマ・突合キーは自分で握る）

---

## Day2-4. Excel/JSON 一括取込 UI（passage: で embedding 計算）[AI 一次→自分レビュー] [BE] [ML]

**目的**
Day2-3 で固めたスキーマ・突合キーに従って、ファイルをアップロード → 検証（dry-run プレビュー）→ 適用、ができる取込ページを実装する。Excel は exceljs、JSON は `JSON.parse`（TypeScript 標準）。適用時、対象行の embedding を **`passage:` で計算**（Day1-4 のサービス）。一次実装は AI、**突合キーの実装が Day2-3 の定義通りか / embedding が `passage:` かを自分がレビューで握る**。

**前提確認**
- [ ] Day2-3 完了（取込仕様メモが手元にある＝AI への正の入力）
- [ ] Day1-4 の `knowledgeEmbeddingUpdater`（`passage:`）が動く
- [ ] Sprint 1 day3 の Seed ツール（[`sprint1/day3.md:240-263`](../sprint1/day3.md)）が既にあれば、その exceljs 読み取りロジックを流用できるか確認（**初回 INSERT 専用なので upsert ロジックは別途**。重複させず流用部分だけ参照）

**AI 依頼テンプレ**
```
ナレッジ一括取込ページを apps/web/src/pages/knowledge/Import.tsx に作って。
対応する Node API エンドポイント（POST /api/knowledge/import）も apps/api/src/routes/knowledgeImport.ts に追加して。
取込スキーマと突合キーは下記（本ファイル Day2-3 で確定済み）に厳密に従うこと。

スキーマ（Excel: categories / knowledge_entries の 2 シート。JSON: { categories:[], knowledge_entries:[] }）:
- categories: code(必須) / name(必須) / emoji? / sort_order? / required_field_codes(";" 区切り)
- knowledge_entries: category_code(必須) / name(必須) / keywords(";") / example_queries(";") /
  required_field_codes(";") / auto_resolution? / guidance_message? / ticket_priority?(既定 normal)

突合キー（upsert）:
- Category: テナント内 code で upsert
- KnowledgeEntry: テナント内 (category_code, name) で upsert（name 変更は新規扱い）
- tenantId はファイルから読まない。JWT クレームから取得して全行に明示的に埋める

仕様:
- ルート /t/:slug/knowledge/import
- フロントは <input type="file"> で .xlsx / .json を受け、multipart で API に送信
- API 側で拡張子で分岐。Excel は exceljs、JSON は JSON.parse
- 2 フェーズ:
  1) 検証(dry-run): 全行パース → category_code が categories に無い knowledge はエラー、必須欠落もエラー。
     新規/更新の件数とエラー一覧をレスポンスで返し、フロントにプレビュー表示（この時点で DB は変更しない）
  2) 適用: エラー 0 のときだけフロントの「適用」ボタン有効。API 側で 1 トランザクションで Category upsert → KnowledgeEntry upsert。
     新規 or name/keywords/example_queries が変わった KnowledgeEntry だけ knowledgeEmbeddingUpdater.recompute を呼ぶ
     適用後は Elasticsearch のインデックスも更新済みであること（knowledgeEmbeddingUpdater 内で ES 更新）
- embedding は文書なので必ず passage:（mode: "passage"）。"query" にしない
- 進捗は pino logger で 100 件ごと。console.log は使わない
制約: apps/api の TypeScript strict モード・SQL はパラメータ化クエリ（文字列結合禁止）・
async/await・secret/SQL をログに出さない。
変更は apps/web/src/pages/knowledge/Import.tsx と apps/api/src/routes/knowledgeImport.ts、
必要なら apps/api/src/services/importService.ts に閉じる。エンティティ定義は変えない。
```

**自分のレビュー責務（ここが本タスクの肝）**
- [ ] **突合キーが Day2-3 の定義通り**（category=`code`, knowledge=`(category_code, name)`）。違うと再取込で重複
- [ ] **embedding が `mode: "passage"`**（`"query"` になっていない）。`"query"` だと検索品質が静かに劣化
- [ ] `tenantId` がファイル由来でなく JWT クレームから取得している（クライアント由来 tenant を信用しない＝CLAUDE.md テナント境界）
- [ ] 検証フェーズで `category_code` 孤児を弾いている
- [ ] 区切り文字 `;` で配列化、本文に `;` が来うる列（`auto_resolution` 等）は分割しない

**完了確認**
- [ ] 既存 `data.xlsx` 相当の Excel を取込 → カテゴリと Knowledge が画面に出る
- [ ] 同じファイルを再取込しても重複が増えない（全件 UPDATE 扱い、件数プレビューが「更新 N / 新規 0」）
- [ ] JSON でも同じ取込ができる
- [ ] 取込後 Elasticsearch の `dense_vector` が更新され `passage:` で計算されている（1 件 `"query"` で同テキストを embed して値が違うことを確認）
- [ ] `category_code` 不正のファイルは検証で弾かれ DB が変わらない
- [ ] 別テナントのデータに影響しない（JWT テナント固定）

**詰まったら**
- exceljs が日本語ヘッダで列を取り違える → `worksheet.getRow(1).values` でヘッダ行を読み、列名で引く実装に再依頼
- embedding が `"query"` になっている → FastAPI `/embed` の mode 取り扱いと Day1-4 の `mode: "passage"` を確認

---

## Day 2 終了チェックリスト

- [ ] `/t/:slug/validation-rules` の CRUD が回る
- [ ] `/t/:slug/field-definitions` の CRUD が回り、`choices` / `isMulti` / `validationRuleId` を編集できる
- [ ] `/t/:slug/knowledge/import` で Excel / JSON を取込でき、検証 → 適用の 2 フェーズが動く
- [ ] 再取込が冪等（突合キーで upsert、重複しない）
- [ ] 取込時 embedding が `passage:` で計算され Elasticsearch に反映されている
- [ ] 別テナントへ漏れない（JWT テナント固定）
- [ ] `pnpm --filter api build` および `pnpm --filter web build` が error 0

## Sprint 6 完了後のメモ（自分宛て）

- これでマスタ（Knowledge / FieldDefinition / ValidationRule / Category）が全部画面で揃い、Excel/JSON 取込でデモデータも投入できる。MVP のマスタ管理は締まり。
- 本 Sprint で投入した Knowledge は、今後 ⑥ LLM フォールバックのデモ用テストデータに使える（`autoResolution` 空・スコア低めの行を 1 件用意しておくと LLM フォールバックを発火させやすい）
- **MVP 後に残るタスク**は `sprint6_plan.md` 末尾「完了後に残るタスク」を参照（⑥ LLM フォールバックの UI 結線、組織オンボーディング & メンバー管理、BYOK Gemini 鍵 Secret Manager 保管 など）
