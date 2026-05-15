-- 0001_schema.sql — Service A の全テーブル定義
--
-- 使い方:
--   Oracle Cloud (手動):  psql -h <host> -U portfolio -d portfolio -f 0001_schema.sql
--   Docker ローカル開発:  docker-compose.yml が 01_schema.sql としてマウントするので自動実行
--
-- 拡張機能は infra/db/init.sql (00_init.sql) で作成済みの前提。
-- RLS ポリシーは Sprint 1 で自分で書く → design/04_security_multitenant.md を参照。

-- -----------------------------------------------------------------------
-- Auth スタブ（Oracle Cloud 自己ホスト用）
-- Supabase を使う場合は auth.users が Supabase 側にあるのでこのブロック不要。
-- -----------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);

-- -----------------------------------------------------------------------
-- tenants — 組織
-- -----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tenants (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug       text UNIQUE NOT NULL,
    name       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------
-- user_tenants — メンバーシップ（多対多）
-- -----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS user_tenants (
    user_id   uuid REFERENCES auth.users(id) ON DELETE CASCADE,
    tenant_id uuid REFERENCES tenants(id)    ON DELETE CASCADE,
    role      text NOT NULL CHECK (role IN ('admin', 'member')),
    joined_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, tenant_id)
);

-- -----------------------------------------------------------------------
-- categories
-- -----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS categories (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    code                 text NOT NULL,
    name                 text NOT NULL,
    emoji                text,
    sort_order           int  NOT NULL DEFAULT 0,
    required_field_codes text[] NOT NULL DEFAULT '{}',
    created_at           timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code)
);

-- -----------------------------------------------------------------------
-- validation_rules
-- -----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS validation_rules (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name          text NOT NULL,
    min_length    int,
    max_length    int,
    regex         text,
    error_message text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name)
);

-- -----------------------------------------------------------------------
-- field_definitions
-- -----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS field_definitions (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    code               text NOT NULL,
    field_type         text NOT NULL,
    is_required        boolean NOT NULL DEFAULT false,
    is_multi           boolean NOT NULL DEFAULT false,
    question           text,
    choices            text[],
    validation_rule_id uuid REFERENCES validation_rules(id) ON DELETE SET NULL,
    created_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code)
);

-- -----------------------------------------------------------------------
-- knowledge_entries（最重要テーブル）
-- -----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS knowledge_entries (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            uuid NOT NULL REFERENCES tenants(id)     ON DELETE CASCADE,
    category_id          uuid NOT NULL REFERENCES categories(id)  ON DELETE CASCADE,
    name                 text NOT NULL,
    keywords             text[] NOT NULL DEFAULT '{}',
    example_queries      text[] NOT NULL DEFAULT '{}',
    required_field_codes text[] NOT NULL DEFAULT '{}',
    auto_resolution      text,
    guidance_message     text,
    ticket_priority      text NOT NULL DEFAULT 'normal'
        CHECK (ticket_priority IN ('low', 'normal', 'high', 'urgent')),
    match_count          int  NOT NULL DEFAULT 0,
    embedding            vector(768),
    embedding_model      text,
    search_text          tsvector GENERATED ALWAYS AS (
        to_tsvector('simple',
            name || ' ' ||
            array_to_string(keywords, ' ') || ' ' ||
            array_to_string(example_queries, ' ')
        )
    ) STORED,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name)
);

