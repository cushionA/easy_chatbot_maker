using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;
using Npgsql;
using Portfolio.Web.Components;
using Portfolio.Web.Data;
using Portfolio.Web.Services;

// ===== builder フェーズ =====
// WebApplication.CreateBuilder でホスト設定を組み立てる。
// builder.Build() を呼ぶまで実際のサービスは起動しない。
//
// 【DI（依存性注入）とは】
// クラスが必要とする部品（依存）を、自分で new するのではなく外から渡してもらう仕組み。
// 例: DbContext が必要なコンポーネントは「自分で new AppDbContext()」しない。
//     ASP.NET Core が「必要になったら作って渡す」ことを引き受けてくれる。
//
// builder フェーズでやること:
//   「〇〇が必要と言われたら、△△をこうやって作って渡してくれ」という設定を
//   DI コンテナ（builder.Services）に登録する。
//   実際にインスタンスが作られるのは、リクエストが来たときに必要になってから。
//
// 【受け取る側の例】
//   Razor:  @inject AppDbContext Db          → Db.Categories.ToListAsync() で使える
//   C#:     MyClass(AppDbContext db) { ... } → コンストラクタ引数に自動で渡される
//   ※ここで AddDbContext<AppDbContext> を登録しているから、受け取る側が動く。

var builder = WebApplication.CreateBuilder(args);

// ----- 認証（Authentication）-----
// 「この人は誰か」を確認する仕組みを登録する。
// JwtBearerDefaults.AuthenticationScheme = "Bearer" を既定のスキームに設定。
// リクエストの Authorization: Bearer <token> ヘッダを自動で読む。
builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        var supa = builder.Configuration.GetSection("Supabase");

        // Authority: JWT を発行した認証サーバーの URL。
        // ASP.NET Core はここから /.well-known/openid-configuration を取得しようとする。
        options.Authority = supa["Issuer"];

        // Audience: このアプリ向けに発行されたトークンかを確認する値。
        // Supabase は "authenticated" を使う。
        options.Audience = supa["Audience"];

        // MetadataAddress: Supabase は Authority とは別の URL に JWKS（公開鍵一覧）を置くため明示する。
        // これがないと Authority + /.well-known/openid-configuration を試みて 404 になる。
        options.MetadataAddress = supa["JwksUrl"]
            ?? throw new InvalidOperationException("Supabase:JwksUrl is required.");

        options.TokenValidationParameters = new TokenValidationParameters
        {
            // 発行者（iss クレーム）が Authority と一致するか確認する。
            ValidateIssuer = true,
            // 受信者（aud クレーム）が Audience と一致するか確認する。
            ValidateAudience = true,
            // トークンの有効期限（exp クレーム）が切れていないか確認する。
            ValidateLifetime = true,
            // 署名を JWKS の公開鍵で検証する。改ざん検知の核心。
            ValidateIssuerSigningKey = true,
            // サーバー時刻のズレを 30 秒まで許容する。
            // 0 にすると期限ぎりぎりのトークンが即拒否されることがある。
            ClockSkew = TimeSpan.FromSeconds(30),
        };
    });

// ----- 認可（Authorization）-----
// 「この人はこの操作をしていいか」を確認する仕組みを登録する。
// Authentication（本人確認）とは別物。[Authorize] 属性を使うために必要。
builder.Services.AddAuthorization();

// IHttpContextAccessor を DI に登録する。
// ミドルウェア外（サービス・インターセプタ）から現在のリクエスト情報（テナント ID 等）を
// 取り出すために使う。後続の TenantConnectionInterceptor が依存する。
builder.Services.AddHttpContextAccessor();

// ----- Blazor Server -----
// Razor コンポーネント（.razor ファイル）を使う UI エンジンを登録する。
// AddInteractiveServerComponents で SignalR 経由のリアルタイム通信も有効になる。
builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents();

// ----- DB 接続 -----
// 接続文字列は appsettings には書かない（秘匿値）。
// 優先順位:
//   1) ConnectionStrings__Postgres 環境変数（本番・CI）
//   2) SUPABASE_DB_URL_APP 環境変数（.env.local をロードした開発環境）
// どちらもなければ起動時にクラッシュさせて設定漏れを即検知する。
var connectionString = ToNpgsqlConnectionString(
    builder.Configuration.GetConnectionString("Postgres")
    ?? Environment.GetEnvironmentVariable("SUPABASE_DB_URL_APP")
    ?? throw new InvalidOperationException("DB 接続文字列が未設定。SUPABASE_DB_URL_APP を .env.local に設定してください。"));

