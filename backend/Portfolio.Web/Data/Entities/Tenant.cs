namespace Portfolio.Web.Data.Entities;

public sealed class Tenant
{
    public Guid Id { get; set; }
    public string Slug { get; set; } = "";
    public string Name { get; set; } = "";
    public DateTimeOffset CreatedAt { get; set; }

    public ICollection<UserTenant> UserTenants { get; set; } = [];
    public ICollection<Category> Categories { get; set; } = [];
    public ICollection<ValidationRule> ValidationRules { get; set; } = [];
    public ICollection<FieldDefinition> FieldDefinitions { get; set; } = [];
    public ICollection<KnowledgeEntry> KnowledgeEntries { get; set; } = [];
    public ICollection<Destination> Destinations { get; set; } = [];
    public ICollection<Inquiry> Inquiries { get; set; } = [];
    public ICollection<UnclassifiedQueueEntry> UnclassifiedQueueEntries { get; set; } = [];
    public ICollection<TenantPublicKey> TenantPublicKeys { get; set; } = [];
}
