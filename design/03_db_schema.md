# 03. データモデル（3 層）

データは 3 層に分ける。**Postgres = エンティティ / 設定（編集の source of truth・RLS の対象）**、**Elasticsearch = 文書（エビデンス検索・関連トピック）**、**BigQuery = 出現ファクト + 日次集計（トレンド・検知の素）**。役割分担の根拠は [07_data_strategy.md](07_data_strategy.md)。

```
[PostgreSQL + RLS]                     [Elasticsearch]            [BigQuery]
 users / tenants / user_tenants         documents                 occurrences（言及ファクト）
 sources（収集ソース・ヘルス）            ├ title/snippet           term_metrics（採用メトリクス時系列）
 terms / term_aliases（用語辞書 F9）      ├ term_slugs[]            daily_term_stats（日次集計）
 term_identities（レジストリ対応付け）     └ embedding(kNN)          （+公開DS: GitHub Archive 等）
 detections（検知 F2）                    = F6 エビデンス/関連トピック
 summaries（要約 F3 キャッシュ）
 tenant_settings / watchlists（テナント）
```

**言及（mentions）と採用（metrics）は別ファクトとして持つ**（[14_data_sources.md](14_data_sources.md) の実地調査を反映）。HN/Qiita/dev.to/SO/Lobsters/GitHub Trending が生む「言及」は `occurrences`（文書に紐づく離散イベント）、npm/PyPI/crates.io の DL 数や GitHub Archive のスター数は「採用」の連続時系列で `term_metrics` に入れる。DL 数を言及に混ぜると `share` / `distinct_sources` が壊れる（react の週 1.3 億 DL は mention ではない）。

グローバル（共有）データはテナント非依存。テナント単位は `tenant_settings` / `watchlists` / プライベート `sources` のみ（**軽量マルチテナント**）。

---

## Postgres テーブル

### `users` — ログインユーザー（OIDC sub 保持）

内部 ID は uuid で発番し、OIDC の `sub`（プロバイダ依存の不透明文字列・UUID とは限らない）は一意キーとして別に保持する。初回ログイン時に `oidc_sub` で upsert する JIT プロビジョニング。

```sql
CREATE TABLE users (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  oidc_sub    text UNIQUE NOT NULL,
  email       text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
```

### `tenants` / `user_tenants`

```sql
CREATE TABLE tenants (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        text UNIQUE NOT NULL,   -- /t/acme/...
  name        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE user_tenants (
  user_id    uuid REFERENCES users(id) ON DELETE CASCADE,
  tenant_id  uuid REFERENCES tenants(id) ON DELETE CASCADE,
  role       text NOT NULL CHECK (role IN ('admin','member')),
  joined_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, tenant_id)
);
```

`admin`：ウォッチリスト編集・BYOK 設定・（プライベート）ソース管理可。`member`：閲覧のみ。

### `sources` — 収集ソース登録 + 収集ヘルス（F8）

API / フィード / クロールの取得元。`tenant_id` が NULL なら**グローバル公開ソース**（共有コーパスを作る）、設定済みなら**テナント専用プライベートソース**。

```sql
CREATE TABLE sources (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid REFERENCES tenants(id) ON DELETE CASCADE,  -- NULL = グローバル
  kind          text NOT NULL CHECK (kind IN ('api','feed','crawl')),
  name          text NOT NULL,                       -- "GitHub Trending" / "Hacker News API"
  locale        text NOT NULL DEFAULT 'global' CHECK (locale IN ('global','jp')),
  config        jsonb NOT NULL DEFAULT '{}',          -- endpoint / query / セレクタ等
  -- 礼儀正しさ・コンプラ
  robots_policy text NOT NULL DEFAULT 'respect',      -- robots 方針メモ
  rate_limit_rpm int NOT NULL DEFAULT 20,
  enabled       boolean NOT NULL DEFAULT true,
  -- 収集ヘルス（F8）
  last_run_at          timestamptz,
  last_ok_at           timestamptz,
  last_status          text CHECK (last_status IN ('ok','failed','parser_broken')),
  last_error           text,
  consecutive_failures int NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, name)
);
```

`last_status = 'parser_broken'`（必須フィールド欠落 / 取得件数 0）と `consecutive_failures` が F8 アラートの根拠。

