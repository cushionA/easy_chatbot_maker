namespace Portfolio.Web.Data.Entities;

public sealed class FieldDefinition
{
    public Guid Id { get; set; }
    public Guid TenantId { get; set; }
    public string Code { get; set; } = "";
    public string FieldType { get; set; } = "";
    public bool IsRequired { get; set; }
    public bool IsMulti { get; set; }
    public string? Question { get; set; }
    public string[]? Choices { get; set; }
    public Guid? ValidationRuleId { get; set; }
    public DateTimeOffset CreatedAt { get; set; }

    public Tenant Tenant { get; set; } = null!;
    public ValidationRule? ValidationRule { get; set; }
}
