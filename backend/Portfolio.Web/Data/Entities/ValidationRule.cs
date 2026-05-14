namespace Portfolio.Web.Data.Entities;

public sealed class ValidationRule
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public string Name { get; set; } = "";
    public int? MinLength { get; set; }
    public int? MaxLength { get; set; }
    public string? Regex { get; set; }
    public string? ErrorMessage { get; set; }
    public DateTimeOffset CreatedAt { get; set; }

    public Tenant Tenant { get; set; } = null!;
    public ICollection<FieldDefinition> FieldDefinitions { get; set; } = [];
}
