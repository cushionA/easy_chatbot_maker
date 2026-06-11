# 06. 収集ソース（Source Adapter）

## 設計思想

ソースごとに取得方法が違う（REST API / フィード / HTML クロール）。**Adapter パターン**で抽象化し、新ソースを追加できる設計にする。**API 主軸・クロール脇役**で、クロールは公式 API が無い対象だけに使う（[01_overview.md](01_overview.md)）。

## SourceAdapter インターフェース

```typescript
type SourceKind = "api" | "feed" | "crawl";

interface DiscoveredRef {
  externalId: string;   // ソース内一意 ID。dedup キーは source + externalId の複合
                        // （型はソースでバラバラ: HN objectID=str / SO question_id=int /
                        //   Qiita 20桁hex / crates name / Lobsters short_id → 文字列化して統一）
  url: string;          // 取得 URL（API なら詳細エンドポイント）
  hint?: unknown;       // 一覧由来の部分メタ（順位・初期タイトル等）
}

interface CollectedItem {
  externalId: string;
  url: string;
  title: string;
  body?: string;        // 用語抽出用。抽出後は破棄し保存しない（07 データ最小化）
  publishedAt?: string; // ★UTC 正規化済み ISO8601 を Adapter が保証する。
                        //   Unix秒(HN/SE)→変換、Qiita は +09:00 JST、Lobsters は -05:00 → UTC へ。
                        //   絶対日付が無いソース（GitHub Trending）は取得時刻を入れる特例
  popularity?: number;  // ソース相対の人気度（points/likes/score）。表示・ソース内ソート専用
  tags?: string[];      // 構造化タグ（高信頼の用語抽出元。05 の抽出(a)層）
  locale: "global" | "jp";
}

interface SourceAdapter {
  readonly kind: SourceKind;
  readonly name: string;

  // 収集対象を列挙（API ページング / フィード / リスト / Trending ページ）
  discover(config: SourceConfig, since: Date | null): AsyncIterable<DiscoveredRef>;

  // 1 参照を取得・解析し正規化アイテムへ（取得できない/対象外なら null）
  collect(ref: DiscoveredRef, config: SourceConfig, ctx: FetchContext): Promise<CollectedItem | null>;
}
```

`FetchContext` は**礼儀正しい取得**を担保する共通基盤（後述）。Adapter は HTTP の作法を自前で書かず、必ず `ctx` 経由で取得する。

```typescript
interface FetchContext {
  // 宛先URL検証(SSRF)・robots 確認・レート制御・条件付き GET・指数バックオフ・UA を内蔵
  get(url: string, opts?: { render?: boolean }): Promise<FetchResult>; // render=true で Playwright
}
```

## 礼儀正しいクローラ（FetchContext の責務）

クロールが脇役でも、ここは**実務スキルの本体**として手を抜かない。

- **宛先 URL の検証（SSRF 対策・最重要）**: scheme は http(s) のみ。DNS 解決後の IP がプライベート・ループバック・リンクローカル（`10/8`・`192.168/16`・`127/8`・`169.254.0.0/16`・`fc00::/7` 等）なら拒否。クラウドメタデータ（`169.254.169.254`）を明示ブロック。リダイレクト先も毎回再検証。テナントが `sources.config` に任意 URL を登録できる（プライベートソース）ため、これが無いと内部ネットワーク / クラウドの一時認証情報に到達する SSRF になる（[04_security_multitenant.md](04_security_multitenant.md) 収集の信頼境界）。
- **robots.txt の遵守**: ソースのホストごとに robots を取得・解析し、Disallow / Crawl-delay を尊重。`sources.robots_policy` に方針を保持。
- **レート制御 + 指数バックオフ**: `sources.rate_limit_rpm` でホスト別トークンバケット。429 / 5xx は指数バックオフ + ジッタ。
- **条件付き GET**: `ETag` / `If-Modified-Since` を保存し 304 を活用（無駄取得削減）。
- **連絡先入り User-Agent**: 誰がアクセスしているか明示。
- **JS レンダリング**: 静的は `undici`/`fetch`、必要時のみ `render:true` で Playwright（コスト高なので最小化）。
- **取得は HTML のみ**: 画像・大容量アセットは取らない。

