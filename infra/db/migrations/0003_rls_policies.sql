-- knowledge_entries
ALTER TABLE knowledge_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE knowledge_entries FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_isolation ON knowledge_entries;
CREATE POLICY tenant_isolation ON knowledge_entries
  USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- categories
ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_isolation ON categories;
CREATE POLICY tenant_isolation ON categories
  USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- field_definitions
ALTER TABLE field_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE field_definitions FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_isolation ON field_definitions;
CREATE POLICY tenant_isolation ON field_definitions
  USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- validation_rules
ALTER TABLE validation_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE validation_rules FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_isolation ON validation_rules;
CREATE POLICY tenant_isolation ON validation_rules
  USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- destinations
ALTER TABLE destinations ENABLE ROW LEVEL SECURITY;
ALTER TABLE destinations FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_isolation ON destinations;
CREATE POLICY tenant_isolation ON destinations
  USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- inquiries
ALTER TABLE inquiries ENABLE ROW LEVEL SECURITY;
ALTER TABLE inquiries FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_isolation ON inquiries;
CREATE POLICY tenant_isolation ON inquiries
  USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- unclassified_queue
ALTER TABLE unclassified_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE unclassified_queue FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_isolation ON unclassified_queue;
CREATE POLICY tenant_isolation ON unclassified_queue
  USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- tenant_public_keys
ALTER TABLE tenant_public_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_public_keys FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_isolation ON tenant_public_keys;
CREATE POLICY tenant_isolation ON tenant_public_keys
  USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- user_tenants（user_id 基準）
ALTER TABLE user_tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_tenants FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_isolation ON user_tenants;
CREATE POLICY user_isolation ON user_tenants
  USING      (user_id = current_setting('app.user_id', true)::uuid)
  WITH CHECK (user_id = current_setting('app.user_id', true)::uuid);

-- tenants（自分が所属するテナントのみ SELECT 可、INSERT/UPDATE/DELETE は GRANT で拒否）
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenants FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_visibility ON tenants;
CREATE POLICY tenant_visibility ON tenants
  FOR SELECT
  USING (id IN (
    SELECT tenant_id FROM user_tenants
    WHERE user_id = current_setting('app.user_id', true)::uuid
  ));