-- -----------------------------------------------------------------------
-- destinations — 起票先設定
-- -----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS destinations (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    kind            text NOT NULL CHECK (kind IN ('redmine', 'github_issues')),
    name            text NOT NULL,
    config          jsonb NOT NULL,
    secret_vault_id uuid,
    is_primary      boolean NOT NULL DEFAULT false,
    field_mapping   jsonb,
    sort_order      int NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- 1テナントにプライマリは1つだけ（部分ユニークインデックス）
CREATE UNIQUE INDEX IF NOT EXISTS destinations_one_primary_per_tenant
    ON destinations (tenant_id) WHERE is_primary;

-- -----------------------------------------------------------------------
-- inquiries — 問い合わせ履歴（メタのみ、本文無し）
-- -----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS inquiries (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            uuid NOT NULL REFERENCES tenants(id)        ON DELETE CASCADE,
    user_id              uuid REFERENCES auth.users(id)              ON DELETE SET NULL,
    category_id          uuid REFERENCES categories(id),
    matched_knowledge_id uuid REFERENCES knowledge_entries(id),
    raw_query            text,
    query_embedding      vector(768),
    embedding_model      text,
    destination_id       uuid REFERENCES destinations(id),
    external_ticket_id   text,
    external_ticket_url  text,
    status               text NOT NULL,
    match_strategy       text,
    confidence_score     real,
    resolved             boolean,
    draft_fields         jsonb,
    created_at           timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------
-- unclassified_queue — 未分類キュー
-- -----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS unclassified_queue (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id         uuid REFERENCES auth.users(id)       ON DELETE SET NULL,
    raw_query       text NOT NULL,
    freeform_body   text,
    query_embedding vector(768),
    status          text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'added_to_master', 'discarded')),
    reviewed_by     uuid REFERENCES auth.users(id),
    reviewed_at     timestamptz,
    review_note     text,
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------
-- tenant_public_keys — 埋め込みウィジェット用公開キー
-- -----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tenant_public_keys (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    key_hash        text NOT NULL,
    label           text,
    rate_limit_rpm  int NOT NULL DEFAULT 30,
    allowed_origins text[] NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    last_used_at    timestamptz
);

-- -----------------------------------------------------------------------
-- インデックス
-- -----------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_knowledge_entries_tenant_category
    ON knowledge_entries (tenant_id, category_id);

CREATE INDEX IF NOT EXISTS idx_inquiries_tenant_created
    ON inquiries (tenant_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_inquiries_matched_knowledge
    ON inquiries (matched_knowledge_id)
    WHERE matched_knowledge_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_unclassified_queue_tenant_status
    ON unclassified_queue (tenant_id, status);

-- pgvector HNSW（近似最近傍、高速）— Sprint 4 の検索で使う
CREATE INDEX IF NOT EXISTS idx_knowledge_entries_embedding_hnsw
    ON knowledge_entries USING hnsw (embedding vector_cosine_ops)
    WHERE embedding IS NOT NULL;

-- BM25 用 GIN（全文検索）— Sprint 4 の検索で使う
CREATE INDEX IF NOT EXISTS idx_knowledge_entries_search_text
    ON knowledge_entries USING gin (search_text);

-- -----------------------------------------------------------------------
-- トリガー: 起票確定時に match_count を +1
-- -----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION increment_match_count()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'created'
       AND NEW.matched_knowledge_id IS NOT NULL
       AND (OLD.status IS NULL OR OLD.status <> 'created')
    THEN
        UPDATE knowledge_entries
           SET match_count = match_count + 1
         WHERE id = NEW.matched_knowledge_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_increment_match_count ON inquiries;
CREATE TRIGGER trg_increment_match_count
    AFTER INSERT OR UPDATE OF status ON inquiries
    FOR EACH ROW EXECUTE FUNCTION increment_match_count();

-- -----------------------------------------------------------------------
-- RLS（Row Level Security）— Sprint 1 で別 migration（0003_rls_policies.sql）として追加する
-- 方針は design/04_security_multitenant.md を参照。要点:
--   * ASP.NET Core 直接接続のため auth.uid() は使わない
--   * 全テーブルのポリシーは current_setting('app.tenant_id')::uuid 直接方式
--   * スキーマ所有 portfolio_owner / アプリ接続 portfolio_app の 2 ロール分離
--     （portfolio_app は NOBYPASSRLS）→ 0002_rls_roles.sql で先に作る
--
-- 雛形:
-- ALTER TABLE knowledge_entries ENABLE ROW LEVEL SECURITY;
-- CREATE POLICY tenant_isolation ON knowledge_entries
--   USING       (tenant_id = current_setting('app.tenant_id')::uuid)
--   WITH CHECK  (tenant_id = current_setting('app.tenant_id')::uuid);
-- -----------------------------------------------------------------------

-- -----------------------------------------------------------------------
-- EF Core マイグレーション履歴への登録
-- dotnet ef migrations add InitialCreate を実行した後、
-- このDBに対して dotnet ef database update を走らせる前にコメントを外す。
-- （スキーマが既に存在するので、EF Core に「適用済み」と教える）
-- -----------------------------------------------------------------------
-- CREATE TABLE IF NOT EXISTS "__EFMigrationsHistory" (
--     "MigrationId"    character varying(150) NOT NULL,
--     "ProductVersion" character varying(32)  NOT NULL,
--     CONSTRAINT "PK___EFMigrationsHistory" PRIMARY KEY ("MigrationId")
-- );
-- INSERT INTO "__EFMigrationsHistory" ("MigrationId", "ProductVersion")
-- VALUES ('20260101000000_InitialCreate', '8.0.10')
-- ON CONFLICT DO NOTHING;
