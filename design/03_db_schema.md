# 03. DB スキーマ

## エンティティ全体図

```
users (内部 uuid + OIDC sub、JIT プロビジョニング)
    │
    └─< user_tenants >─── tenants ─────┐
                                       │
       既存Excelから移行 ──────────────┤
                                       ├─< categories
                                       ├─< validation_rules
                                       ├─< field_definitions
                                       ├─< knowledge_entries（メタのみ／検索文書は ES）
       新規追加 ───────────────────────┤
                                       ├─< destinations（+secret参照）
                                       ├─< inquiries（本文無し）
                                       └─< unclassified_queue
```

Postgres は構造化メタ（編集の source of truth）を保持する。全文・ベクトル検索は Elasticsearch が担当し、`knowledge_entries` の書込時に ES へ upsert 同期する（ES マッピングは後述「Elasticsearch インデックス」節を参照）。

## テーブル定義

### `users` — ログインユーザー（OIDC sub 保持）

内部 ID は uuid で発番し、OIDC（OpenID Connect）の `sub`（プロバイダ依存の不透明文字列で UUID とは限らない）は一意キーとして別に保持する。初回ログイン時に `oidc_sub` で upsert する JIT（Just-In-Time）プロビジョニングで挿入する。

```sql
CREATE TABLE users (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),  -- 内部ID（FK はこれを参照）
  oidc_sub    text UNIQUE NOT NULL,                          -- OIDC の sub（不透明文字列、UUID とは限らない）
  email       text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
```

### `tenants` — 組織

```sql
CREATE TABLE tenants (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        text UNIQUE NOT NULL,   -- URL用: /t/acme/chat
  name        text NOT NULL,           -- 表示名
  created_at  timestamptz NOT NULL DEFAULT now()
);
```

### `user_tenants` — メンバーシップ（多対多）

```sql
CREATE TABLE user_tenants (
  user_id    uuid REFERENCES users(id) ON DELETE CASCADE,
  tenant_id  uuid REFERENCES tenants(id) ON DELETE CASCADE,
  role       text NOT NULL CHECK (role IN ('admin','member')),
  joined_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, tenant_id)
);
```

`admin`：マスタ編集・destination 設定可。
`member`：問い合わせのみ。

### `categories`

既存 Streamlit 版 `categories` シート相当。

```sql
CREATE TABLE categories (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  code                  text NOT NULL,                 -- 既存の "CAT01" 相当
  name                  text NOT NULL,
  emoji                 text,
  sort_order            int  NOT NULL DEFAULT 0,
  required_field_codes  text[] NOT NULL DEFAULT '{}',  -- 旧「起票時必須情報」
  created_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, code)
);
```

### `validation_rules`

既存 `validations` シート相当。

```sql
CREATE TABLE validation_rules (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name           text NOT NULL,
  min_length     int,
  max_length     int,
  regex          text,
  error_message  text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, name)
);
```

### `field_definitions`

既存 `field_types` シート相当 + `is_multi` 新規。

```sql
CREATE TABLE field_definitions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  code                text NOT NULL,
  field_type          text NOT NULL,   -- text/text_short/choice/radio/multi/date/time/datetime/number/bool/file
  is_required         boolean NOT NULL DEFAULT false,
  is_multi            boolean NOT NULL DEFAULT false,   -- ★複数項目フラグ
  question            text,
  choices             text[],
  validation_rule_id  uuid REFERENCES validation_rules(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, code)
);
```

### `knowledge_entries`（★ 最重要テーブル）

既存 `knowledge` シート相当 + 多数の拡張。**構造化メタは Postgres、検索用テキストとベクトルは Elasticsearch** に持つ。Postgres 側は編集の source of truth であり、書込時に ES ドキュメントへ upsert 同期する。

