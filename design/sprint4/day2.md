# Sprint 4 Day 2 作業指示書（2026-06-02）

> テーマ: **3段階エスカレーション分岐と動的フォーム**
> 完了時の状態: 確定した問題の `auto_resolution` / `guidance_message` で 3 通りに分岐し、起票が必要なケースで `required_field_codes` を結合した動的フォームが型別ウィジェットで描画され、`is_multi` の行追加とクライアント+サーバ両方のバリデーションが効く
> 推定所要: 6〜8 時間

> 着手前に必読: [`05_search_classification.md:113-146`](../05_search_classification.md)（3段階エスカレーション + 動的フォーム + バリデーション）、[`08_features.md:39`](../08_features.md)（フィールド型一覧）、[`10_existing_streamlit.md:70-84`](../10_existing_streamlit.md)（`forms.py` の流用方針）。

---

## Day4-5. 3段階エスカレーション分岐ロジック [自分（分岐ロジックが中核）]

**目的**
[`05:113-128`](../05_search_classification.md) の真偽値表を実装する。確定した `KnowledgeEntry` の `AutoResolution` / `GuidanceMessage` の有無で挙動を 3 通りに分ける。この 3 分岐がサービスの差別化ポイント（「3段階エスカレーション設計」として面接訴求、[`05:128`](../05_search_classification.md)）なので自分で書く。

**自分で書く理由**
真偽値表 → 挙動のマッピングは仕様の核心。誤ると「自動回答すべき FAQ で起票させる」「直接起票すべき案件で勝手に自己解決を促す」など利用者体験を壊す。AI に任せず自分が表を C# の分岐に落とす。

**前提確認**
- [ ] Day 1 完了（確定 `KnowledgeEntry` が 1 つに収束する変数がある）
- [ ] [`05:117-121`](../05_search_classification.md) の表を読んだ
- [ ] `KnowledgeEntry.cs` の `AutoResolution` / `GuidanceMessage`（ともに `string?`）を確認

**手順**
1. 分岐を表のまま明文化（仕様の正、[`05:117-121`](../05_search_classification.md)）:

   | `AutoResolution` | `GuidanceMessage` | 挙動 |
   |---|---|---|
   | あり | - | 自動回答完結。解決方法表示 + 「解決した？」→ `inquiries.resolved` 保存、起票しない |
   | なし | あり | ガイダンス付き起票。ガイダンス表示 →「それでも解決しない →フォーム」 |
   | なし | なし | 直接起票。即フォーム |

2. `Chat.razor` に分岐の骨子を**自分で**書く。enum と判定メソッドのシグネチャだけ示す。**どの真偽の組み合わせがどの enum 値になるか（= 上の表）は自分で `Decide` の中に落とす**:
   ```csharp
   private enum Escalation { AutoResolved, Guided, DirectForm }

   // 表（手順 1）の 3 行を 1 つの戻り値にマッピングする。
   // ヒント: 空文字と NULL の両方を「なし」とみなす（IsNullOrWhiteSpace）。
   //   優先順位に注意 — 表の上の行ほど優先（両方あっても自動回答完結を先に出す）。
   private static Escalation Decide(KnowledgeEntry k)
   {
       // ここを自分で実装: AutoResolution / GuidanceMessage の有無で 3 分岐
   }
   ```
3. 確定時に `Decide(k)` を呼び、`ChatStep` を拡張（`AutoAnswer` / `Guidance` / `Form`）して切替:
   - `AutoResolved` → 解決方法 + 「解決した？ はい/いいえ」。「はい」で `Inquiry.Resolved=true` 保存して終了（保存自体は Day3 で `Inquiry` 一括保存に寄せてもよい）。「いいえ」はフォームへ落とす。
   - `Guided` → `GuidanceMessage` 表示 + 「それでも解決しなかった」ボタンでフォームへ。
   - `DirectForm` → 即フォーム（Day4-6）。

**完了確認**
- [ ] `auto_resolution` ありの問題 → 解決方法 + 「解決した？」が出て、起票に進まない
- [ ] `guidance_message` のみ → ガイダンス → ボタンでフォームへ
- [ ] 両方なし → 即フォーム
- [ ] 両方ありのデータでも自動回答完結が優先される（表 1 行目）

**詰まったら**
- 空文字とNULLの扱いがブレる → `IsNullOrWhiteSpace` で統一（DB が空文字を入れる可能性に備える）

**AI 依頼テンプレ**: なし（自分で書く範囲。フォーム本体は Day4-6 で AI）

---

## Day4-6. 動的フォーム生成（`required_field_codes` 結合 → UI 描画）[AI]

