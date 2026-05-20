# ASP.NET Core 基礎ノート

個人的な学習メモ。概念を自分の言葉で整理する場所。

---

## エントリポイントとアプリの起動フロー

`Program.cs` がアプリの出発点（エントリポイント）。大きく2フェーズに分かれる。

```
Program.cs
  │
  ├─ [builder フェーズ] ─────────────────────────────────────
  │    WebApplication.CreateBuilder(args) でスタート。
  │    builder.Services.AddXxx() でサービスを DI コンテナに登録する。
  │    「誰かが AppDbContext を必要としたら、こうやって作って渡せ」という
  │    レシピ帳を作っているイメージ。
  │    builder.Build() を呼ぶまで実際には何も動かない。
  │
  ├─ var app = builder.Build() ─────────────────────────────
  │    DI コンテナが確定し、WebApplication（app）のインスタンスが作られる。
  │    app がないと UseXxx / MapXxx を呼べないので、必ずここが先。
  │
  ├─ [app フェーズ] ──────────────────────────────────────────
  │    app.UseXxx() でミドルウェアパイプラインを組み立てる。
  │    内部では UseMiddleware<T> が呼ばれ、関数の入れ子が順番に積まれる。
  │    呼んだ順番 = パイプラインの実行順番。
  │
  │    UseAuthentication(          ← 外側から順に実行される
  │        UseAuthorization(
  │            UseAntiforgery(
  │                MapRazorComponents() ← 最終的な処理
  │            )
  │        )
  │    )
  │
  │    各ミドルウェアは next(ctx) を呼ぶかどうかを自分で決める。
  │    呼ばなければそこで止まる（401 返して終わりなど）。
  │
  │    app.MapXxx() でルーティング（URL と処理の対応）を登録する。
  │
  └─ app.Run() ───────────────────────────────────────────────
       サーバーが起動してリクエストの待ち受けを開始する。
       入れ子のパイプラインがここで確定する。
       以降はリクエストが来るたびに外側から順に実行される。
       この行で処理が止まり続ける（返ってこない）。
```

---

## ミドルウェアパイプライン

HTTP リクエストが来てからレスポンスを返すまでに通過する「関所の連鎖」。
`app.UseXxx()` を書いた**順番通り**に通過する。

```
クライアント
    │
    │  HTTP リクエスト（GET /t/foo/categories）
    ▼
┌─────────────────────────────┐
│ UseStaticFiles              │ → CSS/JS/画像ならここで完結。以降はスキップ。
├─────────────────────────────┤
│ UseAuthentication           │ → Authorization ヘッダの JWT を検証する。
│                             │   成功すると HttpContext.User に誰かが入る。
│                             │   失敗しても止まらず次に進む（Userが空のまま）。
├─────────────────────────────┤
│ UseAuthorization            │ → [Authorize] 属性が付いたページにアクセスしようと
│                             │   しているとき、User が空なら 401 を返して止める。
├─────────────────────────────┤
│ UseAntiforgery              │ → フォーム送信の偽造（CSRF）を防ぐ。
│                             │   Blazor の SignalR ハンドシェイクでも使われる。
│                             │   User が確定した後でないと正しく動かないので
│                             │   UseAuthentication より後に置く必要がある。
├─────────────────────────────┤
│ MapHealthChecks("/healthz") │ → /healthz なら 200 OK を返して完結。
├─────────────────────────────┤
│ MapRazorComponents          │ → URL に対応する .razor ページを探して実行する。
│                             │   ここで初めて C# のページ処理が動く。
└─────────────────────────────┘
    │
    │  HTTP レスポンス（HTML / JSON）
    ▼
クライアント
```

**ポイント**: 途中のミドルウェアが「ここで終わり」と判断したら、以降はスキップされる。
例: 静的ファイルが見つかれば `UseStaticFiles` で完結し、認証処理すら走らない。

---

## Blazor Server の通信フロー

### 全体の流れ

