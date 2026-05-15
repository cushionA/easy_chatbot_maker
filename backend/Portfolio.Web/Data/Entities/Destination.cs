namespace Portfolio.Web.Data.Entities;

public sealed class Destination
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public string Kind { get; set; } = "";
    public string Name { get; set; } = "";
    public string Config { get; set; } = "{}";
    public Guid? SecretVaultId { get; set; }
    public bool IsPrimary { get; set; }
    public string? FieldMapping { get; set; }
    public int SortOrder { get; set; }
    public DateTimeOffset CreatedAt { get; set; }

    public Tenant Tenant { get; set; } = null!;
    public ICollection<Inquiry> Inquiries { get; set; } = [];
}