**目的**
[`05:130-134`](../05_search_classification.md)。確定した `KnowledgeEntry.RequiredFieldCodes` と該当 `Category.RequiredFieldCodes` を結合（順序保持・重複除去）し、各 code を `FieldDefinition` に引き当てて型別ウィジェットで描画する。既存 `forms.py` の `render_field`（型別分岐、[`10:74`](../10_existing_streamlit.md)）の C# 再構成。

**前提確認**
- [ ] Day4-5 完了（`DirectForm` / `Guided`→フォーム へ到達できる）
- [ ] `FieldDefinition.cs` の列を確認（`Code` / `FieldType` / `IsRequired` / `IsMulti` / `Question` / `Choices` / `ValidationRuleId`）
- [ ] フィールド型の正は [`08_features.md:39`](../08_features.md): `text/text_short/choice/radio/multi/date/time/datetime/number/bool/file`

**AI 依頼テンプレ**
```
backend/Portfolio.Web/Components/Pages/Chat/ に動的フォームを実装してほしい。

仕様（design/05_search_classification.md:130-146 と design/08_features.md:39 が正）:
1. 入力: 確定した KnowledgeEntry（RequiredFieldCodes: string[]）と、その CategoryId。
2. フィールド code の結合: category.RequiredFieldCodes を先、knowledgeEntry.RequiredFieldCodes を後に連結し、
   出現順を保ったまま重複除去（C# の Distinct ではなく順序保持の dedup を書く）。
3. 各 code を AppDbContext.FieldDefinitions（AsNoTracking, RLS が tenant を絞る）から
   .Where(f => codes.Contains(f.Code)) で引き、結合した順序に並べ替える。見つからない code はスキップしてログ警告。
4. <DynamicForm> コンポーネント（Components/Shared/DynamicForm.razor）が EditForm 内で各 FieldDefinition を
   <DynamicField> 子コンポーネントとして描画する。FieldType ごとのウィジェット対応:
     - text        → InputTextArea
     - text_short  → InputText
     - choice      → <select>（単一、Choices から option）
     - radio       → radio ボタン群（Choices）
     - multi       → 複数選択 checkbox 群（Choices）  ※「複数選択肢」。is_multi(行追加) とは別物なので混同しない
     - date/time/datetime → InputDate（type 切替。datetime は DateTimeLocal）
     - number      → InputNumber
     - bool        → InputCheckbox
     - file        → InputFile（拡張子/サイズ検証は Day4-8 のバリデーションで）
   Question 列をラベルに使う（null なら Code）。IsRequired を * 表示に反映。
5. フォーム値は Dictionary<string code, object?> 的なモデルに集約し、Day4-9 の確認画面・Day4-10 の起票へ渡せる形にする。
   is_multi フィールドは値を配列(List)で持つ（Day4-7 で行追加 UI を足す前提の器を用意）。

制約（backend/CLAUDE.md 準拠）:
- @rendermode InteractiveServer 明示
- EditForm + DataAnnotationsValidator を土台にする（個別ルールは Day4-8 で足す）
- Nullable enable / TreatWarningsAsErrors なので警告ゼロ
- tenant_id でフィルタしない（RLS）。AsNoTracking。
```

**自分の確認ポイント**
- [ ] category 必須 + 問題別必須が**順序保持で**結合され重複しない
- [ ] 全フィールド型が想定ウィジェットで描画される
- [ ] `multi`（複数選択肢）と `is_multi`（行追加）が**混同されていない**（ここが事故りやすい）

---

## Day4-7. `is_multi` 行追加 UI [AI]

**目的**
[`05:136-140`](../05_search_classification.md)。`FieldDefinition.IsMulti == true` のフィールドに「行追加」ボタンを出し、値を配列で送れるようにする（例: 添付 3 つ → `[file1, file2, file3]`）。Day4-6 で用意した「配列で持つ器」に行追加/削除を載せる。

**前提確認**
- [ ] Day4-6 完了（`is_multi` フィールドが配列モデルで保持されている）

**AI 依頼テンプレ**
```
Day4-6 の DynamicField で IsMulti == true のフィールドに行追加 UI を足してほしい。

仕様（design/05_search_classification.md:136-140）:
- 初期 1 行。「+ 行追加」ボタンで同じ型のウィジェットを 1 行増やす。各行に「削除」ボタン（最低 1 行は残す）。
- 値は List<...> で保持し、送信時に配列になる。
- バリデーション（Day4-8）は各行に適用し、1 行でも不正ならフィールド全体を不正扱いにできる構造にする。
- file 型 × is_multi（複数添付）が代表ケースなので必ず動かす。

制約: @rendermode InteractiveServer、Nullable enable、警告ゼロ。
@key を使って行の再描画が崩れないようにする。
```