```
① HTTP GET（最初の1回）
   ブラウザ → サーバー: GET /t/foo/categories
   パイプライン全部通る（UseAuthentication → UseAuthorization → UseAntiforgery）
   サーバー → ブラウザ: HTML の骨格 + CSS + JS + 新しいトークン埋め込み済み

② SignalR ハンドシェイク（WebSocket への切り替え交渉）
   ブラウザ → サーバー: 「WebSocket に切り替えていい？」+ トークン
   UseAntiforgery: トークンが一致するか確認（CSRF 防止）
   サーバー → ブラウザ: 「いいよ」（101 Switching Protocols）

③ WebSocket 確立（以降ずっとここ）
   ユーザーがボタンを押す
     → WebSocket で「ボタンが押された」をサーバーに送る
     → サーバーで C# のイベント処理が走る（DB を引くなど）
     → 変わった部分の差分だけ WebSocket で返す
     → ブラウザが差分だけ更新（ページ全体は再読み込みしない）
```

### リロード時

WebSocket を切断して HTTP GET からやり直す。JWT 再検証・新しいトークン発行・ハンドシェイクをすべてやり直す。JWT の有効期限が切れた状態でリロードすると `UseAuthentication` で弾かれてログインページへ飛ぶ。

### パイプラインが動くタイミング

| タイミング | パイプライン | 何を確認するか |
|---|---|---|
| HTTP リクエスト（最初・リロード） | 動く | JWT 検証・トークン確認 |
| SignalR ハンドシェイク | 動く | トークン確認（CSRF 防止） |
| WebSocket 通信中（Razor 間移動など） | 動かない | `[Authorize]`（認証済みか）のみ |

### `[Authorize]` の役割

JWT の再検証はしない。「User.IsAuthenticated が true か」だけを確認する門番。

```
UseAuthentication ← JWT を検証して User を確定する（検証はここ）
[Authorize]       ← User.IsAuthenticated が true か確認するだけ
                    true  → 通す
                    false → 401 / ログインページへ
```

### wwwroot が HTTP である理由

CSS・JS は WebSocket が確立する前に必要。ブラウザが HTTP で要求してくるので HTTP で返すしかない。WebSocket にはリクエストごとの HTTP ヘッダがないため、ブラウザが HTTP で要求するものは HTTP で返す以外に方法がない。

```
① HTTP GET → HTML + CSS + JS を取得（この時点で WebSocket はまだない）
② ハンドシェイク → WebSocket 確立
③ WebSocket → Blazor の処理が始まる
```

### セキュリティの多層構造

```
JWT 偽造を試みる
  → Supabase の秘密鍵が必要（外から取れない）→ 無理

DB に直接接続する
  → portfolio_app は NOBYPASSRLS
  → SET LOCAL app.tenant_id が未発行 → 全テーブル 0 行

偽造 JWT でアクセスする
  → UseAuthentication が署名検証で弾く
```

---

## エンドポイント

### 種類

| 種類 | 例 | コンテンツ |
|---|---|---|
| 自作エンドポイント | `MapGet` / `MapPost` / `MapRazorComponents` | 自分で書く |
| ライブラリ提供 | `MapHealthChecks` / `UseSwagger` | ライブラリが用意 |
| ファイルそのまま | `UseStaticFiles` | `wwwroot` フォルダの中身 |

### wwwroot と Razor ページの違い

| | `wwwroot` | `Components/Pages/` |
|---|---|---|
| 認証 | 常になし | `[Authorize]` を付けた場合のみ |
| 実行場所 | ブラウザ | サーバー |
| 中身 | 静的ファイル（CSS・JS・画像） | Razor コンポーネント |
| アクセス | URL 直打ちで誰でも取得可能 | `@page` で登録した URL のみ |

`wwwroot` の外（DB・接続文字列・C# コード）は `UseStaticFiles` 経由では絶対に取れない。

### Razor ページのルーティング

URL はファイル名ではなく `@page` ディレクティブが決める。

```razor
@page "/t/{Slug}/categories"   ← この行が URL を決める
@attribute [Authorize]          ← これがないと誰でもアクセスできる
```