```sql
CREATE TABLE knowledge_entries (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  category_id           uuid NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  name                  text NOT NULL,                  -- 問題名

  -- 検索用テキスト群（ES へ同期）
  keywords              text[] NOT NULL DEFAULT '{}',   -- 短い検索キーワード
  example_queries       text[] NOT NULL DEFAULT '{}',   -- ★言い換え・組織用語含む（同義語管理を統合）

  -- フォーム制御
  required_field_codes  text[] NOT NULL DEFAULT '{}',

  -- 3段階エスカレーション
  auto_resolution       text,                            -- 自動回答（あれば起票しない）
  guidance_message      text,                            -- 起票前ガイダンス
  -- 両方なし → 直接フォーム → 起票

  -- 起票時メタ
  ticket_priority       text NOT NULL DEFAULT 'normal'
    CHECK (ticket_priority IN ('low','normal','high','urgent')),

  -- 検索ランキング統計（トリガで更新後、ES ドキュメントへ同期）
  match_count           int  NOT NULL DEFAULT 0,         -- 過去マッチ回数（起票成功時に+1）

  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, name)
);
```

embedding ベクトル・全文検索用テキスト・`embedding_model` は Postgres には持たず、ES ドキュメント側の概念とする（次節参照）。

### `destinations` — 起票先設定

```sql
CREATE TABLE destinations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  kind            text NOT NULL CHECK (kind IN ('redmine','github_issues')),
  name            text NOT NULL,                       -- "社内Redmine" 等
  config          jsonb NOT NULL,                       -- URL, project_id 等の非秘匿設定
  secret_ref      text,                                 -- Secret Manager のリソース名/バージョン
  is_primary      boolean NOT NULL DEFAULT false,
  field_mapping   jsonb,                                -- ticket_priority 等のサービス固有変換
  sort_order      int NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- 1テナントに1つだけプライマリ
CREATE UNIQUE INDEX destinations_one_primary_per_tenant
  ON destinations (tenant_id) WHERE is_primary;
```

### `inquiries` — 問い合わせ履歴（メタのみ、本文無し）

「**本文は外部システムにある**」という戦略の核心テーブル。

```sql
CREATE TABLE inquiries (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id               uuid REFERENCES users(id) ON DELETE SET NULL,
  category_id           uuid REFERENCES categories(id),
  matched_knowledge_id  uuid REFERENCES knowledge_entries(id),
  raw_query             text,                            -- 自然言語入力（短いので保持）
  destination_id        uuid REFERENCES destinations(id),
  external_ticket_id    text,                            -- 起票先のチケットID
  external_ticket_url   text,
  status                text NOT NULL,                   -- created / failed / auto_resolved
  match_strategy        text,                            -- dropdown / keyword / hybrid / llm
  confidence_score      real,                            -- ナレッジギャップ検出用
  resolved              boolean,                         -- 自動回答時の「解決した？」答え
  draft_fields          jsonb,                            -- 起票失敗時の短期一時保存
  created_at            timestamptz NOT NULL DEFAULT now()
);
```

`draft_fields` は失敗時のリトライ用、起票成功時は NULL クリア。

### `unclassified_queue` — 未分類キュー

```sql
CREATE TABLE unclassified_queue (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id         uuid REFERENCES users(id) ON DELETE SET NULL,
  raw_query       text NOT NULL,                       -- 自然言語入力
  freeform_body   text,                                 -- 「新規問題として」のフォーム入力
  status          text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','added_to_master','discarded')),
  reviewed_by     uuid REFERENCES users(id),
  reviewed_at     timestamptz,
  review_note     text,
  created_at      timestamptz NOT NULL DEFAULT now()
);
```

管理画面で admin がレビュー → マスタ追加 or 破棄。

## Elasticsearch インデックス

knowledge 検索ドキュメントは Elasticsearch（または OpenSearch）に持つ。Postgres の `knowledge_entries` 書込時に、検索対象のフィールドを ES ドキュメントへ upsert 同期する。マッピング例：

