namespace Portfolio.Web.Data.Entities;

public sealed class TenantPublicKey
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public string KeyHash { get; set; } = "";
    public string? Label { get; set; }
    public int RateLimitRpm { get; set; } = 30;
    public string[] AllowedOrigins { get; set; } = [];
    public DateTimeOffset CreatedAt { get; set; }
    public DateTimeOffset? LastUsedAt { get; set; }

    public Tenant Tenant { get; set; } = null!;
}