**自分の確認ポイント**
- [ ] 行追加・削除で値配列が正しく増減する
- [ ] file × is_multi で複数添付が配列になる
- [ ] 行を削除しても残り行の値が壊れない（`@key` 指定の有無を確認）

---

## Day4-8. バリデーション（既存 `forms.py` の `validate_field` 移植、client + server）[AI]

**目的**
[`05:142-146`](../05_search_classification.md)。`FieldDefinition.ValidationRuleId` 経由で `ValidationRule`（`MinLength` / `MaxLength` / `Regex` / `ErrorMessage`）を参照し、必須・文字数・正規表現・ファイル拡張子/サイズを検証する。既存 `forms.py` の `validate_field` ロジック（[`10:77`](../10_existing_streamlit.md)）を C# 移植。**クライアントとサーバの両方で検証**（クライアントを信頼しない、[`10:83`](../10_existing_streamlit.md)）。

**前提確認**
- [ ] Day4-7 完了
- [ ] `ValidationRule.cs`（`MinLength` / `MaxLength` / `Regex` / `ErrorMessage`、すべて nullable）を確認
- [ ] 元ロジックの所在: 既存 Streamlit `forms.py` の `validate_field` / `validate_form`（[`10_existing_streamlit.md:70-84`](../10_existing_streamlit.md)）

**AI 依頼テンプレ**
```
動的フォームのバリデーションを実装してほしい。既存 Streamlit 版 forms.py の validate_field / validate_form
（design/10_existing_streamlit.md:70-84 参照）の C# 移植 + is_multi 対応。

仕様（design/05_search_classification.md:142-146 が正）:
- ルール源: FieldDefinition.ValidationRuleId → ValidationRule(MinLength?, MaxLength?, Regex?, ErrorMessage?)。
- 検証項目:
  - 必須: FieldDefinition.IsRequired が true なら空不可
  - 文字数: MinLength/MaxLength（テキスト系）
  - 正規表現: Regex（System.Text.RegularExpressions, タイムアウトを設定して ReDoS を避ける）
  - file: 拡張子/サイズ（許可拡張子・最大サイズの基準は ValidationRule か定数。元 forms.py に合わせる）
  - エラーメッセージは ValidationRule.ErrorMessage を優先、無ければ既定文言
- is_multi フィールドは各行（各配列要素）に同じルールを適用。1 行でも不正ならフィールド不正。
- 2 層で検証:
  1) クライアント: EditForm の IValidatableObject / カスタム ValidationAttribute で即時赤字
  2) サーバ: 起票直前（Day4-10 の SubmitAsync 呼び出し前）に同じ検証ロジックを再実行し、
     不正なら起票させない。検証ロジックは共有クラス（例: Components/Shared または Services の
     FieldValidator）に切り出して client/server で同じコードを呼ぶ。

制約: Nullable enable / 警告ゼロ。Regex は new Regex(pattern, options, matchTimeout) でタイムアウト必須。
ユニットテストも付ける（必須/文字数/正規表現/ファイル/ is_multi 各行 のケース）。
```

**自分の確認ポイント**
- [ ] クライアントで赤字、かつ DevTools でクライアント検証を潰してもサーバが弾く（**2 層検証が本物か**）
- [ ] `is_multi` の各行に検証が効く
- [ ] Regex にタイムアウトが設定されている（ReDoS 対策）
- [ ] エラーメッセージが `ValidationRule.ErrorMessage` を優先する

---

## Day 2 終了チェックリスト

- [ ] `auto_resolution` / `guidance_message` の 3 分岐が表通りに動く（自動回答が最優先）
- [ ] category + 問題別の `required_field_codes` が順序保持・重複除去で結合される
- [ ] 全フィールド型が描画され、`multi`（複数選択肢）と `is_multi`（行追加）を取り違えていない
- [ ] `is_multi` の行追加・削除と配列送信が動く
- [ ] バリデーションがクライアント + サーバの 2 層で効き、サーバ側を潰すと起票が止まる

## Day 3 への引き継ぎメモ
- フォーム値は code→値（is_multi は配列）の集約モデルで保持済み。Day3 の確認画面・起票本文組立・`draft_fields` 退避でこのモデルをそのまま使う。
- サーバ側検証は共有 `FieldValidator` に切り出した。起票直前（Day4-10）に同じものを呼ぶ。
