# 03. DB スキーマ

## エンティティ全体図

```
auth.users (Supabase Auth が管理)
    │
    └─< user_tenants >─── tenants ─────┐
                                       │
       既存Excelから移行 ──────────────┤
                                       ├─< categories
                                       ├─< validation_rules
                                       ├─< field_definitions
                                       ├─< knowledge_entries（+embedding, +tsvector）
       新規追加 ───────────────────────┤
                                       ├─< destinations（+vault参照）
                                       ├─< inquiries（+embedding、本文無し）
                                       └─< unclassified_queue（+embedding）
```

## テーブル定義

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
  user_id    uuid REFERENCES auth.users(id) ON DELETE CASCADE,
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

既存 `knowledge` シート相当 + 多数の拡張。

```sql
CREATE TABLE knowledge_entries (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id             uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  category_id           uuid NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  name                  text NOT NULL,                  -- 問題名

  -- 検索用テキスト群
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

  -- 検索ランキング統計
  match_count           int  NOT NULL DEFAULT 0,         -- 過去マッチ回数（起票成功時に+1）

  -- 検索用インデックス材料
  embedding             vector(768),
  embedding_model       text,
  search_text           tsvector GENERATED ALWAYS AS (
    to_tsvector('simple',
      name || ' ' ||
      array_to_string(keywords, ' ') || ' ' ||
      array_to_string(example_queries, ' ')
    )
  ) STORED,

  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, name)
);
```

### `destinations` — 起票先設定

```sql
CREATE TABLE destinations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  kind            text NOT NULL CHECK (kind IN ('redmine','github_issues')),
  name            text NOT NULL,                       -- "社内Redmine" 等
  config          jsonb NOT NULL,                       -- URL, project_id 等の非秘匿設定
  secret_vault_id uuid,                                 -- Supabase Vault キーID
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
  user_id               uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  category_id           uuid REFERENCES categories(id),
  matched_knowledge_id  uuid REFERENCES knowledge_entries(id),
  raw_query             text,                            -- 自然言語入力（短いので保持）
  query_embedding       vector(768),                     -- 分析・クラスタリング用
  embedding_model       text,
  destination_id        uuid REFERENCES destinations(id),
  external_ticket_id    text,                            -- 起票先のチケットID
  external_ticket_url   text,
  status                text NOT NULL,                   -- created / failed / auto_resolved
  match_strategy        text,                            -- dropdown / keyword / embedding / hybrid / llm
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
  user_id         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  raw_query       text NOT NULL,                       -- 自然言語入力
  freeform_body   text,                                 -- 「新規問題として」のフォーム入力
  query_embedding vector(768),
  status          text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','added_to_master','discarded')),
  reviewed_by     uuid REFERENCES auth.users(id),
  reviewed_at     timestamptz,
  review_note     text,
  created_at      timestamptz NOT NULL DEFAULT now()
);
```

管理画面で admin がレビュー → マスタ追加 or 破棄。

## インデックス

```sql
-- 通常検索
CREATE INDEX ON knowledge_entries (tenant_id, category_id);
CREATE INDEX ON inquiries (tenant_id, created_at DESC);
CREATE INDEX ON inquiries (matched_knowledge_id) WHERE matched_knowledge_id IS NOT NULL;
CREATE INDEX ON unclassified_queue (tenant_id, status);

-- pgvector：HNSW（高速近似最近傍）
CREATE INDEX ON knowledge_entries USING hnsw (embedding vector_cosine_ops)
  WHERE embedding IS NOT NULL;

-- BM25：GIN（フルテキスト）
CREATE INDEX ON knowledge_entries USING gin (search_text);

-- 未分類キューの embedding はクラスタリング用、HNSW は不要（バッチ処理）
```

`inquiries.query_embedding` には **HNSW を作らない**：リアルタイム検索しない、分析・クラスタリング用なのでバッチで扱う。

## RLS（テナント分離ポリシー）

全テーブルに対して、JWT から取得したユーザIDで所属テナント自動フィルタ：

```sql
ALTER TABLE knowledge_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON knowledge_entries
  USING (tenant_id IN (
    SELECT tenant_id FROM user_tenants
    WHERE user_id = auth.uid()
  ));
```

`categories` / `validation_rules` / `field_definitions` / `destinations` / `inquiries` / `unclassified_queue` も同様。

`tenants` 自体は **所属テナントのみ閲覧可能**：

```sql
CREATE POLICY tenant_self_visible ON tenants
  USING (id IN (
    SELECT tenant_id FROM user_tenants WHERE user_id = auth.uid()
  ));
```

`user_tenants` は **自分の所属レコードのみ閲覧可能**：

```sql
CREATE POLICY membership_self_visible ON user_tenants
  USING (user_id = auth.uid());
```

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

## 既存Excelからの流用度

| 既存シート | 移行先 | 流用度 |
|---|---|---|
| `knowledge` | `knowledge_entries` | 9割流用 + `embedding` / `tsvector` / `example_queries` / `match_count` / `ticket_priority` / `auto_resolution` / `guidance_message` 列追加 |
| `field_types` | `field_definitions` | 9割流用 + `is_multi` 追加 |
| `categories` | `categories` | 9割流用、配列化 |
| `validations` | `validation_rules` | そのまま |
| `settings` | アプリ設定（DBではなくENV） | 移行しない |

データ移行スクリプトは AI に書かせる範囲（[09_task_split.md](09_task_split.md) 参照）。

## マスタモデル変更時の対応

`knowledge_entries.embedding_model` 列で混在を許容：

- 既存行は古いモデルの embedding を保持
- 新規行・更新行は新モデルで生成
- バックグラウンドジョブで段階的に再計算
- 検索時、現行モデルと一致しない embedding は除外して BM25 のみで検索

これでダウンタイムなしのモデル切替が可能。

## 将来追加されるテーブル（Phase 2 以降）

| テーブル | 用途 | Phase |
|---|---|---|
| `document_chunks` | PDF / Word 等の非構造文書 chunk-based RAG | Phase 2 |
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