`MapRazorComponents<App>()` を書いた時点で Blazor が全 `.razor` をスキャンし、
`@page` を持つものをルーティングテーブルに自動登録する。

### ファイルの置き場所

必須ではなく慣習。機能ごとにフォルダを分けると見つけやすくなる。

```
Components/Pages/
  Categories/
    Index.razor    ← 一覧  @page "/t/{Slug}/categories"
    Create.razor   ← 作成  @page "/t/{Slug}/categories/new"
    Edit.razor     ← 編集  @page "/t/{Slug}/categories/{Id:guid}/edit"
  Knowledge/
    Index.razor
    Create.razor
```

URL は `@page` が決めるので、ファイルの置き場所を変えても動作は変わらない。

### REST API エンドポイントを追加する場合

Blazor Server と REST API は同じプロジェクトに共存できる。

```csharp
// Program.cs に追加するだけ
app.MapGet("/api/categories", async (AppDbContext db) =>
    await db.Categories.ToListAsync());

app.MapPost("/api/categories", async (Category item, AppDbContext db) =>
{
    db.Categories.Add(item);
    await db.SaveChangesAsync();
    return Results.Created($"/api/categories/{item.Id}", item);
});
```

| | Razor | MapGet / MapPost |
|---|---|---|
| 返す形式 | HTML | JSON |
| 用途 | ブラウザで表示 | モバイルアプリ・外部サービス連携 |

このプロジェクトでは Phase 2 の `embed.js`（埋め込みウィジェット）のタイミングで必要になる予定。

### Blazor Server では MapPost が不要な理由

Blazor Server はサーバー側で UI も処理も両方持つ。フォーム送信も `.razor` の中で
直接 DB を叩けるので、API エンドポイントを別途作る必要がない。

```razor
@code {
    private async Task OnSubmit()
    {
        // API を経由せず直接 DB に書く
        Db.Categories.Add(new Category { ... });
        await Db.SaveChangesAsync();
    }
}
```

`MapPost` が必要になるのは React・Vue など別のフロントエンドから API を叩く構成のとき。

---

## DI（依存性注入）

### 概念

クラスが必要な部品（依存）を、自分で `new` するのではなく外から渡してもらう仕組み。

```csharp
// ❌ 自分で new する（依存性注入を使わない場合）
public class MyService
{
    private readonly AppDbContext _db = new AppDbContext(...); // 自分で作る
}

// ✅ DI を使う
public class MyService(AppDbContext db)  // 引数で受け取る
{
    // db は ASP.NET Core が作って渡してくれる
}
```

### 登録（Program.cs）

```csharp
builder.Services.AddDbContext<AppDbContext>(...);       // AppDbContext の作り方を登録
builder.Services.AddHttpContextAccessor();              // IHttpContextAccessor を登録
builder.Services.AddHttpClient<IEmbeddingClient, EmbeddingClient>(...); // 自作クラスも登録できる
```

### 受け取り方

```csharp
// C# クラス: コンストラクタ引数に書くだけ（属性不要）
public sealed class TenantResolutionMiddleware(AppDbContext db, IHttpContextAccessor http)
{
    // db と http は自動で渡ってくる
}
```

```razor
@* Razor ファイル: @inject を使う *@
@inject AppDbContext Db
@inject NavigationManager Nav

@code {
    protected override async Task OnInitializedAsync()
    {
        var items = await Db.Categories.ToListAsync(); // Db は DI から来ている
    }
}
```

### ライフタイム（インスタンスの寿命）

登録方法によって、インスタンスをいつ作っていつ捨てるかが変わる。

```csharp
// 毎回新しいインスタンスを作る
builder.Services.AddTransient<MyService>();

// リクエスト1本につき1インスタンス（同じリクエスト内では使い回す）
builder.Services.AddScoped<MyService>();

// アプリ起動から終了まで1インスタンス（全リクエストで使い回す）
builder.Services.AddSingleton<MyService>();
```

