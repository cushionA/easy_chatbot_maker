namespace Portfolio.Web.Services;

public interface IEmbeddingClient
{
    Task<float[]> EmbedAsync(string text, CancellationToken ct = default);
}
