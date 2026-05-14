using NpgsqlTypes;
using Pgvector;

namespace Portfolio.Web.Data.Entities;

public sealed class KnowledgeEntry
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public Guid CategoryId { get; set; }
    public string Name { get; set; } = "";
    public string[] Keywords { get; set; } = [];
    public string[] ExampleQueries { get; set; } = [];
    public string[] RequiredFieldCodes { get; set; } = [];
    public string? AutoResolution { get; set; }
    public string? GuidanceMessage { get; set; }
    public string TicketPriority { get; set; } = "normal";
    public int MatchCount { get; set; }
    public Vector? Embedding { get; set; }
    public string? EmbeddingModel { get; set; }
    public NpgsqlTsVector? SearchText { get; set; }
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset UpdatedAt { get; set; }

    public Tenant Tenant { get; set; } = null!;
    public Category Category { get; set; } = null!;
}
