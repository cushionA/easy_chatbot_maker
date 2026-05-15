# Sprint 1 Day 3 作業指示書（2026-05-19）

> テーマ: **最初の画面と CRUD**
> 完了時の状態: `/t/{slug}/categories` で一覧/作成/編集が動き、Excel 取込でデモテナントのデータが画面に出る
> 推定所要: 5〜7 時間

---

## Day3-1. ルーティングを `/t/{slug}/...` 形式に整える

**目的**
URL に `slug` が必須なルーティングに切り替え、Day2-3 のミドルウェアが意味を持つ状態にする。既存 `Home.razor` はデバッグ用に退避。

**自分で書く理由**
URL 設計はサービスの顔。後から変更すると影響範囲が広い。

**前提確認**
- [ ] Day 2 完了
- [ ] `design/04_security_multitenant.md:148-155`（URL 設計）を読んだ

**手順**
1. `Components/Pages/Home.razor` の `@page "/"` を `@page "/t/{Slug}/_debug/embedding"` に変更
   ```razor
   @page "/t/{Slug}/_debug/embedding"
   @code {
       [Parameter] public string Slug { get; set; } = "";
   }
   ```
2. 新規 `Components/Pages/Landing.razor` を `@page "/"` で作成し、簡単な「ログインして /t/{slug}/chat へ」案内 + 自分が所属するテナント一覧リンクを表示
3. `Components/Layout/MainLayout.razor` を改装:
   - `[Parameter, SupplyParameterFromQuery]` ではなく、URL から `slug` を `CascadingParameter` 的に下に流す方法を選ぶ
   - MVP では各ページで `[Parameter] string Slug` を受ける単純実装で十分
   - sidebar に `Chat` / `Categories` / `Knowledge` / `Settings` の 4 リンクを置く（実体は今日 Category だけ）

**完了確認**
- [ ] `/` → ランディング
- [ ] `/t/tenant-a/_debug/embedding` → Embedding 動作確認画面（認証 + 所属チェック後）

---

## Day3-2. Category 一覧ページ `/t/{Slug}/categories`

**目的**
RLS が UI 経由でも効いていることを目視確認できる最初のページ。

**前提確認**
- [ ] Day3-1 完了
- [ ] Day1-4 で投入した手動データが残っている

**手順**
1. 新規 `Components/Pages/Categories/Index.razor`:
   ```razor
   @page "/t/{Slug}/categories"
   @attribute [Authorize]
   @inject AppDbContext Db
   @inject NavigationManager Nav

   <h2>Categories</h2>
   <a href="/t/@Slug/categories/new">+ New</a>

   @if (_rows is null) { <p>Loading...</p> }
   else
   {
       <table>
           <thead><tr><th>Name</th><th>Description</th><th>Order</th><th></th></tr></thead>
           <tbody>
           @foreach (var c in _rows)
           {
               <tr>
                   <td>@c.Name</td>
                   <td>@c.Description</td>
                   <td>@c.DisplayOrder</td>
                   <td><a href="/t/@Slug/categories/@c.Id/edit">Edit</a></td>
               </tr>
           }
           </tbody>
       </table>
   }

   @code {
       [Parameter] public string Slug { get; set; } = "";
       private List<Category>? _rows;

       protected override async Task OnInitializedAsync()
       {
           _rows = await Db.Categories.OrderBy(c => c.DisplayOrder).ToListAsync();
       }
   }
   ```
   **重要**: `WHERE tenant_id = ?` を書かない。RLS が絞るのを目視確認したい。

**完了確認**
- [ ] `/t/tenant-a/categories` でテナント A のカテゴリのみ表示
- [ ] `/t/tenant-b/categories` でテナント B のカテゴリのみ表示
- [ ] 別テナントの slug で 403（ミドルウェアの仕事）

**詰まったら**
- 全テナント分のデータが見える → `SET LOCAL` が効いていない、Day2-4 へ戻る
- 0 件しか見えない → `SET LOCAL` 未発行で接続している可能性。`HttpContext.Items["TenantId"]` がページに届いているかブレークポイントで確認

---

## Day3-3. Category 作成ページ `/t/{Slug}/categories/new`

**目的**
**Blazor `EditForm` のお手本となる最初の 1 ページ**を自分の手で書く。これが Knowledge / FieldDefinition で AI に複製させるテンプレになる。