### `terms` — 正規化済み技術用語（F9 の核）

```sql
CREATE TABLE terms (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug          text UNIQUE NOT NULL,         -- 正規キー: 'kubernetes'
  display_name  text NOT NULL,                -- 'Kubernetes'
  domain_tag    text,                          -- 粗いドメイン（language/framework/tool/infra/ai）任意・フィルタ用
  description   text,
  is_excluded   boolean NOT NULL DEFAULT false, -- 除外語（一般語 "app"/"data" 等）
  disambig_note text,                          -- 曖昧性解消メモ（"Go"=言語）
  first_seen_at timestamptz,                    -- 初出（新出検知の確定で記録）
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
```

### `term_aliases` — 別名 → 正規用語（表記揺れ吸収）

```sql
CREATE TABLE term_aliases (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  term_id      uuid NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
  alias        text NOT NULL,                 -- 'k8s' / 'Kubernetes' 表記揺れ
  locale       text,
  is_ambiguous boolean NOT NULL DEFAULT false, -- 文脈依存（"Go"）→ 抽出時に文脈判定を要する
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (alias, locale)
);
```

`is_ambiguous = true` の別名は、抽出時に周辺文脈（共起語）で正規用語を確定してから出現を記録する（[05_search_classification.md](05_search_classification.md)）。

### `term_identities` — term ↔ レジストリ識別子の対応付け

採用メトリクス（DL 数・スター）を term に結びつけるための対応表。「react」= npm パッケージ `react` + GitHub repo `facebook/react` のように、**同一技術が複数レジストリに別 ID で存在する**ため必要（用語の表記揺れを吸収する `term_aliases` とは別物）。

```sql
CREATE TABLE term_identities (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  term_id      uuid NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
  source       text NOT NULL,        -- 'npm' / 'pypi' / 'crates_io' / 'github_repo'
  external_id  text NOT NULL,        -- 'react' / 'requests' / 'serde' / 'facebook/react'
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source, external_id)
);
```

MVP は名前のヒューリスティック一致（slug = パッケージ名）から始め、衝突・別名（例: slug `nextjs` ↔ npm `next`）は手動で登録する。metrics 収集ワーカーはこの表を巡回リストとして使う。

### `detections` — 検知イベント（F2 出力）

```sql
CREATE TABLE detections (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  term_id       uuid NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
  type          text NOT NULL CHECK (type IN ('emerging','rising','declining')),
  locale        text NOT NULL DEFAULT 'global',
  window_start  date NOT NULL,
  window_end    date NOT NULL,
  score         real NOT NULL,                 -- z-score / surprise 等
  distinct_sources int,                          -- 新出のクロスソース裏取り数
  evidence      jsonb,                            -- 代表文書参照（doc_id/url）
  status        text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','confirmed','dismissed')),
  detected_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (term_id, type, locale, window_end)
);
```

`status` は人手レビューのフィードバック（誤検知 → `dismissed` → 除外語/別名へ反映）。

### `summaries` — 技術サマリ（F3 キャッシュ）

```sql
CREATE TABLE summaries (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  term_id       uuid NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
  locale        text NOT NULL DEFAULT 'global',
  model         text NOT NULL,
  content       text NOT NULL,
  evidence      jsonb NOT NULL DEFAULT '[]',    -- 出典 document 参照
  related_terms uuid[] NOT NULL DEFAULT '{}',    -- 関連トピック（embedding 近傍 / 共起）
  generated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (term_id, locale)
);
```

**システム既定キーで生成するグローバルキャッシュ**。`(term_id, locale)` で upsert（`model` 変更時も同キーで更新）。テナントの BYOK キーで生成する要約は**このグローバルキャッシュに保存せず**オンデマンド生成する（他テナントへの混入・コストの付け替えを防ぐ）。キーの使い分けは [05_search_classification.md](05_search_classification.md) / [04_security_multitenant.md](04_security_multitenant.md)。

### `tenant_settings` — テナント設定（BYOK）

```sql
CREATE TABLE tenant_settings (
  tenant_id      uuid PRIMARY KEY REFERENCES tenants(id) ON DELETE CASCADE,
  llm_secret_ref text,                          -- Secret Manager リソース名（BYOK Gemini キー）
  default_locale text NOT NULL DEFAULT 'global',
  updated_at     timestamptz NOT NULL DEFAULT now()
);
```

