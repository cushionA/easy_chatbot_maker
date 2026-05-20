# Sprint 4 Day 1 作業指示書（2026-06-01）

> テーマ: **チャット画面の足場と分類結線**
> 完了時の状態: `/t/{slug}/chat` でカテゴリ選択 → コンボボックスで問題名を選ぶ／「該当なし」で自然言語入力 → `ClassifyService` を呼んで候補が画面に出る
> 推定所要: 5〜7 時間

> 着手前に必読: [`05_search_classification.md:5-35`](../05_search_classification.md)（フロー①②③）、[`sprint1/day3.md`](../sprint1/day3.md)（Blazor ページの書き方の手本）。
> 既存 Components 構成: ページは `Components/Pages/`、再利用部品は `Components/Shared/`（[`backend/CLAUDE.md`](../../backend/CLAUDE.md)）。Sprint 1 の Category CRUD は `Components/Pages/Categories/` に置いた。本 Sprint の Chat は `Components/Pages/Chat/` にまとめる。

---

## Day4-1. チャット画面の足場 `Chat.razor` を作る [自分（最初の1個=画面の型）]

**目的**
利用者導線の入口になる `/t/{slug}/chat` を自分の手で立てる。フロー①②③をステップ駆動で進める「画面の型」（state machine 的な enum + 子コンポーネント切替）をここで決める。これが Day2/Day3 の動的フォーム・確認画面・未分類キューを差し込む土台になる。面接で「チャット UI をどういう状態機械として設計したか」を語れる中核。

**自分で書く理由**
画面のステップ遷移（`ChatStep` enum と各ステップの責務分割）は後から差し替えにくい設計判断。AI に丸投げすると state が散らかり、Day2 以降のエスカレーション分岐を差し込めなくなる。型と遷移だけは自分で握る。

**前提確認**
- [ ] Sprint 1 完了（`/t/{slug}/categories` が動き、`HttpContext.Items["TenantId"]` が middleware で入る）
- [ ] **`ClassifyService` が実在し想定シグネチャで呼べるか実機確認**（`backend/Portfolio.Web/Services/` を `find` / `grep`。無ければ Sprint 2 に戻る。[`sprint4_plan.md:18`](../sprint4_plan.md)）
- [ ] `Data/Entities/Category.cs` / `KnowledgeEntry.cs` の列を確認（`Code` / `Name` / `Emoji` / `SortOrder` / `RequiredFieldCodes` / `AutoResolution` / `GuidanceMessage`）

**手順**
1. 新規 `Components/Pages/Chat/Chat.razor`:
   ```razor
   @page "/t/{Slug}/chat"
   @rendermode InteractiveServer
   @attribute [Authorize]
   @inject AppDbContext Db

   <h1>Help desk</h1>

   @switch (_step)
   {
       case ChatStep.SelectCategory: /* Day4-2 の <CategoryPicker> を置く */ break;
       case ChatStep.PickProblem:    /* Day4-3 の <ProblemCombobox> を置く */ break;
       case ChatStep.FreeformInput:  /* Day4-4 の自然言語入力を置く */ break;
       case ChatStep.ShowCandidates: /* Day4-5 のエスカレーション分岐へ */ break;
   }

   @code {
       [Parameter] public string Slug { get; set; } = "";

       // 画面の型: 1 セッション = 1 state machine。Blazor Server のサーバ側コンポーネント状態に持つ
       private enum ChatStep { SelectCategory, PickProblem, FreeformInput, ShowCandidates }
       private ChatStep _step = ChatStep.SelectCategory;

       private Guid? _categoryId;          // null = 「わからない」（全件フォールバック）
       private string _query = "";
       // 候補・確定 knowledge は Day4-4/4-5 で追加
   }
   ```
2. `@rendermode InteractiveServer` を **明示**する（.NET 8 では継承されない。[`backend/CLAUDE.md`](../../backend/CLAUDE.md)）。
3. `Components/Layout/MainLayout.razor` のヘッダにチャットへ戻るリンクを足す程度に留める（CRUD sidebar との統合は範囲外）。
4. tenant_id は **クライアントから受け取らない**。書き込み時は `HttpContext.Items["TenantId"]` から取る（Sprint 1 day3 の `Create.razor` と同じ作法）。読み取りは RLS が絞る。

**完了確認**
- [ ] 認証なしで `/t/{slug}/chat` → ログイン誘導
- [ ] 別テナントの slug → 403（middleware の仕事）
- [ ] `_step` を手で書き換えると対応する空ステップに切り替わる（型が機能している）

**詰まったら**
- ボタンを押しても再描画されない → `@rendermode InteractiveServer` の付け忘れ
- `Items["TenantId"]` が null → `/t/{slug}/...` パターン外で呼ばれている／middleware 順序（Sprint 1 day3 の「詰まったら」参照）

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## Day4-2. カテゴリ選択 UI（ボタン式、「わからない」で全件フォールバック）[自分]