**自分で書く理由**
バリデーション + 保存 + リダイレクト + RLS 適用の最初の組み合わせ。説明責任を負う部分。

**前提確認**
- [ ] Day3-2 完了
- [ ] `Data/Entities/Category.cs` のフィールドを確認

**手順**
1. 新規 `Components/Pages/Categories/Create.razor`:
   ```razor
   @page "/t/{Slug}/categories/new"
   @attribute [Authorize]
   @inject AppDbContext Db
   @inject NavigationManager Nav
   @inject IHttpContextAccessor Http

   <h2>New category</h2>

   <EditForm Model="_form" OnValidSubmit="OnSubmit" FormName="category-new">
       <DataAnnotationsValidator />
       <ValidationSummary />

       <div>
           <label>Name *</label>
           <InputText @bind-Value="_form.Name" />
       </div>
       <div>
           <label>Description</label>
           <InputTextArea @bind-Value="_form.Description" />
       </div>
       <div>
           <label>Display order</label>
           <InputNumber @bind-Value="_form.DisplayOrder" />
       </div>
       <button type="submit">Save</button>
       <a href="/t/@Slug/categories">Cancel</a>
   </EditForm>

   @code {
       [Parameter] public string Slug { get; set; } = "";
       [SupplyParameterFromForm] private FormModel _form { get; set; } = new();

       private sealed class FormModel
       {
           [Required, StringLength(100)]
           public string Name { get; set; } = "";
           [StringLength(500)]
           public string? Description { get; set; }
           public int DisplayOrder { get; set; }
       }

       private async Task OnSubmit()
       {
           // tenant_id は RLS の WITH CHECK で current_setting と一致が必須。
           // HttpContext.Items から取得する（middleware が入れている）。
           var tenantId = (Guid)Http.HttpContext!.Items["TenantId"]!;
           Db.Categories.Add(new Category
           {
               Id = Guid.NewGuid(),
               TenantId = tenantId,
               Name = _form.Name,
               Description = _form.Description,
               DisplayOrder = _form.DisplayOrder,
           });
           await Db.SaveChangesAsync();
           Nav.NavigateTo($"/t/{Slug}/categories");
       }
   }
   ```

**完了確認**
- [ ] 正常系: 作成 → 一覧に新規行
- [ ] バリデーション: 空 Name で `ValidationSummary` に赤字
- [ ] テナント越境: ブラウザ DevTools で別テナントの `TenantId` を inject しても、`WITH CHECK` で DB が拒否（500 になるが OK、Day3-4 でハンドリング）

**詰まったら**
- `Items["TenantId"]` が null → ページが `/t/{Slug}/...` パターン外で呼ばれている、または middleware の順序が `MapRazorComponents` の後になっている
- `WITH CHECK` 違反で 500 → 期待動作。エラーハンドリングは Day3-4 でまとめて

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## Day3-4. Category 編集ページ `/t/{Slug}/categories/{Id:guid}/edit` [AI 委譲]

**目的**
お手本 `Create.razor` を複製して編集用に変形する作業を AI に投げる。複製パターンを確立しておけば、Knowledge / FieldDefinition も同じ依頼で増やせる。

**前提確認**
- [ ] Day3-3 完了、`Create.razor` がローカルで動く

**AI 依頼テンプレ**
```
backend/Portfolio.Web/Components/Pages/Categories/Create.razor をベースに、編集用ページ Edit.razor を書いてほしい。

仕様:
- ルート: /t/{Slug}/categories/{Id:guid}/edit
- OnInitializedAsync で Db.Categories.FindAsync(Id) して FormModel を埋める
- 見つからなければ NotFound (404) を返す
- フォームの構成は Create.razor と同じ（Name / Description / DisplayOrder）
- 保存ボタンで Update → 一覧へリダイレクト
- 楽観ロック（RowVersion 列がエンティティにあれば DbUpdateConcurrencyException をキャッチして UI にメッセージ表示）

エラーハンドリングも入れて:
- DbUpdateException（RLS の WITH CHECK 違反含む）→ "Save failed: ..." と画面上にメッセージ
- DbUpdateConcurrencyException → "Conflicted with concurrent edit, please reload" メッセージ + リロードボタン

Create.razor 側にも同様のエラーハンドリングを反映してほしい。
```

**自分の確認ポイント**
- [ ] 編集 → 保存 → 一覧に反映
- [ ] 別ブラウザで開いて片方を保存後、もう片方が conflict メッセージを出す（RowVersion が無ければスキップ可）
- [ ] 別テナントの URL の id を踏むと 404（RLS で見えないので Find が null）

