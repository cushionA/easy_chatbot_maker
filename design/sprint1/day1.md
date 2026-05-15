# Sprint 1 Day 1 作業指示書（2026-05-17）

> テーマ: **DB の防御層を立てる**
> 完了時の状態: Supabase プロジェクトが動き、`portfolio_app` ロールが `NOBYPASSRLS` で接続でき、`knowledge_entries` 1 テーブルだけ RLS のお手本ポリシーが効いている
> 推定所要: 4〜6 時間

---

## Day1-1. Supabase プロジェクト作成

**目的**
Auth と DB の基盤を得る。JWKS URL と DB 接続文字列を確保し、Day 2 以降のブロッカーを潰す。

**前提確認**
- [ ] Supabase アカウントを持っている（無ければ GitHub OAuth で 1 分で作成）
- [ ] 1Password / Bitwarden などのパスワード保管庫がある

**手順**
1. https://supabase.com/dashboard → **New project**
   - Name: `easy-chatbot-maker`（任意）
   - DB password: 自動生成して保管庫に保存（**この場でメモらないと二度と見られない**）
   - Region: `Northeast Asia (Tokyo)`
   - Plan: Free
2. プロジェクト作成後（2 分ほど待つ）、左メニュー **Project Settings → API** で以下を控える:
   - `Project URL`（例: `https://abc123.supabase.co`）
   - `anon` `public` key
   - `service_role` `secret` key（**取扱注意**、フロントに出さない）
3. **Project Settings → API → JWT Settings** の `JWT Secret` を控える（HS256 検証のフォールバック用）
4. **Project Settings → Database → Connection string → URI**（Direct connection, port 5432）を控える。形式:
   ```
   postgresql://postgres.<ref>:<password>@aws-0-ap-northeast-1.pooler.supabase.com:5432/postgres
   ```
   ※ Supabase は Direct を `pooler` 経由で出すことが多い。port 5432 が Direct、6543 は Transaction Pooler
5. リポジトリ直下に `.env.local` を作成（`.gitignore` に追記済みであることを確認）:
   ```
   SUPABASE_URL=https://abc123.supabase.co
   SUPABASE_JWKS_URL=https://abc123.supabase.co/auth/v1/.well-known/jwks.json
   SUPABASE_JWT_SECRET=...
   SUPABASE_DB_URL_OWNER=postgresql://postgres.<ref>:<password>@aws-0-ap-northeast-1.pooler.supabase.com:5432/postgres
   ```

**完了確認**
- [ ] `curl $env:SUPABASE_JWKS_URL` で `{"keys":[...]}` が返る
- [ ] `psql "$env:SUPABASE_DB_URL_OWNER" -c "\dt"` で接続できる（空でも OK）
- [ ] `git status` で `.env.local` が untracked にも出ない（gitignore 済み）

**詰まったら**
- 接続が拒否される → Region が遠いとタイムアウトしやすい。Direct(5432) と Pooler(6543) を間違えていないか
- JWKS が 404 → Project URL のサブドメインを確認（`<ref>.supabase.co` 形式）

**AI 依頼テンプレ**: なし（手作業）

---

## Day1-2. 既存スキーマを Supabase に適用

**目的**
`infra/db/migrations/0001_schema.sql` を Supabase 上に流し、ローカル開発と同じ 10 テーブルが Supabase 側にも存在する状態を作る。

**前提確認**
- [ ] Day1-1 完了
- [ ] ローカルで `docker compose up postgres` した状態と Supabase で同じスキーマになることをこれから保証する

**手順**
1. `psql "$env:SUPABASE_DB_URL_OWNER" -f infra/db/init.sql`
2. `psql "$env:SUPABASE_DB_URL_OWNER" -f infra/db/migrations/0001_schema.sql`
3. `psql "$env:SUPABASE_DB_URL_OWNER" -c "\dt public.*"` で 10 テーブル確認

**完了確認**
- [ ] 10 テーブル（tenants, user_tenants, categories, field_definitions, validation_rules, knowledge_entries, destinations, inquiries, unclassified_queue, tenant_public_keys）が見える
- [ ] `\dx` で `vector` / `pg_trgm` 拡張が有効

