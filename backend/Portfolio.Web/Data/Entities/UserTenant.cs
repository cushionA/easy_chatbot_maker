namespace Portfolio.Web.Data.Entities;

public sealed class UserTenant
{
    public Guid UserId { get; set; }
    public Guid TenantId { get; set; }
    public string Role { get; set; } = "member";
    public DateTimeOffset JoinedAt { get; set; }

    public Tenant Tenant { get; set; } = null!;
}
