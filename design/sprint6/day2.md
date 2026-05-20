# Sprint 6 Day 2 作業指示書（2026-06-13）

> テーマ: **残マスタ（FieldDefinition / ValidationRule）+ Excel/JSON 一括取込**
> 完了時の状態: `/t/{Slug}/field-definitions` と `/t/{Slug}/validation-rules` の CRUD が回り、Excel または JSON でナレッジを一括取込でき、取込時に embedding が `passage:` で計算される
> 推定所要: 5〜7 時間

---

## Day2-1. ValidationRule CRUD [AI]

**目的**
`field_definitions.validation_rule_id` から参照される `validation_rules` を画面から CRUD できるようにする。FieldDefinition（Day2-2）が `InputSelect` で選ぶ先なので先に作る。Day1 で固めた編集パターンの複製なので AI。

**前提確認**
- [ ] Day1 完了（編集パターン・配列エディタ断片がある）
- [ ] `Data/Entities/ValidationRule.cs` の列を確認（`Name` / `MinLength?` / `MaxLength?` / `Regex?` / `ErrorMessage?`）

**AI 依頼テンプレ**
```
backend/Portfolio.Web/Components/Pages/Knowledge/ の Index/Create/Edit と同じパターンで、
ValidationRule の CRUD 3 ページを Components/Pages/ValidationRules/ に作って。

制約:
- ルート: /t/{Slug}/validation-rules（一覧）, /new, /{Id:guid}/edit、[Authorize]、@rendermode InteractiveServer
- フォーム列: Name(必須, max 100) / MinLength(int?) / MaxLength(int?) / Regex(string?) / ErrorMessage(string?)
- MinLength/MaxLength は両方 null 可。MinLength > MaxLength のときは DataAnnotations カスタムで弾く
- Regex は不正な正規表現を保存時に new Regex(...) で検証し、失敗ならフォームにエラー表示（実行はしない、構文チェックのみ）
- 一覧は AsNoTracking()、tenant_id は WHERE に書かない（RLS 任せ）
- 削除は、参照中の FieldDefinition があれば拒否してメッセージ表示（FK 制約 or 事前カウント）
- 楽観ロック/エラーハンドリングは Knowledge の Edit と同じ扱い
変更は Components/Pages/ValidationRules/ に閉じる。エンティティ・AppDbContext は変えない。
```

**自分の確認ポイント**
- [ ] 一覧 → 作成 → 編集 → 削除が回る
- [ ] 不正な Regex で保存しようとするとフォームエラー（500 にしない）
- [ ] FieldDefinition から参照中の rule を削除しようとすると拒否される
- [ ] 別テナントの rule が見えない（RLS）

---

## Day2-2. FieldDefinition CRUD（field_type / is_multi / choices / validation_rule_id）[AI]

**目的**
動的フォームの定義元 `field_definitions` を CRUD できるようにする。`field_type` で `choices` の要否が変わり、`is_multi` で複数値入力になり、`validation_rule_id` で Day2-1 の rule を選ぶ。`choices`（`string[]`）は Day1 の配列エディタ断片を流用。複製 + 軽い分岐なので AI。

**前提確認**
- [ ] Day2-1 完了（`validation_rules` が選択肢として存在）
- [ ] `Data/Entities/FieldDefinition.cs` の列を確認（`Code` / `FieldType` / `IsRequired` / `IsMulti` / `Question?` / `Choices?`（`string[]?`）/ `ValidationRuleId?`）
- [ ] `field_type` の取りうる値は [`08_features.md:39`](../08_features.md)（text/text_short/choice/radio/multi/date/time/datetime/number/bool/file）

**AI 依頼テンプレ**
```
Knowledge / ValidationRules の CRUD と同じパターンで、FieldDefinition の CRUD 3 ページを
Components/Pages/FieldDefinitions/ に作って。

制約:
- ルート: /t/{Slug}/field-definitions（一覧）, /new, /{Id:guid}/edit、[Authorize]、@rendermode InteractiveServer
- フォーム列:
  - Code(必須, max 64, 同一テナント内ユニーク。重複なら保存時にエラー表示)
  - FieldType: InputSelect。値は text/text_short/choice/radio/multi/date/time/datetime/number/bool/file
  - IsRequired(bool) / IsMulti(bool)
  - Question(string?)
  - Choices(string[]?): Day1 で作った配列エディタ断片(Components/Shared/)を流用。
    FieldType が choice/radio/multi のときだけ表示・必須（それ以外は非表示で null）
  - ValidationRuleId(Guid?): Db.ValidationRules から InputSelect、空(なし)も選べる
- 一覧列: Code / FieldType / IsMulti / Choices 件数 / 紐づく ValidationRule 名 / IsRequired
- 一覧は AsNoTracking() で ValidationRule を結合表示、tenant_id は WHERE に書かない（RLS 任せ）
- 削除は、required_field_codes 等から参照されていても DB 上は緩いので確認ダイアログのみで可
- 楽観ロック/エラーハンドリングは既存と同じ
変更は Components/Pages/FieldDefinitions/ に閉じる。エンティティ・AppDbContext は変えない。
```