## 収集ヘルス（F8）

収集ワーカーは Adapter 呼び出しを包み、`sources` の健全性を更新する。

| シグナル | 検知 | 反映 |
|---|---|---|
| 取得成功 | `collect` が有効アイテム | `last_ok_at` 更新、`consecutive_failures = 0` |
| 取得失敗 | 例外 / タイムアウト | `last_status='failed'`、`consecutive_failures++` |
| **パーサ破損** | `discover` が 0 件 / `collect` が必須フィールド欠落 | `last_status='parser_broken'`（即アラート対象） |

`parser_broken` は「サイト構造が変わってセレクタが死んだ」を捉える運用の肝。F8 ダッシュボードと `consecutive_failures` 閾値でアラートする。

## MVP の収集ソース

**言及系**（文書を生む → `documents` + `occurrences`）と**採用メトリクス系**（文書を持たない連続量 → `term_metrics`）で Adapter の形を分ける（[03_db_schema.md](03_db_schema.md) の mentions / metrics 分離）。

### 言及系（SourceAdapter: discover / collect）

| ソース | kind | locale | 取得物 | 備考 |
|---|---|---|---|---|
| Hacker News（Algolia） | api | global | story（履歴は時間窓スライド） | 話題シグナルの主力 |
| Qiita API v2 | api | jp | 記事 / タグ / いいね | JP 信号。`+09:00`→UTC |
| dev.to (Forem) API | api | global | 記事 / タグ | |
| Stack Exchange API | api | global | 質問 / タグ | `filter=total` で期間件数も |
| Lobsters (.json) | api | global | story / キュレート済タグ | 議論の独立裏取り |
| GitHub REST API | api | global | repo / release / topic | |
| **GitHub Trending** | **crawl** | global | 言語別トレンド | **公式 API 無し**。絶対日付なし → **取得時刻を occurrence 日付にする特例** |
| 記事本文 | **crawl** | both | トップ記事の本文 | MVP 後段。API はメタのみ → 本文抽出 |
| CHANGELOG / docs | **crawl** | global | リリース・破壊的変更 | fast-follow。ウォッチ対象を週次 |

### 採用メトリクス系（MetricsSourceAdapter: `term_identities` 巡回）

| ソース | metric | 備考 |
|---|---|---|
| npm downloads API | downloads | bulk は point のみ・128 件・scoped 不可 |
| PyPI（pypistats / BigQuery） | downloads | pypistats は直近 ~180 日。長期は BigQuery |
| crates.io | downloads | **連絡先 UA 必須・1 req/s**。長期は DB dump |
| GitHub Archive（BigQuery 公開 DS） | stars (WatchEvent) | DWH 内で集計 |

```typescript
interface MetricsSourceAdapter {
  readonly name: string;
  // term_identities の対応 ID ごとに、日次メトリクスの点列を返す
  collectMetrics(identity: { termSlug: string; externalId: string },
                 config: SourceConfig, ctx: FetchContext): Promise<MetricPoint[]>;
}

interface MetricPoint {
  date: string;                    // "YYYY-MM-DD"（UTC）
  metric: "downloads" | "stars";
  value: number;
}
```

`config`（jsonb）にエンドポイント / クエリ / セレクタ / 言語リスト等を持つ。新ソース追加は Adapter 実装 + `sources` 行追加。

API ソースは robots ではなく**各 API の利用規約（ToS）**に従う（再配布禁止・帰属表示・商用条件など robots では担保されない）。ToS の要点は `sources.robots_policy`（robots / ToS メモ兼用）に記録し、新ソース追加時のチェックリスト（[11_open_questions.md](11_open_questions.md) Q8）で確認する。

