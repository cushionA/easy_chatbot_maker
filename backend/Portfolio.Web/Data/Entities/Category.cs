namespace Portfolio.Web.Data.Entities;

public sealed class Category
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public string Code { get; set; } = "";
    public string Name { get; set; } = "";
    public string? Emoji { get; set; }
    public int SortOrder { get; set; }
    public string[] RequiredFieldCodes { get; set; } = [];
    public DateTimeOffset CreatedAt { get; set; }

    public Tenant Tenant { get; set; } = null!;
    public ICollection<KnowledgeEntry> KnowledgeEntries { get; set; } = [];
}