**自分の確認ポイント**
- [ ] `field_type=choice/radio/multi` で `choices` 編集欄が出る、その他では隠れて保存値が null
- [ ] `validation_rule_id` で Day2-1 の rule を選べる、未選択(null)も保存できる
- [ ] `Code` 重複でエラー表示（500 にしない）
- [ ] 別テナントの定義が見えない（RLS）

---

## Day2-3. 取込スキーマ・突合キー（upsert キー）定義 [自分]

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
   - `tenant_id` は RLS のセッションから（取込画面は admin がログイン中なので `HttpContext.Items["TenantId"]`）。**ファイル内の tenant 列は信用しない / そもそも持たせない**
4. **embedding 再計算の発火**: 新規 or `name`/`keywords`/`example_queries` が変わった行だけ Day1-4 の `IKnowledgeEmbeddingUpdater` を `passage:` で呼ぶ、と決める
5. **検証ルール**: `category_code` が `categories` 側に無い knowledge は取込前にエラーで弾く（孤児防止）。1 件でもエラーがあれば**全体ロールバックするか部分取込するか**を決める（MVP は「検証フェーズで全件チェック → OK なら 1 トランザクションで適用」と決める）

**完了確認**
- [ ] 取込スキーマ（Excel シート + JSON 構造）と列→エンティティ対応表をメモにした
- [ ] upsert 突合キー（category=`code`, knowledge=`(category_code, name)`）を根拠付きで決めた
- [ ] 区切り文字 `;`、tenant はファイル外（ログインユーザー）から、を明記した
- [ ] embedding 再計算の発火条件と、検証フェーズ→1 トランザクション適用の方針を決めた

**AI 依頼テンプレ**: なし（スキーマ・突合キーは自分で握る）

---

## Day2-4. Excel/JSON 一括取込 UI（passage: で embedding 計算）[AI 一次→自分レビュー]

**目的**
Day2-3 で固めたスキーマ・突合キーに従って、ファイルをアップロード → 検証（dry-run プレビュー）→ 適用、ができる取込ページを実装する。Excel は ClosedXML、JSON は `System.Text.Json`。適用時、対象行の embedding を **`passage:` で計算**（Day1-4 のサービス）。一次実装は AI、**突合キーの実装が Day2-3 の定義通りか / embedding が `passage:` かを自分がレビューで握る**。

**前提確認**
- [ ] Day2-3 完了（取込仕様メモが手元にある＝AI への正の入力）
- [ ] Day1-4 の `IKnowledgeEmbeddingUpdater`（`passage:`）が動く
- [ ] Sprint 1 day3 の Seed ツール（[`sprint1/day3.md:240-263`](../sprint1/day3.md)）が既にあれば、その ClosedXML 読み取りロジックを流用できるか確認（**初回 INSERT 専用なので upsert ロジックは別途**。重複させず流用部分だけ参照）

