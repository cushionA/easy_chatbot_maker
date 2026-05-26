# Sprint 6 Day 1 作業指示書（2026-06-12）

> テーマ: **マスタ CRUD の本命 — KnowledgeEntry リッチ編集の型を仕上げる**
> 完了時の状態: `/t/{Slug}/knowledge/{Id:guid}/edit` で `example_queries` / `auto_resolution` / `guidance_message` / `ticket_priority` / `required_field_codes` を含む全列を編集でき、保存時に embedding 再計算が `passage:` でトリガされる。一覧/作成/削除も回る
> 推定所要: 5〜7 時間

---

## Day1-1. Sprint 4 前提リハビリ + KnowledgeEntry 編集の現状確認 [自分]

**目的**
Sprint 2 day1 で AI が作った Knowledge CRUD は「配列列をカンマ区切り 1 行で雑に編集する」最小実装だった（[`sprint2/day1.md:21-22`](../sprint2/day1.md)）。今日はそれを「マスタ管理として実用に耐えるリッチ編集」に格上げする。まず現状の編集ページが何を編集できて何を取りこぼしているかを自分の目で確認し、今日の差分を箇条書きにする。面接では「PoC の雑な編集 UI を、3 段階エスカレーション列まで含む実用マスタ管理に育てた差分」を語れる。

**自分で書く理由**
今日の作業範囲（=どの列を編集対象に昇格させ、embedding をいつ再計算するか）は設計判断。AI に「確認して」と投げると、何を仕上げるべきかの判断ごと委譲してしまう。

**前提確認**
- [ ] Sprint 1 / 2 / 4 が完了している（[`sprint6_plan.md`](../sprint6_plan.md) の前提）
- [ ] `dotnet build Portfolio.sln --configuration Release` が warning 0 で通る
- [ ] `backend/Portfolio.Web/Data/Entities/KnowledgeEntry.cs` の列を確認した（`Name` / `Keywords[]` / `ExampleQueries[]` / `RequiredFieldCodes[]` / `AutoResolution?` / `GuidanceMessage?` / `TicketPriority`（default `"normal"`）/ `MatchCount` / `Embedding?` / `EmbeddingModel?` / `SearchText`）
- [ ] [`08_features.md:18`](../08_features.md)（問題エントリ管理の編集対象列）と [`05_search_classification.md:113-134`](../05_search_classification.md)（3 段階エスカレーション / `required_field_codes` 結合）を読んだ

**手順**
1. 既存の `Components/Pages/Knowledge/Edit.razor`（Sprint 2 day1 生成物）を開き、現状で編集できる列を列挙する
2. 今日の昇格対象を箇条書きにする（このメモが Day1-2 の設計の正）:
   - `ExampleQueries`（`string[]`）→ カンマ 1 行ではなく**行追加できる配列エディタ**にする
   - `Keywords` / `RequiredFieldCodes`（`string[]`）→ 同じ配列エディタを再利用
   - `AutoResolution` / `GuidanceMessage`（`string?`）→ 複数行 `InputTextArea`、両方の有無で 3 段階エスカレーションが決まることをラベルに明記
   - `TicketPriority` → 自由文字でなく `InputSelect`（`low` / `normal` / `high` / `urgent` を仮置き、設計に enum 定義がないので**ここで仮決めし報告**）
   - `CategoryId` → `Categories` から引いた `InputSelect`
3. embedding 再計算の方針を決める: **`Name` / `Keywords` / `ExampleQueries` のいずれかが変わったら再計算が要る**（`search_text` の生成元と揃える）。再計算は Day1-4 で実装、Day1-2 では「保存後に再計算サービスを呼ぶフック点」だけ用意する、と決める
4. `EmbeddingModel` 列は手で触らせない（再計算サービスが `current_model` を埋める）方針をメモ

**完了確認**
- [ ] 「今日昇格する列」と「embedding 再計算の発火条件」を箇条書きにした
- [ ] `TicketPriority` の取りうる値を仮決めし、設計に定義が無い旨をメモした（報告対象）
- [ ] ビルドが warning 0

**AI 依頼テンプレ**: なし（範囲確定は自分）

---

## Day1-2. KnowledgeEntry リッチ編集ページ（配列 / 3 段階列 / required_field_codes / embedding 再計算トリガ）[自分]

**目的**
**マスタ編集 UX の「最初の 1 個（型）」を自分の手で仕上げる**。これが Day2 の FieldDefinition / ValidationRule、そして取込後の手修正でも使う「配列エディタ + 多列フォーム」のお手本になる。`example_queries` を行追加で編集でき、3 段階エスカレーション（`auto_resolution` / `guidance_message`）の意味がラベルで分かり、`required_field_codes` を編集でき、保存時に embedding 再計算がトリガされる。面接では「Blazor `EditForm` で配列列を行追加 UI として編集し、保存契機で embedding を再計算する設計」を語れる。