---

## Day3-5. Excel 取込スクリプト [AI 一次実装 → 自分レビュー]

**目的**
採用面接で見せるデモテナントを 1 コマンドで作れるようにする。既存 Streamlit 版の `data.xlsx` を流用する。

**前提確認**
- [ ] Day3-4 完了
- [ ] 既存 Streamlit 版の `data.xlsx` の場所と中身を把握（[`design/10_existing_streamlit.md`](../10_existing_streamlit.md)）

**自分が先に決めること**
- [ ] デモテナント名と slug（例: `acme` / `demo` など、採用面接で説明しやすいもの）
- [ ] デモユーザー（自分自身の Supabase Auth ユーザー）の admin 権限を付ける

**AI 依頼テンプレ**
```
.NET 8 コンソールアプリ `backend/Portfolio.Tools.Seed` を新規プロジェクトとして作ってほしい。

要件:
- Portfolio.sln に追加
- 引数: --file <xlsx path> --tenant-slug <slug> --tenant-name <name> --admin-user-id <guid>
- ClosedXML で Excel を読む（依存追加）
- シート構成は data.xlsx 既存仕様に従う（categories / knowledge_entries の 2 シート想定。実物を見て確認してから決めて）
- 動作:
  1. owner 接続（SUPABASE_DB_URL_OWNER）で BeginTransaction
  2. tenants に INSERT（slug 一意制約に注意、既存なら ID 取得して続行）
  3. user_tenants に admin 行を INSERT（role='admin'）
  4. categories を XLSX から一括 INSERT
  5. knowledge_entries を XLSX から一括 INSERT
  6. 各 knowledge_entry について embedding サービス（http://localhost:9000/embed, mode=passage）を呼んで embedding 列を埋める
  7. Commit
- embedding 呼び出しは並列度 4 でバッチ化（HttpClient で）
- ログは Microsoft.Extensions.Logging で進捗を 100 件ごとに出力
- --dry-run で実 INSERT せず件数だけ出力するモードも追加

注意:
- owner 接続なので RLS は無関係だが、tenant_id を全レコードに明示的に埋めること
- パスワードは環境変数 SUPABASE_DB_URL_OWNER から読む
- API キーや秘匿情報を含む xlsx の取り扱いは想定外で良い
```

**自分の確認ポイント**
- [ ] `--dry-run` で件数が合う
- [ ] 本実行後、`/t/acme/categories` に Excel のカテゴリが見える
- [ ] knowledge_entries の `embedding` 列が NULL でない
- [ ] embedding 呼び出しが `mode=passage` になっている（**重要**: 検索品質の根幹）

**詰まったら**
- embedding が `query:` プレフィクスになっている → `embedding/app/embedder.py` の修正がまだなら先にそちらを直す（[`reviews/04_current_deliverable_review.md:161-168`](../../reviews/04_current_deliverable_review.md)）
- ClosedXML が複合主キー的なシートでパースに失敗 → シートの先頭行をヘッダとして固定する仕様で AI に再依頼

---

## Day 3 終了チェックリスト

- [ ] `/t/{slug}/categories` の一覧/作成/編集 3 ページが動く
- [ ] 別テナント URL を踏むと 403、別テナントの id を直接踏むと 404
- [ ] Excel 取込でデモテナントが作成され、一覧画面に出る
- [ ] knowledge_entries に `passage:` プレフィクスで embedding が入っている
- [ ] **「Create.razor を見せて『同じパターンで Knowledge も書いて』で AI が複製できる**」状態になった

## Sprint 1 完走後の状態

Sprint 1 ゴール（`design/README.md:64` の 7 項目）の達成度:
- (1) Supabase プロジェクト: ✅
- (2) `0002_rls_roles.sql`: ✅
- (3) `0003_rls_policies.sql`: ✅
- (4) JwtBearer + テナント解決ミドルウェア: ✅
- (5) `DbConnectionInterceptor`: ✅
- (6) Category / Knowledge / FieldDefinition の最小 CRUD: **Category は ✅**、Knowledge と FieldDefinition は次セッションで AI に複製依頼するだけ
- (7) Excel 取込: ✅

次は Sprint 2: **分類フロー本体**（[`05_search_classification.md`](../05_search_classification.md)）に着手。
