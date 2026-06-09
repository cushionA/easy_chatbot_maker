# Sprint 1 Day 1 作業指示書（2026-05-17）

> テーマ: **DB の防御層を立てる**
> 完了時の状態: managed Postgres + OIDC プロバイダ + Secret Manager がプロビジョニングされ、`portfolio_app` ロールが `NOBYPASSRLS` で接続でき、`knowledge_entries` 1 テーブルだけ RLS のお手本ポリシーが効いている
> 推定所要: 4〜6 時間

---

## Day1-1. managed Postgres + OIDC + Secret Manager のプロビジョニング [INFRA]

**目的**
Auth と DB の基盤を得る。JWKS URL と DB 接続文字列を確保し、Day 2 以降のブロッカーを潰す。

**前提確認**
- [ ] クラウドアカウントを持っている（managed Postgres と OIDC プロバイダを作れる）
- [ ] 1Password / Bitwarden などのパスワード保管庫がある

**手順**
1. managed Postgres インスタンス（Cloud SQL / RDS など）を作成
   - インスタンス名: `easy-chatbot-maker`（任意）
   - DB password: 自動生成して保管庫に保存（**この場でメモらないと二度と見られない**）
   - Region: `Northeast Asia (Tokyo)` 相当（`ap-northeast-1`）
   - Postgres バージョン: 16
2. OIDC プロバイダ（Identity Platform / Cognito / Auth0 のいずれか）を作成し、以下を控える:
   - `Issuer`（例: `https://issuer.example.com/`）
   - `JWKS URL`（例: `https://issuer.example.com/.well-known/jwks.json`）
   - `Audience`（このアプリ用の client/audience）
3. Secret Manager に DB 接続情報・OIDC 設定を登録する（本番値は環境変数注入の経路を確保しておく）
4. managed Postgres の接続文字列（Direct connection, port 5432）を控える。形式:
   ```
   postgresql://postgres:<password>@<host>:5432/postgres
   ```
   ※ Pooler を挟む構成なら Direct(5432) を使う。Transaction Pooler(6543) はトランザクション制御に制約があるので避ける
5. リポジトリ直下に `.env.local` を作成（`.gitignore` に追記済みであることを確認）:
   ```
   OIDC_ISSUER=https://issuer.example.com/
   OIDC_JWKS_URL=https://issuer.example.com/.well-known/jwks.json
   OIDC_AUDIENCE=easy-chatbot-maker
   DATABASE_URL_OWNER=postgresql://postgres:<password>@<host>:5432/postgres
   ```

**完了確認**
- [ ] `curl $env:OIDC_JWKS_URL` で `{"keys":[...]}` が返る
- [ ] `psql "$env:DATABASE_URL_OWNER" -c "\dt"` で接続できる（空でも OK）
- [ ] `git status` で `.env.local` が untracked にも出ない（gitignore 済み）

**詰まったら**
- 接続が拒否される → Region が遠いとタイムアウトしやすい。Direct(5432) と Pooler(6543) を間違えていないか、IP 許可リスト/VPC を確認
- JWKS が 404 → OIDC プロバイダの discovery（`.well-known/openid-configuration`）から `jwks_uri` を引き直す

**AI 依頼テンプレ**: なし（手作業）

---

## Day1-2. 既存スキーマを managed Postgres に適用 [INFRA]

**目的**
`infra/db/migrations/0001_schema.sql` を managed Postgres 上に流し、ローカル開発と同じ 11 テーブルが managed 側にも存在する状態を作る。

**前提確認**
- [ ] Day1-1 完了
- [ ] ローカルで `docker compose up postgres` した状態と managed Postgres で同じスキーマになることをこれから保証する

**手順**
1. `psql "$env:DATABASE_URL_OWNER" -f infra/db/init.sql`
2. `psql "$env:DATABASE_URL_OWNER" -f infra/db/migrations/0001_schema.sql`
3. `psql "$env:DATABASE_URL_OWNER" -c "\dt public.*"` で 11 テーブル確認

**完了確認**
- [ ] 11 テーブル（users, tenants, user_tenants, categories, field_definitions, validation_rules, knowledge_entries, destinations, inquiries, unclassified_queue, tenant_public_keys）が見える（`03_db_schema.md` が正。`users` は内部 uuid + `oidc_sub`、初回ログイン時に JIT プロビジョニング）
- [ ] 全文検索・ベクトル検索は Elasticsearch が担当するため、`vector` / `pg_trgm` 拡張は不要