### `watchlists` / `watchlist_items` — 追跡（テナント単位）

```sql
CREATE TABLE watchlists (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, name),
  UNIQUE (id, tenant_id)            -- 子の複合 FK 用（親子のテナント一致を強制）
);

CREATE TABLE watchlist_items (
  watchlist_id uuid NOT NULL,
  tenant_id    uuid NOT NULL,                                          -- RLS 用に冗長保持
  term_id      uuid NOT NULL REFERENCES terms(id) ON DELETE CASCADE,
  added_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (watchlist_id, term_id),
  -- 親 watchlist と tenant_id が一致する組しか許さない（他テナントの watchlist にぶら下げられない）
  FOREIGN KEY (watchlist_id, tenant_id) REFERENCES watchlists(id, tenant_id) ON DELETE CASCADE
);
```

---

## Elasticsearch インデックス（`documents`）

収集した各アイテム（記事 / HN ストーリー / リリース / Trending エントリ）を 1 文書として格納。**本文全文は持たず、メタ + 短い文脈スニペット + 抽出用語 + embedding のみ**（[07_data_strategy.md](07_data_strategy.md) のデータ最小化）。

```json
{
  "mappings": {
    "properties": {
      "doc_id":       { "type": "keyword" },
      "source_id":    { "type": "keyword" },
      "source_kind":  { "type": "keyword" },
      "locale":       { "type": "keyword" },
      "url":          { "type": "keyword" },
      "title":        { "type": "text", "analyzer": "kuromoji" },
      "snippet":      { "type": "text", "analyzer": "kuromoji" },
      "term_slugs":   { "type": "keyword" },
      "embedding":    { "type": "dense_vector", "dims": 768, "index": true, "similarity": "cosine" },
      "content_hash": { "type": "keyword" },
      "popularity":   { "type": "integer" },
      "published_at": { "type": "date" },
      "fetched_at":   { "type": "date" }
    }
  }
}
```

- **`doc_id` は `source:ソース内ID` の複合キー**（例 `hackernews:8863` / `qiita:d5349e...` / `lobsters:esvncd`）。ソース内 ID の型はバラバラ（int / hex / slug）なので文字列連結で統一し、冪等 upsert のキーにする。
- **`popularity`** はソース相対の人気度（points / likes_count / score 等）。表示とソース内ソート専用で、**ソース間の集計には使わない**。
- **`published_at` は Adapter が UTC 正規化済み**の値（[06_destinations.md](06_destinations.md)）。GitHub Trending のように絶対日付が無いソースは取得時刻を入れる。
- **F6 エビデンス**: 用語 → `term_slugs` で該当文書を引き、`title` / `snippet` / `url`（リンク）を出す。`snippet` は用語を含む短い文脈（上限文字数）で、本文全文ではない。
- **関連トピック**: 用語 embedding の **kNN 近傍**、または用語の共起から算出（固定タクソノミの代替）。
- **dedup**: `content_hash`（完全一致）+ `embedding` kNN（近重複）。
- MVP の `documents` は**グローバル公開コーパス**で `tenant_id` を持たない。プライベートソース文書は `tenant_id` を付与しクエリでフィルタする（fast-follow、[04_security_multitenant.md](04_security_multitenant.md) の ES テナント分離節と同じ choke-point を使う）。
- **保持期間 / 容量**: `documents`（特に 768 次元 embedding）は蓄積一方なので、`published_at` が一定期間（初期: 1 年）より古く参照の無い文書は ILM（index lifecycle management）で削除 / cold 移行する。MVP は手動 reindex で運用し ILM 自動化は Phase 2（[07_data_strategy.md](07_data_strategy.md) 保持・コスト）。

---

## BigQuery テーブル（DWH）

### `occurrences` — 言及ファクト

抽出・正規化後、**言及**を 1 行 = 1（用語 × 文書）で追記する。日付パーティション + `term_slug` クラスタリングでスキャン量を抑える。1 言及 = 1 行であり、人気度（points / likes / score）は**ここに混ぜない**（ソース相対値で非可換。文書側 = ES `documents.popularity` に保持し、表示・ソース内ソートにのみ使う）。