**詰まったら**
- 拡張が入らない → Supabase は `vector` / `pg_trgm` をデフォルトで有効化できる。**Database → Extensions** から GUI で ON にしても可
- `init.sql` の `CREATE EXTENSION` が `must be owner` で失敗 → Supabase は `superuser` ではないので、GUI 経由で拡張を入れ、`init.sql` の該当行をコメントアウトして再実行

**AI 依頼テンプレ**: なし（コマンド実行のみ）

---

## Day1-3. `0002_rls_roles.sql` を書く

**目的**
`portfolio_owner`（マイグレーション専用）と `portfolio_app`（アプリ接続専用・`NOBYPASSRLS`）の 2 ロールを作る。これが**未対応だと RLS が無力化**される。

**自分で書く理由**
GRANT 粒度を誤ると RLS をすり抜ける接続経路が残る。面接で「なぜ 2 ロールに分けたか」を語る要所。

**前提確認**
- [ ] Day1-2 完了
- [ ] `design/04_security_multitenant.md:58-78` を読んだ

**手順**
1. 新規ファイル `infra/db/migrations/0002_rls_roles.sql` を作成
2. 以下の骨格を書く（パスワードは `.env.local` 経由で渡す前提なので SQL ファイル内に書かない）:
   ```sql
   -- portfolio_owner: スキーマ所有・マイグレーション実行
   DO $$ BEGIN
     IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'portfolio_owner') THEN
       CREATE ROLE portfolio_owner NOLOGIN;
     END IF;
   END $$;

   -- portfolio_app: アプリ接続・NOBYPASSRLS
   DO $$ BEGIN
     IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'portfolio_app') THEN
       CREATE ROLE portfolio_app LOGIN NOBYPASSRLS PASSWORD :'app_password';
     END IF;
   END $$;

   -- 既存スキーマの所有権を owner に
   REASSIGN OWNED BY postgres TO portfolio_owner;

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
   ```
3. Supabase の SQL Editor で `portfolio_app` 用のパスワードを生成し、`.env.local` に `SUPABASE_DB_URL_APP` として `postgres.<ref>` の代わりに `portfolio_app` を使った接続 URL を追加
   ```
   SUPABASE_DB_URL_APP=postgresql://portfolio_app:<password>@aws-0-ap-northeast-1.pooler.supabase.com:5432/postgres
   ```
4. SQL を流す（パスワードは psql 変数で渡す）:
   ```powershell
   psql "$env:SUPABASE_DB_URL_OWNER" -v app_password="'<生成したパスワード>'" -f infra/db/migrations/0002_rls_roles.sql
   ```

**完了確認**
- [ ] `psql "$env:SUPABASE_DB_URL_OWNER" -c "\du"` で 2 ロールが見える
- [ ] `psql "$env:SUPABASE_DB_URL_OWNER" -c "SELECT rolname, rolbypassrls FROM pg_roles WHERE rolname IN ('portfolio_owner','portfolio_app')"` で `portfolio_app` が `f`（false = NOBYPASSRLS）
- [ ] `psql "$env:SUPABASE_DB_URL_APP" -c "SELECT 1"` で `portfolio_app` として接続できる

**詰まったら**
- `REASSIGN OWNED BY postgres` が失敗 → Supabase のスキーマは `supabase_admin` 所有のことがある。`SELECT tableowner FROM pg_tables WHERE schemaname='public'` で実所有者を確認し、その名前を `REASSIGN OWNED BY ...` に入れる
- 接続できない → Supabase Free は外部 IP 制限がデフォルト無効だが、念のため Network Restrictions を確認

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## Day1-4. `knowledge_entries` 1 テーブルだけ RLS のお手本ポリシーを書く

**目的**
**「最初の 1 個」を自分の手で書く**。残り 9 テーブルは Day 2-1 で AI に複製させるので、ここでポリシーの型を確定させる。

**自分で書く理由**
RLS は漏洩したら一発アウト。`USING` / `WITH CHECK` / セッション変数未設定時の挙動を自分で確認しておかないと、Day 2 で AI が量産したものを信頼できない。

**前提確認**
- [ ] Day1-3 完了
- [ ] `design/04_security_multitenant.md:24-44`（RLS の仕組み）を読んだ