**AI 依頼テンプレ**
```
ナレッジ一括取込ページを backend/Portfolio.Web/Components/Pages/Knowledge/Import.razor に作って。
取込スキーマと突合キーは下記（本ファイル Day2-3 で確定済み）に厳密に従うこと。

スキーマ（Excel: categories / knowledge_entries の 2 シート。JSON: { categories:[], knowledge_entries:[] }）:
- categories: code(必須) / name(必須) / emoji? / sort_order? / required_field_codes(";" 区切り)
- knowledge_entries: category_code(必須) / name(必須) / keywords(";") / example_queries(";") /
  required_field_codes(";") / auto_resolution? / guidance_message? / ticket_priority?(既定 normal)

突合キー（upsert）:
- Category: テナント内 code で upsert
- KnowledgeEntry: テナント内 (category_code, name) で upsert（name 変更は新規扱い）
- tenant_id はファイルから読まない。HttpContext.Items["TenantId"] を全行に明示的に埋める

仕様:
- ルート /t/{Slug}/knowledge/import、[Authorize]、@rendermode InteractiveServer
- InputFile で .xlsx / .json を受け、拡張子で分岐。Excel は ClosedXML、JSON は System.Text.Json
- 2 フェーズ:
  1) 検証(dry-run): 全行パース → category_code が categories に無い knowledge はエラー、必須欠落もエラー。
     新規/更新の件数とエラー一覧を画面にプレビュー表示（この時点で DB は変更しない）
  2) 適用: エラー 0 のときだけ「適用」ボタン有効。1 トランザクションで Category upsert → KnowledgeEntry upsert。
     新規 or name/keywords/example_queries が変わった KnowledgeEntry だけ IKnowledgeEmbeddingUpdater.RecomputeAsync を呼ぶ
- embedding は文書なので必ず passage:（EmbedMode.Passage）。query: にしない
- 進捗は ILogger<T> で 100 件ごと。Console.WriteLine は使わない
制約: backend/CLAUDE.md（parameterized・AsNoTracking は読み取りのみ・System.Text.Json・Newtonsoft 禁止・
async/Async・secret/SQL をログに出さない）。SQL は LINQ で。生 SQL 不要。
変更は Components/Pages/Knowledge/Import.razor と必要なら Services/ の取込サービスに閉じる。エンティティは変えない。
```

**自分のレビュー責務（ここが本タスクの肝）**
- [ ] **突合キーが Day2-3 の定義通り**（category=`code`, knowledge=`(category_code, name)`）。違うと再取込で重複
- [ ] **embedding が `EmbedMode.Passage`**（`query` になっていない）。`query:` だと検索品質が静かに劣化
- [ ] `tenant_id` がファイル由来でなくログインユーザーの `TenantId`（クライアント由来 tenant を信用しない＝CLAUDE.md テナント境界）
- [ ] 検証フェーズで `category_code` 孤児を弾いている
- [ ] 区切り文字 `;` で配列化、本文に `;` が来うる列（`auto_resolution` 等）は分割しない

**完了確認**
- [ ] 既存 `data.xlsx` 相当の Excel を取込 → カテゴリと Knowledge が画面に出る
- [ ] 同じファイルを再取込しても重複が増えない（全件 UPDATE 扱い、件数プレビューが「更新 N / 新規 0」）
- [ ] JSON でも同じ取込ができる
- [ ] 取込後 `embedding` が NULL でなく `passage:` で計算されている（1 件 `query` で同テキストを embed して値が違うことを確認）
- [ ] `category_code` 不正のファイルは検証で弾かれ DB が変わらない
- [ ] 別テナントのデータに影響しない（RLS + ログインテナント固定）

**詰まったら**
- ClosedXML が日本語ヘッダで列を取り違える → ヘッダ行を固定位置（1 行目）とし、列名で引く実装に再依頼（[`sprint1/day3.md:273`](../sprint1/day3.md)）
- embedding が `query:` になっている → サーバ側 `embedding/app/` の mode 取り扱いと Day1-4 の `EmbedMode.Passage` を確認

---

## Day 2 終了チェックリスト

- [ ] `/t/{Slug}/validation-rules` の CRUD が回る
- [ ] `/t/{Slug}/field-definitions` の CRUD が回り、`choices` / `is_multi` / `validation_rule_id` を編集できる
- [ ] `/t/{Slug}/knowledge/import` で Excel / JSON を取込でき、検証 → 適用の 2 フェーズが動く
- [ ] 再取込が冪等（突合キーで upsert、重複しない）
- [ ] 取込時 embedding が `passage:` で計算されている
- [ ] 別テナントへ漏れない（RLS + tenant はログインユーザー）
- [ ] `dotnet build Portfolio.sln --configuration Release` が warning 0

## Sprint 6 完了後のメモ（自分宛て）

- これでマスタ（Knowledge / FieldDefinition / ValidationRule / Category）が全部画面で揃い、Excel/JSON 取込でデモデータも投入できる。MVP のマスタ管理は締まり。
- 本 Sprint で投入した Knowledge は、今後 ⑥ LLM フォールバックのデモ用テストデータに使える（`auto_resolution` 空・スコア低めの行を 1 件用意しておくと LLM フォールバックを発火させやすい）
- **MVP 後に残るタスク**は `sprint6_plan.md` 末尾「完了後に残るタスク」を参照（⑥ LLM フォールバックの UI 結線、組織オンボーディング & メンバー管理、BYOK Gemini 鍵 Vault 保管 など）