**詰まったら**
- スキーマ適用が `must be owner` で失敗 → 接続ロールが所有者でない。`DATABASE_URL_OWNER` が正しいロールを指しているか確認
- `users` の `oidc_sub` 一意制約に引っかかる → JIT プロビジョニングは「`oidc_sub` で UPSERT」が前提。重複投入していないか確認

**AI 依頼テンプレ**: なし（コマンド実行のみ）

---

## Day1-3. `0002_rls_roles.sql` を書く [INFRA]

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
3. `portfolio_app` 用のパスワードを生成し、`.env.local` に `DATABASE_URL_APP` として `portfolio_app` を使った接続 URL を追加
   ```
   DATABASE_URL_APP=postgresql://portfolio_app:<password>@<host>:5432/postgres
   ```
4. SQL を流す（パスワードは psql 変数で渡す）:
   ```powershell
   psql "$env:DATABASE_URL_OWNER" -v app_password="'<生成したパスワード>'" -f infra/db/migrations/0002_rls_roles.sql
   ```

**完了確認**
- [ ] `psql "$env:DATABASE_URL_OWNER" -c "\du"` で 2 ロールが見える
- [ ] `psql "$env:DATABASE_URL_OWNER" -c "SELECT rolname, rolbypassrls FROM pg_roles WHERE rolname IN ('portfolio_owner','portfolio_app')"` で `portfolio_app` が `f`（false = NOBYPASSRLS）
- [ ] `psql "$env:DATABASE_URL_APP" -c "SELECT 1"` で `portfolio_app` として接続できる

**詰まったら**
- `REASSIGN OWNED BY postgres` が失敗 → managed Postgres では初期所有者がプロバイダ管理ロールのことがある。`SELECT tableowner FROM pg_tables WHERE schemaname='public'` で実所有者を確認し、その名前を `REASSIGN OWNED BY ...` に入れる
- 接続できない → managed Postgres の IP 許可リスト / VPC / SSL 要件を確認

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## Day1-4. `knowledge_entries` 1 テーブルだけ RLS のお手本ポリシーを書く [INFRA]

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
   psql "$env:DATABASE_URL_OWNER" -f infra/db/migrations/0003_rls_policies.sql
   ```
4. 手動検証用のデータ投入（`psql`）:
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
psql "$env:DATABASE_URL_APP" -c "BEGIN; SET LOCAL app.tenant_id = '00000000-0000-0000-0000-000000000001'; SELECT title FROM knowledge_entries; ROLLBACK;"
# → a-doc のみ

# ケース 2: B のセッション変数 → B の 1 件だけ
psql "$env:DATABASE_URL_APP" -c "BEGIN; SET LOCAL app.tenant_id = '00000000-0000-0000-0000-000000000002'; SELECT title FROM knowledge_entries; ROLLBACK;"
# → b-doc のみ

# ケース 3: セッション変数未設定 → 0 行（フェイルセーフ）
psql "$env:DATABASE_URL_APP" -c "SELECT title FROM knowledge_entries;"
# → 0 件
```

**詰まったら**
- ケース 3 で全件返る → `FORCE ROW LEVEL SECURITY` が当たっていない or `portfolio_app` が `BYPASSRLS` のままになっている。Day1-3 の `\du` を再確認
- INSERT で `permission denied` → `portfolio_app` への GRANT 漏れ。Day1-3 の GRANT 文を見直す

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## Day 1 終了チェックリスト

- [x] managed Postgres + OIDC プロバイダ + Secret Manager がプロビジョニング済み
- [x] スキーマ（11 テーブル）が managed Postgres に存在
- [x] `portfolio_owner` / `portfolio_app` の 2 ロール、`portfolio_app` は `NOBYPASSRLS`
- [x] `knowledge_entries` の RLS が 3 ケース（A/B/未設定）すべて期待通り
- [x] `.env.local` に `OIDC_ISSUER` / `OIDC_JWKS_URL` / `OIDC_AUDIENCE` / `DATABASE_URL_OWNER` / `DATABASE_URL_APP` が揃う

## Day 2 への引き継ぎメモ（自分宛て）

- ポリシー名は `tenant_isolation` で統一する（AI 依頼時に明示）
- `user_tenants` だけは `current_setting('app.user_id', true)::uuid` 基準にする必要あり（Day2-1 で AI に明示）
- `tenants` テーブルは「自分の所属 tenant_id だけ可視」の `SELECT` ポリシーが特殊（同じく Day2-1）