**目的**
フロー①（[`05:5-8`](../05_search_classification.md)）。カテゴリをボタンで選ばせ、選択した `category_id` を以降の検索スコープにする。「わからない」を押したら `category_id = null`（= 全件検索フォールバック）にする。この「わからない → 全件」の分岐が後段の検索品質に効く判断点なので自分で書く。

**自分で書く理由**
「わからない＝category_id を絞らない」という仕様上の意味づけは設計判断。`ClassifyService` 側が `categoryId?` を nullable で受ける契約（[`sprint2_plan.md:6`](../sprint2_plan.md)）と整合させる責任を自分が負う。

**前提確認**
- [ ] Day4-1 完了
- [ ] [`05:5-8`](../05_search_classification.md)（「わからない」で全件フォールバック）を読んだ

**手順**
1. `Components/Shared/CategoryPicker.razor` を新規作成（再利用部品）:
   ```razor
   @inject AppDbContext Db

   @if (_categories is null) { <p>Loading...</p> }
   else
   {
       @foreach (var c in _categories)
       {
           <button @onclick="() => OnPick(c.Id)">@c.Emoji @c.Name</button>
       }
       <button @onclick="() => OnPick(null)">わからない</button>
   }

   @code {
       [Parameter, EditorRequired] public EventCallback<Guid?> OnSelected { get; set; }
       private List<Category>? _categories;

       protected override async Task OnInitializedAsync()
           => _categories = await Db.Categories
               .AsNoTracking().OrderBy(c => c.SortOrder).ToListAsync();

       private Task OnPick(Guid? id) => OnSelected.InvokeAsync(id);
   }
   ```
   読み取りは `AsNoTracking()`（[`backend/CLAUDE.md`](../../backend/CLAUDE.md)）。`WHERE tenant_id` は書かない（RLS が絞る）。
2. `Chat.razor` で `<CategoryPicker OnSelected="OnCategorySelected" />` を `SelectCategory` ステップに置き、ハンドラで `_categoryId` を保存して `_step = ChatStep.PickProblem` に進める。

**完了確認**
- [ ] 自テナントのカテゴリのみボタン表示（RLS 目視確認）
- [ ] カテゴリ押下 → `_categoryId` がセットされ次ステップへ
- [ ] 「わからない」押下 → `_categoryId == null` で次ステップへ

**詰まったら**
- 全テナントのカテゴリが見える → `SET LOCAL` が効いていない（Sprint 1 Day2-4 へ）

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## Day4-3. コンボボックス（カテゴリ内問題名の入力フィルタ可能ドロップダウン）[自分（最初の1個）]

**目的**
フロー②（[`05:9-13`](../05_search_classification.md)）。選んだカテゴリ内の `KnowledgeEntry.Name` を入力でフィルタできるドロップダウンにする。選択 → 即確定（`match_strategy=dropdown` 相当）。末尾に「該当なし／見つからない」項目を置き、それを選んだらフロー③（自然言語入力）に落とす。**入力フィルタ + 候補確定 + フォールバック導線**を持つ最初の 1 個を自分で書き、型ができたら他の入力部品は AI 複製可能にする。

**自分で書く理由**
コンボボックスは「入力でフィルタ」「選択で確定」「該当なしで自然言語へ落とす」の 3 挙動を 1 部品に同居させる。この挙動の境界（いつ確定 / いつ ③ へ）が分類フローの分岐そのもの。最初の 1 個の型は自分で握る。

**前提確認**
- [ ] Day4-2 完了
- [ ] [`05:9-13`](../05_search_classification.md)（コンボボックス／「該当なし」で ③ へ）を読んだ

**手順**
1. `Components/Shared/ProblemCombobox.razor`:
   ```razor
   @inject AppDbContext Db

   <input @bind="_filter" @bind:event="oninput" placeholder="問題名で絞り込み" />
   <ul>
       @foreach (var k in Filtered())
       {
           <li @onclick="() => OnConfirm(k)">@k.Name</li>
       }
       <li @onclick="OnNotFound"><em>該当なし / 見つからない</em></li>
   </ul>

   @code {
       [Parameter] public Guid? CategoryId { get; set; }       // null = 全件
       [Parameter, EditorRequired] public EventCallback<KnowledgeEntry> OnSelected { get; set; }
       [Parameter, EditorRequired] public EventCallback OnFallback { get; set; }

       private string _filter = "";
       private List<KnowledgeEntry> _entries = [];

       protected override async Task OnParametersSetAsync()
       {
           var q = Db.KnowledgeEntries.AsNoTracking();
           if (CategoryId is { } id) q = q.Where(k => k.CategoryId == id);
           _entries = await q.OrderBy(k => k.Name).ToListAsync();
       }

       private IEnumerable<KnowledgeEntry> Filtered() =>
           string.IsNullOrWhiteSpace(_filter)
               ? _entries
               : _entries.Where(k => k.Name.Contains(_filter, StringComparison.OrdinalIgnoreCase));

       private Task OnConfirm(KnowledgeEntry k) => OnSelected.InvokeAsync(k); // dropdown 確定
       private Task OnNotFound() => OnFallback.InvokeAsync();                 // ③ 自然言語へ
   }
   ```