```json
{
  "mappings": {
    "properties": {
      "tenant_id":        { "type": "keyword" },
      "entry_id":         { "type": "keyword" },
      "category_id":      { "type": "keyword" },
      "name":             { "type": "text", "analyzer": "kuromoji", "fields": { "raw": { "type": "keyword" } } },
      "keywords":         { "type": "text", "analyzer": "kuromoji", "fields": { "raw": { "type": "keyword" } } },
      "example_queries":  { "type": "text", "analyzer": "kuromoji" },
      "embedding":        { "type": "dense_vector", "dims": 768, "similarity": "cosine" },
      "embedding_model":  { "type": "keyword" },
      "match_count":      { "type": "integer" }
    }
  }
}
```

`tenant_id` はインデックスの routing キーとしても利用する。

完全一致（分類フロー④）は `name.raw` / `keywords.raw` の keyword サブフィールドに対する `term` クエリで行う（解析済み text フィールドでは exact 一致しないため）。

**全クエリは `tenant_id` でフィルタ必須**：ES には Postgres のような RLS が存在しないため、テナント分離はクエリ側で `tenant_id` フィルタを強制することで担保する（詳細は [04_security_multitenant.md](04_security_multitenant.md)）。

`embedding` は Python FastAPI 側で推論したベクトル（768 次元、cosine 類似度）を格納する。`embedding_model` はそのベクトルを生成したモデル名で、検索対象の出し分けに使う（後述「マスタモデル変更時の対応」）。

`match_count` は Postgres のトリガ（後述）で更新された後、ES ドキュメントへ同期する。

### 同期と整合性

Postgres（source of truth）と ES（検索）の二重書き込みになるため、整合性方針を決めておく:

- `knowledge_entries` の作成 / 更新 / 削除時に、同一リクエスト内で ES へ upsert / delete する（ベストエフォート）。
- ES 反映は失敗しうるため、失敗はリトライキューに積み、定期の再インデックスジョブで Postgres を真として突合・修復する（結果整合）。
- `match_count` 更新（トリガ）も非同期で ES に反映され、検索ランキングへの反映は短時間遅延しうる。
- 検索は ES 主、整合性が要る編集・表示は Postgres 主、と読み分ける。

## インデックス

```sql
-- 通常検索（btree）
CREATE INDEX ON knowledge_entries (tenant_id, category_id);
CREATE INDEX ON inquiries (tenant_id, created_at DESC);
CREATE INDEX ON inquiries (matched_knowledge_id) WHERE matched_knowledge_id IS NOT NULL;
CREATE INDEX ON unclassified_queue (tenant_id, status);
```

全文（BM25）・ベクトル（近似最近傍）検索は Elasticsearch が担当するため、Postgres 側に HNSW / GIN インデックスは作らない。Postgres には構造化メタへの btree インデックスのみを置く。

## RLS（テナント分離ポリシー）

Node のデータ層が Postgres に直接接続する構成のため、`auth.uid()` は利用しない。アプリ側で OIDC トークン → `user_tenants` 照合まで済ませ、確定した `tenant_id` を `SET LOCAL app.tenant_id = ...` でセッション変数に流す。RLS ポリシーはその変数だけを参照する（設計の根拠は [04_security_multitenant.md](04_security_multitenant.md) の「なぜ `auth.uid()` ベースにしないか」参照）。

```sql
ALTER TABLE knowledge_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON knowledge_entries
  USING       (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK  (tenant_id = current_setting('app.tenant_id', true)::uuid);
```

`current_setting('app.tenant_id', true)` の第二引数（missing_ok）により、セッション変数未設定時は例外ではなく NULL → 空集合（フェイルセーフ）になる。

`categories` / `validation_rules` / `field_definitions` / `destinations` / `inquiries` / `unclassified_queue` / `tenant_public_keys` も同じパターン。

`tenants` 自体は **自分の所属テナントのみ閲覧可能**：

```sql
CREATE POLICY tenant_self_visible ON tenants
  USING (id = current_setting('app.tenant_id', true)::uuid);
```