// NpgsqlDataSourceBuilder でベクトル型（pgvector）を有効にした接続ソースを作る。
// UseVector() を呼ばないと Vector 型のカラムを読み書きできない。
var dataSourceBuilder = new NpgsqlDataSourceBuilder(connectionString);
dataSourceBuilder.UseVector();
var dataSource = dataSourceBuilder.Build();

// EF Core の AppDbContext を DI に登録する。
// Scoped = HTTP リクエスト 1 本につき 1 インスタンス。リクエストが終わると Dispose される。
builder.Services.AddDbContext<AppDbContext>(opt =>
    opt.UseNpgsql(dataSource, npg => npg.UseVector()));

// ----- Embedding サービス -----
// FastAPI の Embedding サーバーの URL を設定から読む。
var embeddingBaseUrl = builder.Configuration["Embedding:BaseUrl"]
    ?? throw new InvalidOperationException("Embedding:BaseUrl is required.");

// IEmbeddingClient を「型付き HttpClient」として登録する。
// new HttpClient() を直接使うと接続プールが枯渇するリスクがある。
// AddHttpClient<TClient, TImpl> を使うと ASP.NET Core が適切に管理してくれる。
builder.Services.AddHttpClient<IEmbeddingClient, EmbeddingClient>(c =>
{
    c.BaseAddress = new Uri(embeddingBaseUrl);
    c.Timeout = TimeSpan.FromSeconds(60);
});

// /healthz エンドポイント用。Docker の HEALTHCHECK や監視ツールが叩く。
builder.Services.AddHealthChecks();

// ここで builder フェーズ終了。DI コンテナが確定し、app（実際のサーバー）が作られる。
var app = builder.Build();

// ===== ミドルウェアパイプライン =====
// HTTP リクエストは上から順にミドルウェアを通過し、レスポンスは逆順に戻る。
// 登録順が重要: 後のミドルウェアは前のミドルウェアが設定した情報に依存できる。

if (!app.Environment.IsDevelopment())
{
    // 本番環境のみ: 未処理例外を /Error ページに転送する。
    app.UseExceptionHandler("/Error");
    // 本番環境のみ: HTTPS を強制する Strict-Transport-Security ヘッダを付与する。
    app.UseHsts();
}

// CSS・JS・画像などの静的ファイルをそのままレスポンスする。
// 認証不要なので UseAuthentication の前に置く（処理を短絡できる）。
app.UseStaticFiles();

// JWT トークンを検証し、HttpContext.User（ユーザー情報）を確定する。
// これより後のミドルウェアは ctx.User.Identity.IsAuthenticated を信頼できる。
app.UseAuthentication();

// [Authorize] 属性のチェックを行う。
// UseAuthentication が先に User を確定していないと、常に未認証扱いになる。
app.UseAuthorization();

// Blazor の CSRF 対策（フォーム送信の偽造防止）。
// UseAuthentication/UseAuthorization の後に置く理由:
// Blazor Server の SignalR ハンドシェイク時に User が確定している必要があるため。
app.UseAntiforgery();

// /healthz に GET すると 200 OK を返す。認証不要。
app.MapHealthChecks("/healthz");

app.MapGet("/whoami", (HttpContext ctx) => ctx.User.Identity?.Name ?? "(no name)").RequireAuthorization();

// Blazor の Razor コンポーネントをルーティングに登録する。
// InteractiveServer = SignalR で UI 更新をリアルタイムに行うモード。
app.MapRazorComponents<App>()
    .AddInteractiveServerRenderMode();

app.Run();

// Supabase/クラウド系は postgresql:// URL 形式で接続文字列を配るが、
// Npgsql はキーワード形式しか受け付けないので詰め替える。
static string ToNpgsqlConnectionString(string raw)
{
    if (!raw.StartsWith("postgresql://") && !raw.StartsWith("postgres://"))
    {
        return raw; // 既にキーワード形式
    }

    var uri = new Uri(raw);
    var userInfo = uri.UserInfo.Split(':', 2);
    var b = new NpgsqlConnectionStringBuilder
    {
        Host = uri.Host,
        Port = uri.Port,
        Username = Uri.UnescapeDataString(userInfo[0]),
        Password = userInfo.Length > 1 ? Uri.UnescapeDataString(userInfo[1]) : null,
        Database = uri.AbsolutePath.TrimStart('/'),
        SslMode = SslMode.Require,
    };
    return b.ConnectionString;
}

// テストプロジェクトが WebApplicationFactory<Program> でこのアプリを起動するための宣言。
// partial にすることで Program クラスをテスト側から参照できる。
public partial class Program;
