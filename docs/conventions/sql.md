# SQL / PostgreSQL 規約

対象: `infra/db/migrations/*.sql`（スキーマ・RLS）と、アプリから発行する SQL。設計の正は [`design/03_db_schema.md`](../../design/03_db_schema.md) と [`design/04_security_multitenant.md`](../../design/04_security_multitenant.md)。共通原則は [README.md](README.md)。

自動 lint は **sqlfluff**（[`.sqlfluff`](../../.sqlfluff)）。capitalisation 一貫性・`<>`・末尾セミコロン・ambiguous など**意味的なルールだけ**を強制し、列の整列レイアウト（手で揃える）はツールで縛らない方針（allowlist）。`make lint.sql` / pre-commit / CI で走る。ただし**RLS の不変条件は lint では守れない**ので、最終的にはレビュー + migration テストが要。より深い PostgreSQL チューニングは [`.agents/skills/supabase-postgres-best-practices/`](../../.agents/skills/supabase-postgres-best-practices/) を参照。

## マイグレーション規律

- マイグレーションは `NNNN_snake_case.sql`（`0001_schema.sql`, `0002_rls_roles.sql`, …）。**連番・前進のみ**。
- **適用済みマイグレーションは編集しない。** スキーマを変えたいなら新しい番号のファイルを足す（履歴が正）。
- できる限り**冪等**に書く: `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` / `DROP POLICY IF EXISTS` → `CREATE POLICY`（既存マイグレーションの作法に合わせる）。
- 1 マイグレーション = 1 つの意図。スキーマ変更とデータ移行を混ぜない。
- 破壊的変更（列削除・型変更・NOT NULL 追加）は段階移行（追加 → バックフィル → 切替 → 旧削除）。ロックの長いDDLは [`lock-short-transactions`](../../.agents/skills/supabase-postgres-best-practices/references/lock-short-transactions.md) を参照。
- 大きいテーブルへのインデックスは `CREATE INDEX CONCURRENTLY`（ただしトランザクション外）。

## 命名

- **識別子は小文字 `snake_case`**。引用符付き識別子（`"CamelCase"`）は使わない（[`schema-lowercase-identifiers`](../../.agents/skills/supabase-postgres-best-practices/references/schema-lowercase-identifiers.md)）。
- テーブルは**複数形**（`tenants`, `watchlists`, `daily_term_stats`）。列は単数。
- 主キーは `id`。外部キーは `<参照先単数>_id`（`tenant_id`, `term_slug`）。
- boolean は `is_`/`has_` 接頭辞（`is_primary`, `is_required`）。時刻は `_at` 接尾辞で `timestamptz`（`created_at`, `last_ok_at`）。
- 制約・インデックスは役割が分かる名前: インデックス `idx_<table>_<cols>`、部分/特殊は説明的（`destinations_one_primary_per_tenant`）。ポリシーは `tenant_isolation` / `user_isolation` / `<table>_modify` など意図名。

## 定義順（CREATE TABLE 内の列順）

「読む順 = 重要度順」。

1. `id`（主キー）
2. **テナント/所有キー**（`tenant_id` — グローバル共有テーブルでは `tenant_id uuid`（NULL 可）、テナント専用は `NOT NULL`）
3. 外部キー（親への参照）
4. 本体の属性（業務的に重要な順）
5. ステータス・フラグ・カウンタ
6. 派生・生成列（`GENERATED ALWAYS AS ... STORED`）
7. `created_at` / `updated_at`（末尾）
8. テーブル制約（複合 `UNIQUE` / 複合 `PRIMARY KEY` / 複合 `FOREIGN KEY`）

```sql
CREATE TABLE IF NOT EXISTS watchlists (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name)
);
```

- 列定義は型・修飾子を**縦に揃える**（既存マイグレーションの整形に合わせる。4スペースインデント）。
- セクションは `-- ----…----` の区切りコメントで分け、テーブルごとに「何のためのテーブルか」を1行。

## 型の選択