| 列 | 型 | 備考 |
|---|---|---|
| `occurred_date` | DATE | パーティションキー（文書の published_at 由来） |
| `term_slug` | STRING | クラスタリングキー（正規化済み） |
| `source_id` | STRING | |
| `source_kind` | STRING | api / feed / crawl |
| `locale` | STRING | global / jp |
| `doc_id` | STRING | ES `documents` と対応 |
| `weight` | FLOAT64 | **抽出位置の重み**（タイトル出現 > 本文等）。人気度ではない |

**冪等性（重要）**: BigQuery に UNIQUE 制約は無い。`occurrences` は `(occurred_date, doc_id, term_slug)` を論理キーとし、取り込みは `MERGE`（または `WHERE NOT EXISTS`）で**冪等 upsert** する。リトライ・再インデックスで同一行が二重投入されると `daily_term_stats` の `mentions` / `distinct_sources` が水増しされ検知が壊れるため、二重排除は必須。

**プライベートソースの隔離**: テナント専用（プライベート）ソース由来の出現は、グローバル `occurrences` / `daily_term_stats` に**入れない**（テナントの非公開な関心が他テナントのトレンドへ漏れるのを防ぐ。fast-follow の不変条件）。

### `term_metrics` — 採用メトリクス時系列（言及とは別ファクト）

npm / PyPI / crates.io の日次ダウンロード数、GitHub Archive のスター付与数など、**文書を持たない連続量**。`term_identities` を巡回リストとして metrics ワーカーが取り込む。

| 列 | 型 | 備考 |
|---|---|---|
| `metric_date` | DATE | パーティションキー |
| `term_slug` | STRING | クラスタリングキー（`term_identities` 経由で解決） |
| `source` | STRING | npm / pypi / crates_io / github_archive |
| `metric` | STRING | downloads / stars |
| `value` | INT64 | 当日の値 |

- 冪等キーは `(metric_date, term_slug, source, metric)`（`MERGE` で upsert）。
- **役割分担**: `occurrences`（言及）が**発見・新出**を担い、`term_metrics`（採用）が**裏付け・急上昇の確証**を担う。「言及も DL も伸びている」が最強の rising シグナル（[05_search_classification.md](05_search_classification.md)）。
- 絶対値はソース間で非可換なので、検知に使うのは**ソース内の変化率・傾き**のみ。

### `daily_term_stats` — 日次集計（スケジュールクエリで生成）

`occurrences` を集計して作る。F1 可視化・F2 検知・F5 JP/Global の読み元。

| 列 | 型 | 備考 |
|---|---|---|
| `day` | DATE | |
| `term_slug` | STRING | |
| `locale` | STRING | |
| `mentions` | INT64 | 当日の出現数 |
| `distinct_sources` | INT64 | クロスソース裏取り（新出検知の鍵） |
| `distinct_docs` | INT64 | |
| `share` | FLOAT64 | mentions ÷ 当日全用語 mentions（総量正規化） |

公開データセット（GitHub Archive 等）も同じ BigQuery 上にあり、必要に応じ結合できる。検知ロジックの式は [05_search_classification.md](05_search_classification.md)。

---

## RLS（テナント分離ポリシー）

Node のデータ層が Postgres に直接接続する。OIDC トークン → `user_tenants` 照合までアプリ層で済ませ、確定した `tenant_id` を `SET LOCAL app.tenant_id` で流す。RLS はその変数だけを参照する（根拠は [04_security_multitenant.md](04_security_multitenant.md)）。

**テナント単位テーブル**（`tenant_settings` / `watchlists` / `watchlist_items` / プライベート `sources`）に適用:

```sql
ALTER TABLE watchlists ENABLE ROW LEVEL SECURITY;
ALTER TABLE watchlists FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON watchlists
  USING       (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK  (tenant_id = current_setting('app.tenant_id', true)::uuid);
```

`current_setting('app.tenant_id', true)` の第二引数（missing_ok）で、未設定時は例外でなく NULL → 空集合（フェイルセーフ）。`tenant_settings` / `watchlist_items` も同パターン。

**`sources`** は混在（グローバル + テナント）。可視性と書込を別ポリシーに分け、**テナントは `tenant_id IS NULL`（グローバル公開ソース）を書けない**ようにする:

