# backend/ — Coding rules for .NET 8 + Blazor Server

Scope: this file applies whenever you are editing anything under `backend/`. Global rules in `~/.claude/CLAUDE.md` still apply on top.

## Build / test commands
```bash
dotnet restore Portfolio.sln
dotnet build  Portfolio.sln --configuration Release
dotnet test   Portfolio.sln --configuration Release
dotnet format Portfolio.sln                       # auto-fix style
```

## C# conventions (Microsoft baseline + project additions)
- Target **.NET 8 LTS** only. SDK version pinned in `global.json`.
- `<Nullable>enable</Nullable>` and `<TreatWarningsAsErrors>true</TreatWarningsAsErrors>` are non-negotiable. Don't suppress warnings with `#pragma warning disable` unless there is a written reason on the same line.
- Use **file-scoped namespaces** (`namespace Foo;`) and **primary constructors** (`public sealed class X(IDep dep)`).
- Default to `sealed` for non-abstract classes.
- Prefer `record` / `record struct` for DTOs and value objects.
- Async methods end with `Async` and accept `CancellationToken` as the last parameter.
- Use `ILogger<T>` for logging — no `Console.WriteLine` outside `Program.cs` startup output.

## Blazor / ASP.NET Core
- All interactive components must declare `@rendermode InteractiveServer` explicitly. The render mode is not inherited in .NET 8 Blazor Web App template.
- Routing pages live in `Components/Pages/`. Reusable components live in `Components/Shared/` (create when first needed; don't pre-create empty folders).
- Component parameters: `[Parameter]` for inputs, `[EditorRequired]` if required.
- Inject dependencies with `@inject` in `.razor`, constructor in `.cs`.
- Use `AddHttpClient<TClient, TImpl>` (typed clients) for any outbound HTTP — never `new HttpClient()`.

## EF Core / Postgres
- All queries: **parameterized**. Never string-concatenate SQL.
- Use **`AsNoTracking()`** for read-only queries.
- Migrations live under `Portfolio.Web/Migrations/`. Generate with `dotnet ef migrations add <Name>`. Do not hand-edit applied migrations.
- Multi-tenant queries must filter on `tenant_id` **or** rely on RLS context (see [`design/04_security_multitenant.md`](../design/04_security_multitenant.md)). Never trust client-supplied tenant id; pull it from JWT.
- `pgvector` columns are mapped via Npgsql; use `Vector` type, not raw string.

## Testing
- Test project: `Portfolio.Web.Tests/` (xUnit + `WebApplicationFactory<Program>`).
- One test class per production class; integration tests for endpoints/components.
- Use `WithWebHostBuilder(b => b.UseSetting(...))` to override config; never mutate environment globally.
- DB-touching tests use Testcontainers (when added) or a marked `[Trait("Category","DB")]` so CI can skip in fast lane.

## Security
- Validate inputs only at controller / Razor parameter boundary.
- Never log secrets, JWTs, or full SQL with parameters bound.
- For LLM (Gemini) calls: API key comes from per-tenant Vault — never read from `appsettings.*`.

## Forbidden / avoid
- Newtonsoft.Json (use `System.Text.Json`).
- AutoMapper for new code (manual mapping is fine and explicit).
- Static mutable state outside `Program.cs`.
- `Task.Run` to fake async; mark the method `async` and `await` directly.