`AddDbContext` は内部で `Scoped` を使っている。「1リクエスト = 1DB接続」にするため。

**登録できないもの（事実上無意味なもの）**
- `static` クラス → インスタンスを作る概念がないので登録不要
- `int` や `string` などのプリミティブ型 → できるが使う場面がない

---

### 仕組み

```
Program.cs で登録（レシピ帳に追加）
       ↓
リクエストが来たとき、ASP.NET Core がクラスをインスタンス化
       ↓
コンストラクタの引数の型を DI コンテナで検索
       ↓
登録済み → 作って渡す
未登録   → 起動時エラー
```

---

## ミドルウェアとコンポーネントの違い

| | ミドルウェア | コンポーネント |
|---|---|---|
| 何をするか | リクエスト横断の処理 | 画面の部品 |
| 適用範囲 | 全リクエストに影響 | 特定のページ・部品 |
| 登録方法 | `app.UseMiddleware<T>()` | `.razor` ファイルを作るだけ |
| 例 | JWT 検証、テナント解決 | 一覧ページ、ボタン、フォーム |

---

## Blazor Server の思想

### 従来の Web（HTML + CSS + JS）との比較

```
従来の構成
  ブラウザ: HTML を表示 + CSS でスタイル + JS で UI ロジックを動かす
  ネットワーク: API 呼び出し（fetch / axios）
  サーバー: データ処理・API を返すだけ
  → フロントとバックで言語が分かれる（JS + サーバー側言語）
  → 状態管理がブラウザとサーバーで分散する

Blazor Server
  ブラウザ: 差分の適用だけ（JS は SignalR 接続維持の最小限のみ）
  WebSocket: 常時接続（ユーザー操作をサーバーに送り、差分を受け取る）
  サーバー: UI ロジック + データ処理 全部ここ（C# だけ）
  → フロントもバックも C# で書ける
  → 状態はサーバーに集中する
```

### なぜ Blazor Server を選んだか

「フロントでやる処理を WebSocket を活かしてサーバーに引き込んだ」設計。JS を書かずに C# だけでフルスタック開発できる。

トレードオフ:
- ユーザーが増えると WebSocket 接続をサーバーが全部抱えるのでメモリ負荷が高くなる
- 大規模向きではなく、社内ツール・管理画面のような用途に向いている
- このプロジェクト（社内ナレッジ起票補助）はちょうどその用途

### Razor と JS の役割の違い

| | 従来（JS） | Blazor Server（Razor） |
|---|---|---|
| UI ロジックの実行場所 | ブラウザ | サーバー |
| データ取得 | fetch / API 呼び出し | DB に直接アクセス |
| DOM 更新 | JS が直接操作 | サーバーが差分を送り、ブラウザが適用 |
| 言語 | フロント JS + バック別言語 | C# だけ |
| 状態管理 | ブラウザ側で管理 | サーバー側で管理 |

---

## .razor ファイル

C# に HTML を混ぜて書けるファイル形式。ビルド時に普通の C# クラスに変換される。

```razor
@page "/t/{Slug}/categories"   ← このコンポーネントの URL
@inject AppDbContext Db         ← DI からもらう

<h1>Categories</h1>
<p>テナント: @Slug</p>          ← @ で C# 変数を HTML に埋め込む

@if (_items is null)            ← @ で C# の制御構文
{
    <p>読み込み中...</p>
}

@code {
    [Parameter] public string Slug { get; set; } = "";  ← URL の {Slug} が入る
    private List<Category>? _items;

    protected override async Task OnInitializedAsync()
    {
        _items = await Db.Categories.ToListAsync();
    }
}
```

### `@` の意味

| 書き方 | 意味 |
|---|---|
| `@inject Type Name` | DI からインスタンスをもらう |
| `@page "/path"` | このコンポーネントの URL を指定する |
| `@code { }` | C# コードブロック |
| `@variable` | C# 変数を HTML に埋め込む |
| `@if / @foreach` | C# の制御構文を HTML の中で使う |
