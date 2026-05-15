using System.Net.Http.Json;
using System.Text.Json.Serialization;

namespace Portfolio.Web.Services;

public sealed class EmbeddingClient(HttpClient http) : IEmbeddingClient
{
    private sealed record EmbedRequest(
        [property: JsonPropertyName("text")] string Text,
        [property: JsonPropertyName("mode")] string Mode);

    private sealed record EmbedResponse(
        [property: JsonPropertyName("embedding")] float[] Embedding);

    public async Task<float[]> EmbedAsync(string text, CancellationToken ct = default)
    {
        var resp = await http.PostAsJsonAsync("/embed", new EmbedRequest(text, "query"), ct);
        resp.EnsureSuccessStatusCode();
        var body = await resp.Content.ReadFromJsonAsync<EmbedResponse>(cancellationToken: ct)
            ?? throw new InvalidOperationException("Empty embedding response.");
        return body.Embedding;
    }
}
