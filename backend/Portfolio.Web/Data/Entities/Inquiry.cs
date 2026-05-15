using Pgvector;

namespace Portfolio.Web.Data.Entities;

public sealed class Inquiry
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public Guid? UserId { get; set; }
    public Guid? CategoryId { get; set; }
    public Guid? MatchedKnowledgeId { get; set; }
    public string? RawQuery { get; set; }
    public Vector? QueryEmbedding { get; set; }
    public string? EmbeddingModel { get; set; }
    public Guid? DestinationId { get; set; }
    public string? ExternalTicketId { get; set; }
    public string? ExternalTicketUrl { get; set; }
    public string Status { get; set; } = "";
    public string? MatchStrategy { get; set; }
    public float? ConfidenceScore { get; set; }
    public bool? Resolved { get; set; }
    public string? DraftFields { get; set; }
    public DateTimeOffset CreatedAt { get; set; }

    public Tenant Tenant { get; set; } = null!;
    public Category? Category { get; set; }
    public KnowledgeEntry? MatchedKnowledge { get; set; }
    public Destination? Destination { get; set; }
}
