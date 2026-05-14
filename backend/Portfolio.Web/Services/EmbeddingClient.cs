using System.Net.Http.Json;

namespace Portfolio.Web.Services;

public sealed class EmbeddingClient(HttpClient http) : IEmbeddingClient
{
    private sealed record EmbedRequest(string text);
    private sealed record EmbedResponse(float[] embedding);

    public async Task<float[]> EmbedAsync(string text, CancellationToken ct = default)
    {
        var resp = await http.PostAsJsonAsync("/embed", new EmbedRequest(text), ct);
        resp.EnsureSuccessStatusCode();
        var body = await resp.Content.ReadFromJsonAsync<EmbedResponse>(cancellationToken: ct)
            ?? throw new InvalidOperationException("Empty embedding response.");
        return body.embedding;
    }
}