- 文字列は **`text`**（`varchar(n)` を使わない。長さ制約は `CHECK` か境界バリデーションで）。
- 時刻は **`timestamptz`**（`timestamp` は使わない。UTC で保存）。日付集計キーは `date`。
- ID は `uuid DEFAULT gen_random_uuid()`。連番が要る所だけ `bigint GENERATED ALWAYS AS IDENTITY`。
- 列挙は `text` + `CHECK (col IN (...))`（既存方針）。enum 型は migration が重くなるため避ける。
- 金額・正確な数値は `numeric`。スコア等の近似は `real`/`double precision`。
- 構造化データは `jsonb`（`json` でなく）。検索するキーは生成列か式インデックスに出す。
- ベクトルは `vector(768)`（pgvector）。配列は `text[]`。
- 型・制約の指針は [`schema-data-types`](../../.agents/skills/supabase-postgres-best-practices/references/schema-data-types.md) / [`schema-constraints`](../../.agents/skills/supabase-postgres-best-practices/references/schema-constraints.md)。

## 制約

- **不変条件は DB で守る**。アプリのバリデーションに頼り切らない（複数経路から書かれる）。
- `NOT NULL` を既定に。本当に省略可能なものだけ NULL 可。
- 外部キーに `ON DELETE` を明示（`CASCADE` / `SET NULL` を意図して選ぶ）。
- ビジネスルールは `CHECK` と複合 `UNIQUE`、部分ユニークインデックス（`WHERE` 付き）で表す。
- **テナント越境を構造で塞ぐ**: 子が親のテナントを跨げないよう**複合外部キー** `(watchlist_id, tenant_id)` を使う（[`design/13`](../../design/13_testing_strategy.md) の越境マトリクス）。

## インデックス

