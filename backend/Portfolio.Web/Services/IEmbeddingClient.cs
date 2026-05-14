namespace Portfolio.Web.Services;

public interface IEmbeddingClient
{
    public Task<float[]> EmbedAsync(string text, CancellationToken ct = default);
}
