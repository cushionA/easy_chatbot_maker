using Microsoft.AspNetCore.Mvc.Testing;
using Xunit;

namespace Portfolio.Web.Tests;

public class HealthTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> _factory;

    public HealthTests(WebApplicationFactory<Program> factory)
    {
        _factory = factory.WithWebHostBuilder(b =>
        {
            b.UseSetting("Embedding:BaseUrl", "http://localhost:9999");
            b.UseSetting("ConnectionStrings:Postgres", "Host=localhost;Database=test;Username=test;Password=test");
        });
    }

    [Fact]
    public async Task Healthz_returns_200()
    {
        var client = _factory.CreateClient();
        var resp = await client.GetAsync("/healthz");
        Assert.Equal(System.Net.HttpStatusCode.OK, resp.StatusCode);
    }
}