**自分で書く理由**
配列列の双方向バインド（`string[]` を行追加 UI に載せる）と、保存→embedding 再計算という副作用の発火点は、後続が全部複製する型。ここを AI に決めさせると、`example_queries` の編集 UX も再計算契機も「説明できないコード」になる。SKILL.md の「最初の 1 個は自分」。

**前提確認**
- [ ] Day1-1 完了（昇格列リストと再計算条件が手元にある）
- [ ] Sprint 2 day1 の `Components/Pages/Knowledge/Edit.razor` が動く（複製の土台）
- [ ] 配列列を `EditForm` に直接バインドできない問題と回避策（中間プロパティ）を理解（[`sprint2/day1.md:31-33`](../sprint2/day1.md)）

**手順**（骨格とコメントだけ示す。実装ロジック本体は自分で埋める）
1. `Components/Pages/Knowledge/Edit.razor` を改装（新規ではなく既存を昇格）。`@rendermode InteractiveServer` を明示（backend/CLAUDE.md）
2. `FormModel` を実列に合わせて定義する。配列列（`Keywords` / `ExampleQueries` / `RequiredFieldCodes`）は `EditForm` に直接バインドできないので **`List<string>` の中間プロパティ**で持ち、読込時に `ToList()` / 保存時に `ToArray()` で実列と橋渡しする（[`sprint2/day1.md:31-33`](../sprint2/day1.md)）。スカラー列は `Name`(`[Required, StringLength(200)]`) / `CategoryId`(`Guid`) / `AutoResolution`(`string?`) / `GuidanceMessage`(`string?`) / `TicketPriority`(`[Required]`, 既定 `"normal"`):
   ```csharp
   private sealed class FormModel
   {
       // ここを自分で実装: KnowledgeEntry の編集対象列を Day1-1 の昇格リストに沿って宣言する。
       //   - 配列列は List<string>（保存時 ToArray、読込時 ToList）
       //   - 必須/長さ制約は DataAnnotations で（Name は Required+StringLength(200)）
       //   - TicketPriority は既定 "normal"
   }
   ```
3. **配列エディタを 1 つの再利用断片として書く**（`example_queries` 用に書き、`keywords` / `required_field_codes` でも使い回す）。構造は「各行 = `InputText`（要素への双方向バインド）+ 行削除ボタン」「末尾に + 行追加ボタン」。注意点は **詰まったら** 節（ループ変数のキャプチャ、`@key`）を先に読むこと:
   ```razor
   @* ExampleQueries editor — 配列列の編集 UX のお手本。Day2 / 取込後修正でも流用する *@
   @* ここを自分で実装:
        - _form.ExampleQueries を for で回し、各要素に InputText を @bind-Value する
        - 各行に「行削除」(RemoveAt) ボタン、末尾に「+ 行追加」(Add(string.Empty)) ボタン
        - 再描画でフォーカスが飛ぶ問題は「詰まったら」節の対策（idx キャプチャ / @key）で回避 *@
   ```
4. 3 段階エスカレーション列はラベルで意味を明示する（[`05_search_classification.md:117-121`](../05_search_classification.md) の表）:
   - `AutoResolution`: 「入力すると自動回答完結（起票しない）」
   - `GuidanceMessage`: 「auto_resolution が空でこれが有ると、ガイダンス → フォーム」
   - 両方空 → 直接フォーム、を注記
5. `TicketPriority` は `InputSelect`（Day1-1 で仮決めした値の選択肢を並べる）
6. `OnSubmit` で実列を更新し、**保存後に embedding 再計算をトリガするフック点だけ置く**（実体は Day1-4 の `IKnowledgeEmbeddingUpdater`）。「再計算が要るか」は検索元（`Name` / `Keywords` / `ExampleQueries`）が変わったかで判定する:
   ```csharp
   // embedding は文書なので passage: で計算する（CLAUDE.md 横断ルール）。
   // 実体は Day1-4 の IKnowledgeEmbeddingUpdater。ここでは「再計算が要るか」を判定して呼ぶだけ。
   // ここを自分で実装:
   //   1. 旧 entity 値と _form の Name/Keywords/ExampleQueries を比較する判定を書く
   //   2. 変化があったときだけ await _embeddingUpdater.RecomputeAsync(entity.Id, ct) を呼ぶ
   //   3. guidance_message だけ変更のケースでは呼ばれないことを完了確認で担保する
   ```
7. 楽観ロック・エラーハンドリングは Sprint 1 day3 の `Edit.razor` と同じ扱いに揃える（[`sprint1/day3.md:209-214`](../sprint1/day3.md)）
8. `tenant_id` は `WHERE` に書かず RLS 任せ、保存時の `TenantId` は `HttpContext.Items["TenantId"]` から（[`sprint1/day3.md:163`](../sprint1/day3.md)）

