using Microsoft.EntityFrameworkCore;
using Npgsql;
using Portfolio.Web.Components;
using Portfolio.Web.Data;
using Portfolio.Web.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents();

var connectionString = builder.Configuration.GetConnectionString("Postgres")
    ?? throw new InvalidOperationException("ConnectionStrings:Postgres is required.");

var dataSourceBuilder = new NpgsqlDataSourceBuilder(connectionString);
dataSourceBuilder.UseVector();
var dataSource = dataSourceBuilder.Build();

builder.Services.AddDbContext<AppDbContext>(opt =>
    opt.UseNpgsql(dataSource, npg => npg.UseVector()));

var embeddingBaseUrl = builder.Configuration["Embedding:BaseUrl"]
    ?? throw new InvalidOperationException("Embedding:BaseUrl is required.");

builder.Services.AddHttpClient<IEmbeddingClient, EmbeddingClient>(c =>
{
    c.BaseAddress = new Uri(embeddingBaseUrl);
    c.Timeout = TimeSpan.FromSeconds(60);
});

builder.Services.AddHealthChecks();

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
    app.UseHsts();
}

app.UseStaticFiles();
app.UseAntiforgery();

app.MapHealthChecks("/healthz");

app.MapRazorComponents<App>()
    .AddInteractiveServerRenderMode();

app.Run();

public partial class Program;
