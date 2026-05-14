-- Postgres init for Service A.
-- Runs once on first container start (when data dir is empty).

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Minimal sanity table so smoke tests / health checks have something to query.
CREATE TABLE IF NOT EXISTS _meta (
    key   text PRIMARY KEY,
    value text NOT NULL
);

INSERT INTO _meta (key, value) VALUES ('schema_version', '0')
ON CONFLICT (key) DO NOTHING;