**完了確認**
- [ ] `example_queries` を行追加・行削除・編集して保存でき、再読込で反映される
- [ ] `keywords` / `required_field_codes` も同じ配列エディタで編集できる
- [ ] `auto_resolution` / `guidance_message` / `ticket_priority` / `category_id` が編集・保存できる
- [ ] `Name` または `Keywords`/`ExampleQueries` を変えて保存すると embedding 再計算フックが呼ばれる（Day1-4 未実装ならログ or no-op で発火だけ確認）
- [ ] それ以外（例: `guidance_message` だけ変更）では再計算が呼ばれない
- [ ] 別テナントの id を踏むと 404（RLS で `Find` が null）
- [ ] `dotnet build` warning 0

**詰まったら**
- `@bind-Value` を `List<string>` の要素に張ると再描画でフォーカスが飛ぶ → ループ変数を `var idx = i;` でキャプチャ（上記）。それでも不安定なら各行を `@key` 付きの小コンポーネントに切り出す
- 配列列の保存で空文字が混ざる → `ToArray()` 前に `Where(s => !string.IsNullOrWhiteSpace(s))`

**AI 依頼テンプレ**: なし（編集 UX の型は自分で書く）

---

## Day1-3. KnowledgeEntry 一覧/作成/削除ページ [AI]

**目的**
Day1-2 で固めたリッチ編集ページを土台に、一覧（リッチ列のサマリ表示）・作成（編集と同じフォーム）・削除を AI に複製させる。同パターン複製なので委譲。

**前提確認**
- [ ] Day1-2 完了（`Edit.razor` が動く＝複製元になる）

**AI 依頼テンプレ**
```
backend/Portfolio.Web/Components/Pages/Knowledge/Edit.razor を土台に、Knowledge の
一覧 Index.razor / 作成 Create.razor / 削除を整備して。

制約:
- ルート: 一覧 /t/{Slug}/knowledge、作成 /t/{Slug}/knowledge/new、[Authorize]、@rendermode InteractiveServer
- Create.razor は Edit.razor と同じ FormModel・同じ配列エディタ断片を使う（フォーム部分は共通化して重複を避ける。
  Components/Shared/ に小コンポーネントとして切り出してよい）
- Index.razor: Db.KnowledgeEntries.AsNoTracking() を Category 名で結合表示。
  列は Name / Category / TicketPriority / auto_resolution の有無(○/-) / guidance_message の有無 / ExampleQueries 件数 / UpdatedAt。
  各行に Edit リンクと Delete ボタン
- 削除は確認ダイアログ後に Db.Remove → SaveChangesAsync。削除後は一覧へ
- 作成時 embedding 再計算は Day1-4 の IKnowledgeEmbeddingUpdater を呼ぶ（Edit.razor と同じ発火条件、新規は常に再計算）
- tenant_id は WHERE に書かない（RLS 任せ）。TenantId は HttpContext.Items["TenantId"] から
- 楽観ロック/エラーハンドリングは既存 Category の Edit と同じ扱い
変更は Components/Pages/Knowledge/ と Components/Shared/ に閉じる。エンティティ・AppDbContext は変えない。
```

**自分の確認ポイント**
- [ ] 一覧 → 作成 → 編集 → 削除の一周が回る
- [ ] 作成時に embedding が `passage:` で入る（Day1-4 と接続後）
- [ ] 配列エディタ断片が Create / Edit で共通化され重複していない
- [ ] 別テナントの Knowledge が一覧に出ない（RLS 目視）

---

## Day1-4. embedding 再計算トリガの passage: 計算実装 [AI 一次→自分レビュー]

**目的**
Day1-2 で置いたフック点 `IKnowledgeEmbeddingUpdater.RecomputeAsync` の実体を作る。`Name` + `Keywords` + `ExampleQueries` を 1 本の文書文字列に組み、**`passage:` モード**で embedding を計算して `Embedding` / `EmbeddingModel` 列を更新する。`query:`/`passage:` を間違えると検索 recall が静かに落ちる（[`embedding/CLAUDE.md`](../../embedding/CLAUDE.md)）ので、**mode が `Passage` であることだけは自分がレビューで握る**。

**前提確認**
- [ ] Day1-2 完了（フック点がある）
- [ ] `backend/Portfolio.Web/Services/IEmbeddingClient.cs` の現状シグネチャを確認した
  - **注意**: 現状の `IEmbeddingClient.EmbedAsync(string text, CancellationToken)` は `mode` 引数を持たない（Sprint 2 day1-5 で計画した `EmbedMode` enum 化が実コードに入っていない）。`passage:` を確実に通すため、`EmbedMode { Query, Passage }` を追加して `passage` を明示できる状態にしてから使う（報告対象）
