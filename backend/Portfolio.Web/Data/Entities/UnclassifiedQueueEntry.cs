using Pgvector;

namespace Portfolio.Web.Data.Entities;

public sealed class UnclassifiedQueueEntry
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public Guid? UserId { get; set; }
    public string RawQuery { get; set; } = "";
    public string? FreeformBody { get; set; }
    public Vector? QueryEmbedding { get; set; }
    public string Status { get; set; } = "pending";
    public Guid? ReviewedBy { get; set; }
    public DateTimeOffset? ReviewedAt { get; set; }
    public string? ReviewNote { get; set; }
    public DateTimeOffset CreatedAt { get; set; }

    public Tenant Tenant { get; set; } = null!;
}
