-- portfolio_owner: スキーマ所有・マイグレーション実行
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'portfolio_owner') THEN
    CREATE ROLE portfolio_owner NOLOGIN;
  END IF;
END $$;

-- psql の :'var' は $$ ブロック内で展開されないため set_config 経由で渡す
SELECT set_config('app.password', :'app_password', false);

-- portfolio_app: アプリ接続・NOBYPASSRLS
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'portfolio_app') THEN
    EXECUTE format('CREATE ROLE portfolio_app LOGIN NOBYPASSRLS PASSWORD %L',
                   current_setting('app.password'));
  END IF;
END $$;

-- REASSIGN OWNED BY は Supabase では権限エラーになるため削除
-- (postgres が引き続きオーナーで RLS は portfolio_app の NOBYPASSRLS で担保する)

-- app に必要最小権限のみ GRANT
GRANT CONNECT ON DATABASE postgres TO portfolio_app;
GRANT USAGE ON SCHEMA public TO portfolio_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO portfolio_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO portfolio_app;

-- 将来テーブルにも自動付与
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO portfolio_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO portfolio_app;