## ディスカバリと取得の分離

- **discover**: フィード / sitemap / API ページング / リストページ（Trending）から `DiscoveredRef` を列挙。**発見はフィードを使うのが実務的に正しい**（クロール総量を抑える）。
- **collect**: 1 参照を `ctx.get` で取得 → 解析 → `CollectedItem`。**クロールの主戦場は本文取得 + 抽出**で、ここに per-site 差異が集中する。

### discover の取得上限ハンドリング（実測済みの制約）

一覧 API には取得上限があり、`discover` は**上限を越えて期間を網羅する戦略**を持つ（[14_data_sources.md](14_data_sources.md)）:

| ソース | 上限 | 戦略 |
|---|---|---|
| HN Algolia | **1 クエリ 1000 件天井**（実測） | `numericFilters=created_at_i<最古値` で**時間窓を後ろにスライド** |
| GitHub Search | 合計 1000 件 | `created:YYYY-MM-DD..` で**期間スライス** |
| Qiita | `page` ≤ 100 × `per_page` ≤ 100 = 1 万件 | `query` で期間 / タグを絞って分割 |
| dev.to / Lobsters | ページング自体に上限なし | `published_at` / `created_at` で**期間打ち切り**（前回取得時刻まで遡ったら停止） |

両者を分けることで、ワーカーは discover をキューに積み、collect を並列ワーカーでレート制御しつつ捌ける（[02_architecture.md](02_architecture.md) のキュー構成）。

## dedup（近重複除去）

`CollectedItem` から `content_hash`（タイトル + 正規化本文のハッシュ）を計算し ES に保持、完全重複を弾く。クロスポスト等の近重複は抽出後の embedding kNN（ES）で検出して 1 件に寄せる。

## Adapter 実装ファイル構成

```
src/sources/
├── source-adapter.ts          // 言及系 interface（discover / collect）
├── metrics-source-adapter.ts  // 採用メトリクス系 interface（collectMetrics）
├── fetch-context.ts           // SSRF検証/robots/レート/条件付きGET/Playwright を内蔵
├── models/
│   ├── source-config.ts
│   ├── discovered-ref.ts
│   ├── collected-item.ts
│   └── metric-point.ts
├── adapters/
│   ├── hackernews-algolia-source.ts
│   ├── qiita-api-source.ts
│   ├── devto-api-source.ts
│   ├── stackexchange-api-source.ts
│   ├── lobsters-api-source.ts
│   ├── github-api-source.ts
│   ├── github-trending-crawl-source.ts
│   ├── article-body-crawl-source.ts
│   └── changelog-crawl-source.ts
├── metrics/
│   ├── npm-downloads-source.ts
│   ├── pypistats-source.ts
│   ├── crates-io-source.ts
│   └── github-archive-source.ts
└── source-registry.ts         // kind/name → 実装の解決
```

`source-registry` の DI / ファクトリ（NestJS / Express）で `sources.kind` / 設定から実装を解決する。

## 面接で語る点

> 「ソースごとに取得方法（REST API / フィード / HTML クロール）が異なるため、`SourceAdapter` インターフェースで抽象化し、HTTP の作法（robots 遵守・レート制御・条件付き GET・指数バックオフ・必要時のみ Playwright）は `FetchContext` という共通チョークポイントに集約した。新ソースは Adapter 実装 + 設定行の追加だけで増やせる」

> 「収集は黙って腐るのが最悪なので、`parser_broken`（取得件数 0 / 必須フィールド欠落）を検知して `sources.last_status` と連続失敗回数でアラートする収集ヘルスを設計の一部にした。API 主軸・クロール脇役で、公式アクセスがある所は API を使い、クロールは公式 API が無い隙間（GitHub Trending・記事本文・CHANGELOG）だけに限定した」