2. `Chat.razor`:
   - `OnSelected` → 確定。Day4-5 のエスカレーション分岐（`_step = ShowCandidates` で確定 1 件として扱う）に渡す。`match_strategy="dropdown"` を後で `Inquiry` に記録する前提で変数に持っておく。
   - `OnFallback` → `_step = ChatStep.FreeformInput`。

**完了確認**
- [ ] カテゴリ選択後、その配下の問題名だけがリストに出る（「わからない」経由なら全件）
- [ ] 入力で部分一致フィルタが効く
- [ ] 問題名クリック → 確定ステップへ
- [ ] 「該当なし」クリック → 自然言語入力ステップへ

**詰まったら**
- カテゴリを変えてもリストが古いまま → `OnInitializedAsync` ではなく `OnParametersSetAsync` で読み直す（`CategoryId` 変化に追従）

**AI 依頼テンプレ**: なし（自分で書く範囲。フィルタ強化や仮想化が必要になったら Day4-4 以降で AI に依頼）

---

## Day4-4. 自然言語入力 → `ClassifyService` 結線 [AI]

**目的**
フロー③（[`05:15-24`](../05_search_classification.md)）。利用者の自由入力テキストを `ClassifyService` に渡し、返ってきた候補（ランク済み `KnowledgeEntry` + `match_strategy` + `confidence_score`）を画面に出すところまで結線する。検索ロジック本体は Sprint 2 実装を**呼ぶだけ**で作り直さない。

**前提確認**
- [ ] Day4-3 完了
- [ ] `ClassifyService` のシグネチャを実機で確認（メソッド名・引数・戻り型）。AI 依頼テンプレの該当箇所を実物に合わせて書き換えてから渡す

**AI 依頼テンプレ**
```
backend/Portfolio.Web/Components/Pages/Chat/Chat.razor の FreeformInput ステップを実装してほしい。

前提（実機で確認した実物に合わせて）:
- 既存の ClassifyService（backend/Portfolio.Web/Services/ にある Sprint 2 成果物）を DI で受け取り、
  query(string) + categoryId(Guid?) を渡すと、ランク済み候補リスト + match_strategy + confidence_score を返す。
  ※ 正確なメソッド名・引数・戻り型は実物を確認して合わせること。内部実装は触らない。

要件:
- <InputTextArea> で自然言語入力 + 「検索」ボタン
- ボタンで ClassifyService を呼ぶ（CancellationToken を最後の引数で渡す。await で直接呼ぶ。Task.Run は使わない）
- 呼び出し中はボタン無効化 + "Searching..." 表示
- 返った候補を Chat.razor の状態に格納し、_step = ChatStep.ShowCandidates へ
- 候補 0 件 or 全候補が閾値未満（ClassifyService が空 or low を示す場合）は、Day4-12 で作る「新規問題として」導線に落とせるよう、_step を分けて該当なしフラグを立てる
- match_strategy / confidence_score / categoryId / rawQuery は後続(Day4-9 確認画面・起票)で Inquiry に保存するため、Chat.razor のフィールドに保持しておく
- ClassifyService 呼び出しは ILogger<Chat> で開始/終了をログ（query 本文は INFO で出してよいが PII 配慮のコメントを残す。secret は絶対に出さない）

制約（backend/CLAUDE.md 準拠）:
- @rendermode InteractiveServer 明示済みなので追加不要
- AsNoTracking で読み取り、tenant_id でのフィルタは書かない（RLS が絞る）
- Nullable enable / TreatWarningsAsErrors なので警告を出さないこと
```

**自分の確認ポイント**
- [ ] 入力 → 検索 → 候補が画面に出る
- [ ] LLM フォールバック（⑥）は本 Sprint では結線しない。⑤ で該当なしなら ⑦（未分類キュー、Day4-12）に直結する設計になっているか（[`sprint4_plan.md:89`](../sprint4_plan.md)）
- [ ] `Task.Run` での偽 async になっていない（[`backend/CLAUDE.md`](../../backend/CLAUDE.md)）

---

## Day 1 終了チェックリスト

- [ ] `/t/{slug}/chat` がカテゴリ選択 → コンボボックス → 自然言語入力の 3 ステップで遷移する
- [ ] 「わからない」で `category_id=null`、「該当なし」で自然言語入力へ落ちる
- [ ] 自然言語入力 → `ClassifyService` → 候補が画面に出る（検索本体は呼ぶだけ）
- [ ] `ChatStep` enum と子コンポーネント（`CategoryPicker` / `ProblemCombobox`）の型が確立し、Day2 のエスカレーション分岐を差し込める状態

## Day 2 への引き継ぎメモ

- 確定した `KnowledgeEntry`（dropdown 確定 or 候補選択）を 1 つに収束させる変数を `Chat.razor` に用意した。Day2 はその `AutoResolution` / `GuidanceMessage` の真偽で 3 分岐する。
- `match_strategy` / `confidence_score` / `rawQuery` / `categoryId` を保持済み。Day3 の `Inquiry` 保存で使う。