`user_tenants` は **自分の所属レコードのみ閲覧可能**。`user_id` はアプリが `sub` から解決した内部 `users.id` を別セッション変数に流す：

```sql
CREATE POLICY membership_self_visible ON user_tenants
  USING (user_id = current_setting('app.user_id', true)::uuid);
```

アプリは Node のデータ層で、リクエスト単位トランザクションの先頭に `SET LOCAL app.user_id = ...` と `SET LOCAL app.tenant_id = ...` の 2 本を発行する。匿名ウィジェット経由のアクセス用には別変数 `app.widget_tenant_id` を使い、混線を避ける。

スキーマ所有者と接続ロールを分離する（`portfolio_owner` = スキーマ所有・マイグレーション専用、`portfolio_app` = アプリ接続・`NOBYPASSRLS`）。owner はテーブル所有者として RLS をすり抜けうるため、全テーブルに `FORCE ROW LEVEL SECURITY` を設定して owner にも RLS を強制する。詳細は [04_security_multitenant.md](04_security_multitenant.md)。

## トリガー：`match_count` 更新

`inquiries.status='created'` 確定時、対応する `knowledge_entries.match_count` を +1：

```sql
CREATE OR REPLACE FUNCTION increment_match_count()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'created' AND NEW.matched_knowledge_id IS NOT NULL
     AND (OLD.status IS NULL OR OLD.status != 'created') THEN
    UPDATE knowledge_entries
       SET match_count = match_count + 1
     WHERE id = NEW.matched_knowledge_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_increment_match_count
AFTER INSERT OR UPDATE OF status ON inquiries
FOR EACH ROW EXECUTE FUNCTION increment_match_count();
```

更新後の `match_count` は ES ドキュメントへ同期する。

## 既存Excelからの流用度

| 既存シート | 移行先 | 流用度 |
|---|---|---|
| `knowledge` | `knowledge_entries`（+ ES 検索ドキュメント） | 9割流用 + `example_queries` / `match_count` / `ticket_priority` / `auto_resolution` / `guidance_message` 列追加（embedding は ES 側） |
| `field_types` | `field_definitions` | 9割流用 + `is_multi` 追加 |
| `categories` | `categories` | 9割流用、配列化 |
| `validations` | `validation_rules` | そのまま |
| `settings` | アプリ設定（DBではなくENV） | 移行しない |

データ移行スクリプトは Node 想定で AI に書かせる範囲（[09_task_split.md](09_task_split.md) 参照）。

## マスタモデル変更時の対応

ES ドキュメントの `embedding_model` フィールドで混在を許容：

- 既存ドキュメントは古いモデルの embedding を保持
- 新規・更新ドキュメントは新モデルで生成
- バックグラウンドジョブで段階的に再計算
- 検索時、現行モデルと一致しない embedding は **ES 側で `embedding_model` フィルタ** により除外し、BM25 のみで検索

検索対象の出し分けは Postgres ではなく ES 側で行う。これでダウンタイムなしのモデル切替が可能。

## 将来追加されるテーブル（Phase 2 以降）

| テーブル | 用途 | Phase |
|---|---|---|
| `document_chunks` | PDF / Word 等の非構造文書 chunk-based RAG（chunk も ES インデックス前提） | Phase 2 |
| `tenant_public_keys` | 埋め込みウィジェット用の公開APIキー（rate-limited） | MVP（[06_destinations.md](06_destinations.md) と並行設計） |

`tenant_public_keys` は埋め込みウィジェット用：

```sql
CREATE TABLE tenant_public_keys (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  key_hash        text NOT NULL,   -- bcrypt 等のハッシュ
  label           text,             -- "MyCompany Website" 等
  rate_limit_rpm  int NOT NULL DEFAULT 30,
  allowed_origins text[] NOT NULL DEFAULT '{}',
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_used_at    timestamptz
);
```