**手順**
1. 新規ファイル `infra/db/migrations/0003_rls_policies.sql` を作成
2. 以下を書く:
   ```sql
   ALTER TABLE knowledge_entries ENABLE ROW LEVEL SECURITY;
   ALTER TABLE knowledge_entries FORCE  ROW LEVEL SECURITY;  -- owner にも RLS を強制

   DROP POLICY IF EXISTS tenant_isolation ON knowledge_entries;
   CREATE POLICY tenant_isolation ON knowledge_entries
     USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
     WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);
   ```
   - `current_setting('app.tenant_id', true)` の第二引数 `true` は「未定義なら NULL を返す」。これにより `SET LOCAL` 未発行接続は空集合になる（フェイルセーフ）
3. owner で流す:
   ```powershell
   psql "$env:SUPABASE_DB_URL_OWNER" -f infra/db/migrations/0003_rls_policies.sql
   ```
4. 手動検証用のデータ投入（`SQL Editor` か `psql`）:
   ```sql
   -- 検証用テナント 2 つを作る
   INSERT INTO tenants (id, slug, name) VALUES
     ('00000000-0000-0000-0000-000000000001'::uuid, 'tenant-a', 'Tenant A'),
     ('00000000-0000-0000-0000-000000000002'::uuid, 'tenant-b', 'Tenant B');

   -- カテゴリ 1 つずつ（categories はまだ RLS 未適用なので owner で入る）
   INSERT INTO categories (id, tenant_id, name) VALUES
     ('10000000-0000-0000-0000-000000000001'::uuid, '00000000-0000-0000-0000-000000000001'::uuid, 'cat-a'),
     ('10000000-0000-0000-0000-000000000002'::uuid, '00000000-0000-0000-0000-000000000002'::uuid, 'cat-b');

   -- knowledge_entries を 1 件ずつ（FORCE が効くので owner でも tenant_id を埋める）
   INSERT INTO knowledge_entries (tenant_id, category_id, title) VALUES
     ('00000000-0000-0000-0000-000000000001'::uuid, '10000000-0000-0000-0000-000000000001'::uuid, 'a-doc'),
     ('00000000-0000-0000-0000-000000000002'::uuid, '10000000-0000-0000-0000-000000000002'::uuid, 'b-doc');
   ```

**完了確認**
3 ケース全部 green:

```powershell
# ケース 1: A のセッション変数 → A の 1 件だけ
psql "$env:SUPABASE_DB_URL_APP" -c "BEGIN; SET LOCAL app.tenant_id = '00000000-0000-0000-0000-000000000001'; SELECT title FROM knowledge_entries; ROLLBACK;"
# → a-doc のみ

# ケース 2: B のセッション変数 → B の 1 件だけ
psql "$env:SUPABASE_DB_URL_APP" -c "BEGIN; SET LOCAL app.tenant_id = '00000000-0000-0000-0000-000000000002'; SELECT title FROM knowledge_entries; ROLLBACK;"
# → b-doc のみ

# ケース 3: セッション変数未設定 → 0 行（フェイルセーフ）
psql "$env:SUPABASE_DB_URL_APP" -c "SELECT title FROM knowledge_entries;"
# → 0 件
```

**詰まったら**
- ケース 3 で全件返る → `FORCE ROW LEVEL SECURITY` が当たっていない or `portfolio_app` が `BYPASSRLS` のままになっている。Day1-3 の `\du` を再確認
- INSERT で `permission denied` → `portfolio_app` への GRANT 漏れ。Day1-3 の GRANT 文を見直す

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## Day 1 終了チェックリスト

- [ ] Supabase プロジェクトが動く
- [ ] スキーマ（10 テーブル）が Supabase に存在
- [ ] `portfolio_owner` / `portfolio_app` の 2 ロール、`portfolio_app` は `NOBYPASSRLS`
- [ ] `knowledge_entries` の RLS が 3 ケース（A/B/未設定）すべて期待通り
- [ ] `.env.local` に `SUPABASE_URL` / `SUPABASE_JWKS_URL` / `SUPABASE_JWT_SECRET` / `SUPABASE_DB_URL_OWNER` / `SUPABASE_DB_URL_APP` が揃う

## Day 2 への引き継ぎメモ（自分宛て）

- ポリシー名は `tenant_isolation` で統一する（AI 依頼時に明示）
- `user_tenants` だけは `current_setting('app.user_id', true)::uuid` 基準にする必要あり（Day2-1 で AI に明示）
- `tenants` テーブルは「自分の所属 tenant_id だけ可視」の `SELECT` ポリシーが特殊（同じく Day2-1）