- **外部キーには基本インデックスを張る**（[`schema-foreign-key-indexes`](../../.agents/skills/supabase-postgres-best-practices/references/schema-foreign-key-indexes.md)）。
- RLS と相性の良い**複合インデックスの先頭に `tenant_id`**（`(tenant_id, created_at DESC)` 等）。ポリシーが参照する列は必ず索引化（[RLS パフォーマンス](#rls-行レベルセキュリティ最重要)）。
- 一部行だけ対象なら**部分インデックス**（`WHERE matched_id IS NOT NULL`、`WHERE is_primary`）。
- 全文検索は `GENERATED` な `tsvector` + **GIN**、ベクトル近傍は **HNSW**（`vector_cosine_ops`）。
- 当て推量で張らない。`EXPLAIN ANALYZE`（[`monitor-explain-analyze`](../../.agents/skills/supabase-postgres-best-practices/references/monitor-explain-analyze.md)）で必要を確認してから。使われないインデックスは書き込みコストだけの負債。

## RLS（行レベルセキュリティ・最重要）

軽量マルチテナント（[`design/04`](../../design/04_security_multitenant.md)）: **本体コーパスはグローバル共有**、分離するのは**テナントオーバーレイ**（`tenant_settings` / `watchlists` / `watchlist_items` / プライベート `sources`）のみ。過剰分離しない。

- アプリは `portfolio_app`（**`NOBYPASSRLS`**）で接続。マイグレーション/グローバル書込は `portfolio_owner`。
- 対象テーブルは `ENABLE` に加え **`FORCE ROW LEVEL SECURITY`**（所有者でもポリシーを通す）。
- テナント文脈はトランザクション先頭で **`SET LOCAL app.tenant_id`**（接続プールに漏らさないため必ず `LOCAL`）。アプリ層が JWT から解決した値を入れる。**クライアント由来の tenant id を信頼しない。**
- ポリシーは `current_setting('app.tenant_id', true)::uuid` を使う。第2引数 `true`（missing_ok）で**未設定時は NULL → 空集合**になり、例外でなく**フェイルセーフ**で閉じる。
- `USING`（読める行）と `WITH CHECK`（書ける行）を**両方**書く。`DROP POLICY IF EXISTS` → `CREATE POLICY` で冪等に。

```sql
-- tenant overlay: テナント専用。自テナントの行だけ読めて書ける
ALTER TABLE watchlists ENABLE ROW LEVEL SECURITY;
ALTER TABLE watchlists FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_isolation ON watchlists;
CREATE POLICY tenant_isolation ON watchlists
  USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);
```

```sql
-- 混在テーブル sources: グローバル(tenant_id IS NULL) は全員読める。
-- 書込は自テナント分のみ＝グローバルコーパス汚染と SSRF 起点の注入を塞ぐ
DROP POLICY IF EXISTS sources_read ON sources;
CREATE POLICY sources_read ON sources
  FOR SELECT
  USING (tenant_id IS NULL OR tenant_id = current_setting('app.tenant_id', true)::uuid);

DROP POLICY IF EXISTS sources_modify ON sources;
CREATE POLICY sources_modify ON sources
  FOR ALL
  USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid AND tenant_id IS NOT NULL);
```

- RLS 性能: ポリシー式は行ごとに評価される。`current_setting(...)` は安定なので、**比較する列を索引化**しておけば効く（[`security-rls-performance`](../../.agents/skills/supabase-postgres-best-practices/references/security-rls-performance.md)）。サブクエリ型ポリシー（`tenants` の所属判定など）は特に索引と件数に注意。
- **RLS はテストで恒久ガード**: 越境マトリクス（SELECT/INSERT/UPDATE/DELETE × 他テナント）と「未設定→空集合」フェイルセーフを CI 必須通過に（[`design/13`](../../design/13_testing_strategy.md)）。グローバル共有が**全テナントから読める**ことも検証（過剰分離の検出）。

## アプリから発行する SQL

- **常にパラメータ化**（`$1, $2`）。文字列連結で値を埋めない（SQL インジェクション）。識別子を動的にしたい場合はホワイトリスト経由。
- 読み取りは必要な列だけ `SELECT`（`SELECT *` をプロダクションコードで使わない）。
- **N+1 を作らない**（[`data-n-plus-one`](../../.agents/skills/supabase-postgres-best-practices/references/data-n-plus-one.md)）。ループ内クエリでなく `JOIN` か `WHERE id = ANY($1)`。
- 一括書込は**バッチ**（[`data-batch-inserts`](../../.agents/skills/supabase-postgres-best-practices/references/data-batch-inserts.md)）、再投入は `INSERT ... ON CONFLICT`（[`data-upsert`](../../.agents/skills/supabase-postgres-best-practices/references/data-upsert.md)）で冪等に。
- ページングは `OFFSET` でなくキーセット（[`data-pagination`](../../.agents/skills/supabase-postgres-best-practices/references/data-pagination.md)）。
- トランザクションは短く。ジョブ間の重複処理は `SELECT ... FOR UPDATE SKIP LOCKED`（[`lock-skip-locked`](../../.agents/skills/supabase-postgres-best-practices/references/lock-skip-locked.md)）。

## コメント

- 各テーブルに「何のためか」を1行（既存マイグレーションの作法）。非自明な制約・部分インデックスの WHERE 条件には理由を添える。
- `IMMUTABLE`/`STABLE`/`VOLATILE` の選択理由など、後で踏みがちな落とし穴はコメントで残す（既存 `make_search_tsvector` の例）。
- SQL キーワードは大文字、識別子は小文字で視認性を上げる。

## 禁止 / アンチパターン

- 適用済みマイグレーションの編集 / 番号の使い回し。
- `varchar(n)` / `timestamp`（タイムゾーン無し）/ 引用符付き CamelCase 識別子。
- RLS 対象テーブルで `FORCE` 無し、`WITH CHECK` 無し、`current_setting` の missing_ok（`true`）無しで例外を誘発。
- `SET app.tenant_id`（`LOCAL` 無し）でプール接続に文脈を漏らす。
- アプリでの SQL 文字列連結、`SELECT *`、ループ内 N+1。
- 当て推量インデックス / 外部キー無索引。

## レビューチェックリスト

- [ ] 新規マイグレーションは新番号・前進のみ（既存を編集していない）
- [ ] 識別子は小文字 snake_case、型は `text`/`timestamptz`/`uuid`/`jsonb`
- [ ] 列順が id → tenant_id → FK → 属性 → 時刻、制約は末尾
- [ ] `NOT NULL`・`CHECK`・`ON DELETE`・複合 `UNIQUE`/FK で不変条件を DB で守っている
- [ ] テナント越境を複合 FK `(child_id, tenant_id)` で構造的に塞いでいる
- [ ] RLS 対象に `ENABLE` + `FORCE`、`USING` + `WITH CHECK`、`current_setting('app.tenant_id', true)`
- [ ] ポリシー比較列が索引化されている／グローバル共有を過剰分離していない
- [ ] アプリ SQL がパラメータ化・必要列のみ・N+1 無し
- [ ] RLS 越境マトリクスとフェイルセーフのテストを更新（CI 必須通過）
- [ ] `make lint.sql`（sqlfluff、または pre-commit）が緑