```sql
-- 可視性: グローバル（tenant_id IS NULL）+ 自テナント
CREATE POLICY sources_select ON sources FOR SELECT
  USING (tenant_id IS NULL OR tenant_id = current_setting('app.tenant_id', true)::uuid);

-- 書込: 自テナントのプライベートソースのみ（NULL = グローバルは書込不可）
CREATE POLICY sources_modify ON sources FOR ALL
  USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id IS NOT NULL
              AND tenant_id = current_setting('app.tenant_id', true)::uuid);
```

グローバルソースの作成・編集はマイグレーション / 収集パイプライン（`portfolio_owner`）に限定する。`WITH CHECK` に `tenant_id IS NOT NULL` を明示しないと、テナント admin が `tenant_id = NULL` で INSERT してグローバル公開ソースを生成でき、**全テナントの収集対象に任意 URL を注入**できる（SSRF・文書経由インジェクションの起点。[04_security_multitenant.md](04_security_multitenant.md) の「収集の信頼境界」）。

**グローバル共有テーブル**（`terms` / `term_aliases` / `detections` / `summaries`）は全認証ユーザーが読む共有データで、テナント列を持たない。RLS は有効化しない（テナント scope が無いため）。書込は限定する: 新規 term 作成・出現由来は収集パイプライン（`portfolio_owner`）、F9 辞書管理・検知レビューは admin 操作（`portfolio_app`。ただし **RLS はグローバルを scope できない**ので、アプリ層の **admin 認可ガード + 監査ログ**で保護する）。`summaries` は worker（system key）生成で app は読み取りのみ。GRANT の詳細は [04_security_multitenant.md](04_security_multitenant.md)。

`tenants` / `user_tenants` の自己可視ポリシー、`SET LOCAL app.user_id` の発行、`portfolio_owner`（スキーマ所有・マイグレーション）/ `portfolio_app`（アプリ接続・`NOBYPASSRLS`）の 2 ロール分離は [04_security_multitenant.md](04_security_multitenant.md) を参照。

---

## インデックス

```sql
CREATE INDEX ON sources (tenant_id, enabled);
CREATE INDEX ON sources (last_status) WHERE last_status <> 'ok';   -- F8 ヘルス
CREATE INDEX ON term_aliases (term_id);
CREATE INDEX ON term_identities (term_id);
CREATE INDEX ON detections (type, window_end DESC);
CREATE INDEX ON detections (term_id, detected_at DESC);
CREATE INDEX ON watchlist_items (tenant_id, term_id);
```

全文（BM25）・ベクトル（kNN）検索は Elasticsearch、時系列集計は BigQuery が担当するため、Postgres は構造化メタへの btree インデックスのみ。

---

## 同期と整合性

3 層の二重〜三重書き込みになるため整合性方針を決める:

- 収集ワーカーは 1 文書につき **(a) ES へ `doc_id` で冪等 upsert、(b) BigQuery `occurrences` へ追記（`doc_id`+`term_slug` で重複排除）**。Postgres の `terms` / `term_aliases` は抽出時に参照（必要なら新規 term を upsert）。
- metrics ワーカーは `term_identities` を巡回し、`term_metrics` へ `(metric_date, term_slug, source, metric)` で冪等 upsert（文書・ES は介在しない）。
- `daily_term_stats` は BigQuery のスケジュールクエリで `occurrences` から定期再構築（結果整合）。
- 失敗はリトライキューに積み、再インデックス / 再集計ジョブで突合・修復。
- 検索・関連トピックは ES 主、時系列・検知は BigQuery 主、エンティティ編集は Postgres 主、と読み分ける。

---

## 将来追加（Phase 2 以降）

| 対象 | 用途 | Phase |
|---|---|---|
| `categories` / 創発クラスタ | 「次の MCP」ムーブメント検知（急上昇クラスタのまとめ） | fast-follow |
| `alerts` / 配信設定 | F7 ダイジェスト・アラート（ウォッチリスト連動） | fast-follow |
| プライベートソース文書の ES テナント分離 | テナント自社ブログ等の取込 | Phase 2 |
| `tenant_public_keys` | 公開 API / 埋め込み用の rate-limited キー | Phase 2 |
