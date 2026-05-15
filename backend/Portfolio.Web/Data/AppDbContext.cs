using System.Text;
using Microsoft.EntityFrameworkCore;
using Portfolio.Web.Data.Entities;

namespace Portfolio.Web.Data;

public sealed class AppDbContext(DbContextOptions<AppDbContext> options) : DbContext(options)
{
    public DbSet<Tenant> Tenants => Set<Tenant>();
    public DbSet<UserTenant> UserTenants => Set<UserTenant>();
    public DbSet<Category> Categories => Set<Category>();
    public DbSet<ValidationRule> ValidationRules => Set<ValidationRule>();
    public DbSet<FieldDefinition> FieldDefinitions => Set<FieldDefinition>();
    public DbSet<KnowledgeEntry> KnowledgeEntries => Set<KnowledgeEntry>();
    public DbSet<Destination> Destinations => Set<Destination>();
    public DbSet<Inquiry> Inquiries => Set<Inquiry>();
    public DbSet<UnclassifiedQueueEntry> UnclassifiedQueue => Set<UnclassifiedQueueEntry>();
    public DbSet<TenantPublicKey> TenantPublicKeys => Set<TenantPublicKey>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<UserTenant>(e =>
            e.HasKey(ut => new { ut.UserId, ut.TenantId }));

        modelBuilder.Entity<Tenant>(e =>
            e.HasIndex(t => t.Slug).IsUnique());

        modelBuilder.Entity<Category>(e =>
            e.HasIndex(c => new { c.TenantId, c.Code }).IsUnique());

        modelBuilder.Entity<ValidationRule>(e =>
            e.HasIndex(v => new { v.TenantId, v.Name }).IsUnique());

        modelBuilder.Entity<FieldDefinition>(e =>
            e.HasIndex(f => new { f.TenantId, f.Code }).IsUnique());

        modelBuilder.Entity<KnowledgeEntry>(e =>
        {
            e.Property(k => k.Embedding).HasColumnType("vector(768)");
            e.Property(k => k.SearchText)
                .HasComputedColumnSql(
                    "to_tsvector('simple', name || ' ' || array_to_string(keywords, ' ') || ' ' || array_to_string(example_queries, ' '))",
                    stored: true)
                .HasColumnType("tsvector");
            e.HasIndex(k => new { k.TenantId, k.Name }).IsUnique();
            e.HasIndex(k => new { k.TenantId, k.CategoryId });
        });

        modelBuilder.Entity<Inquiry>(e =>
        {
            e.Property(i => i.QueryEmbedding).HasColumnType("vector(768)");
            e.HasIndex(i => new { i.TenantId, i.CreatedAt });
            e.HasIndex(i => i.MatchedKnowledgeId)
                .HasFilter("matched_knowledge_id IS NOT NULL");
        });

        modelBuilder.Entity<UnclassifiedQueueEntry>(e =>
        {
            e.Property(u => u.QueryEmbedding).HasColumnType("vector(768)");
            e.HasIndex(u => new { u.TenantId, u.Status });
        });

        ApplySnakeCaseNaming(modelBuilder);
    }

    private static void ApplySnakeCaseNaming(ModelBuilder modelBuilder)
    {
        foreach (var entity in modelBuilder.Model.GetEntityTypes())
        {
            var tableName = entity.GetTableName();
            if (tableName is not null)
            {
                entity.SetTableName(ToSnakeCase(tableName));
            }

            foreach (var prop in entity.GetProperties())
            {
                var col = prop.GetColumnName();
                if (col is not null)
                {
                    prop.SetColumnName(ToSnakeCase(col));
                }
            }

            foreach (var key in entity.GetKeys())
            {
                var keyName = key.GetName();
                if (keyName is not null)
                {
                    key.SetName(ToSnakeCase(keyName));
                }
            }

            foreach (var index in entity.GetIndexes())
            {
                var dbName = index.GetDatabaseName();
                if (dbName is not null)
                {
                    index.SetDatabaseName(ToSnakeCase(dbName));
                }
            }

            foreach (var fk in entity.GetForeignKeys())
            {
                var constraintName = fk.GetConstraintName();
                if (constraintName is not null)
                {
                    fk.SetConstraintName(ToSnakeCase(constraintName));
                }
            }
        }
    }

    private static string ToSnakeCase(string input)
    {
        var sb = new StringBuilder(input.Length + 8);
        for (var i = 0; i < input.Length; i++)
        {
            if (i > 0 && char.IsUpper(input[i]) && !char.IsUpper(input[i - 1]))
            {
                sb.Append('_');
            }
            sb.Append(char.ToLowerInvariant(input[i]));
        }
        return sb.ToString();
    }
}