- [ ] [`embedding/CLAUDE.md`](../../embedding/CLAUDE.md) の「prefix `query: ` for queries, `passage: ` for documents」を読んだ

**手順（自分が握る部分）**
1. インターフェースを自分で定義する（`Portfolio.Web/Services/IKnowledgeEmbeddingUpdater.cs`、実装は AI）:
   ```csharp
   namespace Portfolio.Web.Services;

   public interface IKnowledgeEmbeddingUpdater
   {
       // KnowledgeEntry の検索元テキストを passage: で再 embedding し Embedding/EmbeddingModel を更新する。
       Task RecomputeAsync(Guid knowledgeEntryId, CancellationToken ct = default);
   }
   ```
2. embedding の元テキストの組み方を決める（`search_text` 生成列と揃える＝`Name` + `Keywords` + `ExampleQueries` を空白連結）。この 1 行を自分でコメントに残す
3. **`IEmbeddingClient` の `passage` 対応がまだなら、まず enum 化を AI に依頼**（下記テンプレの前半）

**AI 依頼テンプレ**
```
2 つ作って。

(1) IEmbeddingClient に passage 対応を入れる:
- backend/Portfolio.Web/Services/IEmbeddingClient.cs に EmbedMode { Query, Passage } enum を追加し、
  EmbedAsync(string text, EmbedMode mode = EmbedMode.Query, CancellationToken ct = default) に変更
- EmbeddingClient.cs を mode から /embed の mode 文字列("query"/"passage")を導く実装に直す
  （プレフィクスはサーバ側 embedding service が付ける。Web 側で query:/passage: を文字列付与しない＝二重付与防止）
- 既存 EmbedAsync 呼び出し元（grep -rn EmbedAsync backend/）を新シグネチャに合わせる（既存は EmbedMode.Query 相当）

(2) IKnowledgeEmbeddingUpdater の実装:
- backend/Portfolio.Web/Services/KnowledgeEmbeddingUpdater.cs を作り IKnowledgeEmbeddingUpdater を実装
- RecomputeAsync(id):
  1. Db.KnowledgeEntries.FindAsync(id)（RLS 任せ、tenant_id は WHERE に書かない）
  2. 元テキスト = string.Join(" ", new[]{ Name }.Concat(Keywords).Concat(ExampleQueries))
  3. await embeddingClient.EmbedAsync(text, EmbedMode.Passage, ct)  ← passage 必須
  4. entity.Embedding = new Vector(result); entity.EmbeddingModel = options.CurrentModel;
  5. await Db.SaveChangesAsync(ct)
- DI 登録（Program.cs）。AddHttpClient<T,TImpl> 既存の embedding クライアント登録に合わせる
制約: backend/CLAUDE.md（Nullable/TreatWarningsAsErrors、primary constructor、ILogger<T>、async/Async、
System.Text.Json、secret/SQL をログに出さない）。current_model の供給元は既存の設定（ClassifyOptions 等）に合わせる。
```

**自分のレビュー責務（ここが本タスクの肝）**
- [ ] **`EmbedMode.Passage` で呼んでいる**（`Query` になっていない）
- [ ] Web 側で `passage:` の文字列を手付けしていない（サーバ側が付ける。二重付与で `passage: passage:` にならない）
- [ ] `EmbeddingModel` に `current_model` が入る
- [ ] embedding 計算失敗時に保存全体を巻き込んで壊さない（再計算は best-effort でもログを残す）

**完了確認**
- [ ] Day1-2/1-3 から作成・編集すると `Embedding` が NULL でなく、`EmbeddingModel` が埋まる
- [ ] `Name` だけ変更 → embedding が変わる / `guidance_message` だけ変更 → 再計算されない
- [ ] `query` と `passage` で `/embed` のベクトルが異なることを 1 度実機確認した
- [ ] `dotnet build` warning 0

---

## Day 1 終了チェックリスト

- [ ] `/t/{Slug}/knowledge` の一覧/作成/編集/削除が回る
- [ ] 編集ページで `example_queries`（行追加）/ `keywords` / `required_field_codes` / `auto_resolution` / `guidance_message` / `ticket_priority` / `category_id` が編集できる
- [ ] 保存時に検索元（Name/Keywords/ExampleQueries）が変わったときだけ embedding が `passage:` で再計算される
- [ ] 別テナントのデータが見えない（RLS）
- [ ] `dotnet build Portfolio.sln --configuration Release` が warning 0

## Day 2 への引き継ぎメモ（自分宛て）

- 配列エディタ断片（`Components/Shared/`）は Day2 の FieldDefinition `choices` 編集でも流用する
- `IKnowledgeEmbeddingUpdater` は Day2 の一括取込でも 1 件ずつ呼ぶ（取込も `passage:`）
- `TicketPriority` の取りうる値は仮決め。設計に enum 定義が無いので報告に残す
