# 14. データソース取得仕様書（実地調査版）

実装時に調べ物で中断しないための**取得リファレンス**。各ソースは **2026-06-10〜11 に実エンドポイントを叩いてフィールド名・型・認証・レート・セレクタを確認**した。凡例: ✅確認済（ライブ取得で実見） / 📄ドキュメント確認 / ⚠️要再確認（実装時にライブで裏取り）。

設計本体は [03_db_schema.md](03_db_schema.md)（モデル）・[05_search_classification.md](05_search_classification.md)（抽出・検知）・[06_destinations.md](06_destinations.md)（Source Adapter）。本書はそれらに流す**実データの形**を固める。

---

## API キー早見表（「何にキーが要るか」）

| ソース | 種別 | キー要否 | 取得先 / 無料 | 無認証レート | 認証レート |
|---|---|---|---|---|---|
| **HN Algolia** | api | **不要** | — | 10,000/hr/IP 📄 | — |
| HN Firebase | api | **不要** | — | 明記なし | — |
| **Qiita** | api | 任意（本番は推奨） | `qiita.com/settings/applications`・無料 | **60/hr/IP** ✅ | **1,000/hr** ✅ |
| **GitHub REST** | api | 任意（本番は推奨） | Settings→Developer settings→PAT・無料 | core 60/hr・search 10/min ✅ | core 5,000/hr・search 30/min 📄 |
| GitHub Archive | api(DWH) | GCP 必要 | GCP プロジェクト | — | スキャン課金（1TB/月無料枠） |
| **GitHub Trending** | crawl | 不要 | — | robots 許容・低頻度 | — |
| **dev.to** | api | **不要**（読取） | 書込のみ `api-key` | ~3 req/s 📄 | — |
| **Stack Exchange** | api | 任意（推奨） | `stackapps.com/apps/oauth/register`・無料 | **300/day/IP** ✅ | **10,000/day** 📄 |
| npm downloads | api | **不要** | — | 明記なし（緩い） | — |
| PyPI (pypistats) | api | **不要** | — | 良識的ポーリング | — |
| PyPI (BigQuery) | api(DWH) | GCP 必要 | GCP プロジェクト | — | スキャン課金 |
| **crates.io** | api | 不要（読取） | **連絡先入り UA 必須・1 req/s** | — | — |
| **Lobsters** | api(.json) | 不要 | `.json` を連絡先 UA・低頻度（robots Crawl-delay 1） | — | — |

**結論**: MVP の主要源泉は**ほぼ無認証で着手可能**。本番のレート緩和のため Qiita / GitHub / Stack Exchange は**無料キーを取る**（コードはキー有無の両対応にしておく）。BigQuery 系（GitHub Archive / PyPI DL）だけ GCP プロジェクトが要る。

---

## 1. Hacker News Algolia API（履歴取得の主力・global）

- **用途**: 過去の story を**日付窓 + ポイント閾値**で一括取得。時系列の素。
- **ベース URL**: `https://hn.algolia.com/api/v1/`・認証不要 ✅
- **エンドポイント**: `search_by_date`（作成日降順＝履歴向き）/ `search`（関連度順）。**両者レスポンス構造は同一**、並び順のみ違う ✅
  - 例: `https://hn.algolia.com/api/v1/search_by_date?tags=story&hitsPerPage=100&numericFilters=created_at_i>1748000000,points>5`
- **1 hit の実フィールド** ✅:

| フィールド | 型 | 備考 |
|---|---|---|
| `objectID` | string | story id（**文字列**。Firebase は int → 型差に注意） |
| `title` | string | 用語抽出の主対象 |
| `url` | string \| null | self-post（Ask HN 等）は `null` |
| `author` | string | |
| `points` | int | 人気度 |
| `num_comments` | int | |
| `created_at` | string(ISO8601 UTC) | |
| `created_at_i` | **int(Unix秒)** | **フィルタの主役** |
| `_tags` | string[] | `["story","author_x","story_id"]` |

- **ページング・履歴の鍵** ✅: `nbPages` は**最大 1000**、`hitsPerPage` 最大 1000。**1 クエリで取れるのは実質 ≤1000 件**（4000 件目で空配列を実測）。**30 日を一括するには時間窓スライド**: 古い順に取り、各バッチの最古 `created_at_i` を次クエリの `numericFilters=created_at_i<その値` に入れて遡る。`points>N` で 1 窓 1000 件以内に収める。
- **URL エンコード**: `<`=`%3C`, `>`=`%3E`, 複数条件は `,` 区切り。
- **我々の利用**: text=`title`（+URLドメイン、本文なし）/ 日付=`created_at_i` / source=`hackernews`・locale=`global` / 人気度=`points`,`num_comments` / dedup id=`objectID`。

## 2. Hacker News 公式 API（Firebase・現在値のみ）

- **用途**: 「今の」top/new。履歴は取れない（**過去日次は Algolia を使う**）。
- **ベース URL**: `https://hacker-news.firebaseio.com/v0/`・認証不要 ✅
- **エンドポイント**: `topstories.json` / `newstories.json`（id 配列）/ `item/{id}.json` / `maxitem.json`。
- **story アイテム実フィールド** ✅: `id`(int), `type`("story"等), `by`(string), `time`(**Unix秒**), `title`, `url`(self-post で欠落), `score`(int), `descendants`(int), `kids`(int[])。**`type=="story"` でフィルタ必須**（comment は `title`/`url`/`score` なし、`parent`/`text` を持つ）✅。

## 3. Qiita API v2（日本語・locale jp）

- **用途**: 日本語圏の記事。タグが綺麗で用語抽出に強い。
- **ベース URL**: `https://qiita.com/api/v2/`・`GET /items` は無認証可 ✅。トークンは `qiita.com/settings/applications` で無料発行 → `Authorization: Bearer <token>`。
- **レート** ✅: 無認証 **60/hr/IP**、認証 **1,000/hr**。全応答に `Rate-Limit`/`Rate-Remaining`/`Rate-Reset` ヘッダ。
- **エンドポイント**: `GET /items?per_page=100&page=1` / `GET /items?query=tag:Python` / `GET /tags?sort=count` / `GET /tags/{tag}/items`（⚠️未実行）。
- **`/items` 1記事の実フィールド** ✅:

| フィールド | 型 | 備考 |
|---|---|---|
| `id` | string | 20桁 hex |
| `title` | string | 用語抽出の主対象 |
| `body` / `rendered_body` | string | Markdown / HTML。**untrusted（後述）** |
| `tags` | object[] | `[{name, versions}]` ← **タグ名は `tags[].name`** |
| `likes_count` / `stocks_count` | int | 人気度 |
| `created_at` | string | **ISO8601 `+09:00`（JST）→ UTC 正規化必須** |
| `url` | string | |
| `user` | object | `id`, `followers_count` 等 |

- **ページング** ✅: `per_page` 1–100、`page` 1–100（超過は **HTTP 400**）。**最大 10,000 件/クエリ**。`Total-Count` ヘッダと `Link` ヘッダ。`page=100` 付近で 502 観測（負荷）。
- **`/tags`**: `id`（=タグ名そのもの）, `items_count`, `followers_count`（**`/items` 側の `tags[].name` と非対称**）。
- **我々の利用**: text=`title`+`tags[].name`+`body` / 日付=`created_at`(JST→UTC) / source=`qiita`・locale=`jp` / 人気度=`likes_count`,`stocks_count`。`page_views_count` は一覧で常に `null`。

## 4. GitHub REST API（トレンド信号・global）

- **用途**: スター/言語/トピック/作成日でリポジトリ、リリースで新版検知。
- **ベース URL**: `https://api.github.com`・ヘッダ `Accept: application/vnd.github+json` / `X-GitHub-Api-Version: 2022-11-28` ✅。
- **認証** ✅: 公開データ読取は**無認証可**。本番は PAT 推奨（無料発行、公開読取は**スコープ無しトークンで可**。⚠️発行後 `/rate_limit` で `core.limit=5000` を実測裏取り）。
- **レート** ✅: 無認証 core **60/hr**・search **10/min**、認証 core **5,000/hr**・search **30/min**📄。Search は core と別枠。ヘッダ `X-RateLimit-*`（`Reset` は UTC epoch 秒）。
- **エンドポイント例**:
  - `GET /search/repositories?q=stars:>10000+language:typescript&sort=stars&order=desc&per_page=100`
  - 新出: `GET /search/repositories?q=language:rust+created:>2026-05-01&sort=stars`
  - `GET /repos/{owner}/{repo}/releases?per_page=10`
- **search/repositories の items[] 実フィールド** ✅: `full_name`, `name`, `description`(null可), `language`(null可), `topics`(string[]), `stargazers_count`, `forks_count`, `created_at`, `pushed_at`, `updated_at`, `license`(obj/null), `owner`(obj)。
- **releases 実フィールド** ✅: `tag_name`, `name`, `published_at`, `body`(リリースノート＝用語抽出に有用), `prerelease`(bool), `html_url`。
- **ページング・履歴**: `per_page` 最大 100 + `page` + `Link` ヘッダ。**Search は合計 1,000 件上限**（超は `created:` で期間スライス）。**スター履歴は REST 不可** → GraphQL（認証必須）か GitHub Archive（次項）。
- **ToS**: API はスクレイピング条項の対象外（正規ルート）✅。
- **我々の利用**: text=`description`+`topics`+`full_name`、リリースは `name`+`body` / 日付=新出 `created_at`・活発度 `pushed_at`・リリース `published_at` / source=`github_rest`・locale=global。

## 5. GitHub Archive（BigQuery・スター時系列）

- **用途**: `WatchEvent`（=スター付与）の**時系列**集計。REST で取れない履歴の主力。
- **データセット** 📄: **`githubarchive`**（`bigquery-public-data` ではない）。`githubarchive.day.YYYYMMDD`（ワイルドカード `day.20*`）/ `month.YYYYMM` / `year.YYYY`。生 JSON は `https://data.gharchive.org/2015-01-01-15.json.gz`。
- **イベント型**: `WatchEvent`(star), `PushEvent`, `ForkEvent`, `ReleaseEvent` 等。共通カラム `type`,`created_at`,`repo`,`actor`,`payload`。`payload` は型ごとにスキーマが変わる（⚠️ `INFORMATION_SCHEMA`/試走で確認）。
- **課金**: ストレージ無料・**スキャンは自分のプロジェクトに課金**。`_TABLE_SUFFIX BETWEEN '20260601' AND '20260610'` で日付を必ず絞る。
- **クエリの考え方**: `WHERE type='WatchEvent'` → `repo.name` で GROUP BY → 日付バケット → COUNT。急上昇=直近 N 日の増分。
- **我々の利用**: 用語抽出元というより**時系列の重み付けシグナル**（説明文なし、`repo.name` のみ）。日付=`created_at`/`_TABLE_SUFFIX`、source=`github_archive`。

## 6. GitHub Trending（クロール・公式 API なし）

- **用途**: 「本日/今週の急上昇」ランキング。API で取れない部分をクロールで補完。
- **URL** ✅: `https://github.com/trending`、`?since=daily|weekly|monthly`、`/trending/{language}`、`?spoken_language_code=ja`。
- **robots** ✅: `https://github.com/robots.txt` に **`/trending` の Disallow なし**（検索系のみ禁止）。Acceptable Use のスクレイピング条項は研究/アーカイブ目的・派生データのみ保存・非個人情報なら整合。
- **現行セレクタ**（2026-06-10 のライブ HTML を実パース ✅。⚠️ **GitHub は HTML を予告なく変えるため実装時に生 HTML で再検証**）:

| 要素 | セレクタ |
|---|---|
| リポジトリ行 | `article.Box-row`（1ページ 約17件） |
| リポジトリ名＋リンク | `h2.h3.lh-condensed > a` の `href`（`/owner/repo` を分解） |
| 説明 | `p.col-9.color-fg-muted` |
| 言語 | `span[itemprop="programmingLanguage"]` |
| 合計スター | `a[href$="/stargazers"]` のテキスト |
| 期間スター | 行末テキスト `"NNN stars today"`（クラス名は⚠️要再確認） |

- **我々の利用**: text=リポジトリ名+説明 / 日付=**HTML に絶対日付なし → 取得時刻を付与**、`since` を期間メタに / source=`github_trending`・locale=`spoken_language_code` 指定時のみ。

## 7. dev.to（Forem API・global）

- **ベース URL**: `https://dev.to/api/`・**読取は完全公開**（`api-key` は書込専用）✅。`Accept: application/vnd.forem.api-v1+json` 推奨。
- **レート**: ヘッダに `RateLimit-*` は出ず（~3 req/s 📄）。429 時 `Retry-After` 前提。
- **エンドポイント**: `GET /articles?per_page=N`、`GET /articles?tag=react&top=7`（直近 N 日人気順）、`GET /tags`。
- **`/articles` 実フィールド** ✅: `title`, `description`, `tag_list`(**string[]** ← 用語抽出)、`tags`(カンマ区切り string), `published_at`(ISO8601), `positive_reactions_count`(人気度), `comments_count`, `language`("en" 等), `url`, `user`(obj)。
- **`/tags`**: `name`, 色のみ（**記事数 count は返らない** → タグ人気は記事を辿って集計）。
- **ページング**: `page`(1始まり)+`per_page`。履歴は `published_at` で期間打ち切り。
- **我々の利用**: text=`tag_list`+`title`+`description` / 日付=`published_at` / source=`devto`・locale=`language` / 人気度=`positive_reactions_count`。

## 8. Stack Exchange API（Stack Overflow・global）

- **用途**: タグ別の累計質問数（人気度の絶対値）＋期間別新規質問数（傾き）。「困りごと」シグナル。
- **ベース URL**: `https://api.stackexchange.com/2.3/`・**必須 `site=stackoverflow`**。
- **キー/quota** ✅: キー無しでも可（**300/day/IP**、`quota_remaining` が減るのを実測）。`stackapps.com/apps/oauth/register` で無料 key → **10,000/day**📄、`key=<APP_KEY>` 付与。OAuth は書込のみ。
- **エンドポイント**:
  - `GET /questions?site=stackoverflow&order=desc&sort=creation&pagesize=100`
  - `GET /tags?site=stackoverflow&order=desc&sort=popular`
  - 期間別件数: `GET /questions?site=stackoverflow&tagged=react&fromdate=<unix>&todate=<unix>&filter=total` → `{"total":N}` のみ ✅
- **`/questions` 実フィールド** ✅: `question_id`, `title`, `tags`(string[]), `creation_date`(**Unix秒**), `score`, `view_count`, `answer_count`, `link`。**`/tags`**: `name`, `count`(累計質問数)。
- **注意** ✅: `quota_remaining`/`quota_max` は全応答 top-level。過負荷時のみ `backoff`(秒) → 従う。`filter=total` で件数だけ取り quota 節約。多くのクライアントは gzip 前提（requests/axios は自動）。
- **時系列の取り方**: `tagged=<tag>&fromdate&todate&filter=total` を**月次で繰り返す**（1 期間=1 リクエスト）。
- **我々の利用**: text=`tags`+`title` / 日付=`creation_date` / source=`stackoverflow`・locale=global / 人気度=`score`,`view_count`,タグ `count`。

## 9. npm ダウンロード数（採用シグナル・global）

- **ベース URL**: DL=`https://api.npmjs.org/`、メタ=`https://registry.npmjs.org/`・**認証不要** ✅。
- **エンドポイント** ✅:
  - point: `GET /downloads/point/{period}/{package}` → `{downloads, start, end, package}`。`{period}`=`last-day|last-week|last-month|last-year|YYYY-MM-DD:YYYY-MM-DD`
  - range（日次）: `GET /downloads/range/last-month/react` → `downloads[]` = `{downloads:int, day:"YYYY-MM-DD"}`
  - bulk: `point/last-week/react,vue` → **パッケージ名キーの map**。**128 件まで・scoped 不可・range は bulk 不可** ✅。
  - メタ: `GET https://registry.npmjs.org/react` → `description`, `keywords`(string[]), `dist-tags.latest`, `time`(各版公開日)。**ETag/`max-age=300`** で条件付き GET 可 ✅。
- **最古データ 2015-01-10**📄。**我々の利用**: text=`keywords`+`description`+パッケージ名 / 日付=range の `day` / source=`npm`・locale=非依存 / 人気度=`downloads`。

## 10. PyPI ダウンロード数（global）

- **pypistats** ✅（認証不要・**直近 ~180 日**）: `GET https://pypistats.org/api/packages/{pkg}/recent` → `{data:{last_day,last_week,last_month}}`。`/{pkg}/overall` → 日次時系列 `[{category,date,downloads}]`。
- **BigQuery**（長期・正確）📄: `bigquery-public-data.pypi.file_downloads`。カラム `timestamp`, `file.project`, `file.version`, `details.installer.name`（**`='pip'` でボット/mirror 除外必須**）, `details.python`, `country_code`。`WHERE timestamp >= ...` でパーティション制限必須。⚠️実クエリ未検証。
- **メタ** ✅: `GET https://pypi.org/pypi/{pkg}/json` → `info.summary`, `info.version`, `info.classifiers`(string[])。**`info.keywords` は `null` 頻発（PEP 621）→ 用語抽出は `summary`+`classifiers`+パッケージ名を使う**。
- **我々の利用**: 日付=overall の `date` / source=`pypi`・locale=非依存 / 人気度=DL 数。

---

## 11. crates.io（Rust パッケージレジストリ・採用シグナル・global）

- **用途**: Rust の**採用（ダウンロード）シグナル**で global の穴（DL が JS/Python 偏重）を埋める。crate 名・説明・keywords・categories は用語抽出元、`created_at` は新出、`downloads`/`recent_downloads` は人気度。
- **ベース URL**: `https://crates.io/api/v1/`・**API キー不要**（読取・公開データ）✅。書込（publish）のみトークン。
- **認証/作法（重要）** ✅: 公式 data-access ポリシー（`https://crates.io/data-access`）が **「1 req/sec まで・アプリを識別する User-Agent（連絡先入り推奨）」**を要求。**UA 無しは実測でブロック**（`violation of our API data access policy` を返す）。`User-Agent: trendscope (連絡先メール/URL)` を付けると 200。robots.txt は全許可だが**この API ポリシーが優先**。
- **公式の推奨取得順** 📄: ① sparse index `https://index.crates.io/{a}/{b}/{name}`（メタのみ・レート制限なし）② git index ③ RSS（`https://static.crates.io/rss/crates.xml` 等）④ **DB dump**（後述）⑤ 最後の手段が REST API。→ **時系列 DL・ランキングが要るので API/DB dump を使うが、UA とレートは厳守**。
- **エンドポイント（実取得確認）** ✅:
  - `GET /summary` — `new_crates`/`most_downloaded`/`most_recently_downloaded`/`just_updated`（各 crate 10 件）+ `popular_keywords`/`popular_categories`。**新出/急上昇ダッシュボードの素**。
  - `GET /crates?sort=recent-downloads&per_page=3` — `sort` は `downloads`（累計）/`recent-downloads`（直近90日）/`new`（新着＝新出検知）/`recent-updates` すべて動作。
  - `GET /crates/{name}`（例 `/crates/serde`）。
  - `GET /crates/{name}/downloads` — **DL 時系列**（後述）。
- **crate オブジェクトの実フィールド** ✅:

| フィールド | 型 | 備考 |
|---|---|---|
| `id` / `name` | string | crate 名（dedup id） |
| `description` | string \| null | 用語抽出 |
| `keywords` | string[] | `["no_std","serialization"]` 等・用語抽出 |
| `categories` | string[] | `["encoding"]` 等・用語抽出 |
| `downloads` | int | 累計 DL |
| `recent_downloads` | int | 直近90日 DL |
| `created_at` | string(ISO8601 UTC) | **新出判定** |
| `updated_at` | string(ISO8601 UTC) | |
| `newest_version` / `max_stable_version` / `max_version` / `default_version` | string | 版（安定版検知は `max_stable_version`、最新は `newest_version`） |
| `repository` / `homepage` / `documentation` | string \| null | |

- **DL 時系列**（`GET /crates/{name}/downloads`）✅: `version_downloads`=`{version:int(版ID), downloads:int, date:"YYYY-MM-DD"}` 配列 + `meta.extra_downloads`=`{date, downloads}`（古い版を畳んだ分）。**日次合計 = version_downloads 合計 + extra_downloads**。窓は**直近90日**（長期は DB dump）。
- **DB dump（bulk）** ✅: `https://static.crates.io/db-dump.tar.gz`（全 crate・長期履歴を一括）。**棚卸し・長期 DL は dump、差分は API ポーリング**が王道。
- **ページング** ✅: `per_page` 最大 100、**seek カーソル**（`meta.next_page` の `?seek=` を辿る）。
- **我々の利用**: text=`name`+`description`+`keywords`+`categories` / 日付=`created_at`（新出）/ source=`crates_io`・locale=`global` / 人気度=`downloads`・`recent_downloads`・時系列の傾き / dedup=`name`。**UA 連絡先 + 1 req/s スロットルを Adapter に明記**。

## 12. Lobsters（lobste.rs・技術リンク共有・議論の独立裏取り・global）

- **用途**: HN/dev.to から**独立した高 S/N の議論シグナル**。**タグが運用キュレート**（`rust`/`go`/`web` 等）で技術フィルタに有用。
- **ベース URL**: `https://lobste.rs/`・**認証不要** ✅。各ページに `.json` を付けるだけで JSON。
- **エンドポイント（実取得確認）** ✅: `GET /hottest.json`（人気順25件）/ `GET /newest.json`（新着25件）/ `GET /t/{tag}.json`（タグ別。`/t/rust,go.json` で複数 AND）/ `GET /s/{short_id}.json`（単記事＝`comments` 付き）。
- **クロール作法（robots 要注意）** ✅: `https://lobste.rs/robots.txt` は **`User-agent: * → Crawl-delay: 1 / Disallow: /`**、加えて `Content-Signal: ai-input=no, ai-train=no, search=yes`。→ **無差別 HTML クロールは禁止**。`.json` はサイトが公開配信する正規取得口なので、**連絡先入り UA・低頻度（≥1 req/s 間隔）で `.json` を取得、HTML スクレイプはしない**。RSS（`/rss`・`/t/{tag}.rss`）も配信同意ルート。ToS/robots 整合は実装時に最終確認（⚠️）。
- **1 story の実フィールド** ✅:

| フィールド | 型 | 備考 |
|---|---|---|
| `short_id` | string | dedup id（例 `esvncd`） |
| `created_at` | string | **ISO8601 オフセット付き `-05:00`（US Central）→ UTC 正規化必須** |
| `title` | string | 用語抽出の主対象 |
| `url` | string | 外部リンク先 |
| `score` | int | 人気度（upvote−downvote） |
| `comment_count` | int | |
| `tags` | string[] | **運用キュレート済タグ**・技術フィルタ＆用語抽出 |
| `description` / `description_plain` | string | 本文（**untrusted**・多くは空） |
| `submitter_user` | string | **文字列**（HN/Qiita の user オブジェクトと型が違う） |
| `comments_url` | string | |

- **ページング** ✅: `?page=N`（1始まり・25件/ページ）。履歴は `created_at` で期間打ち切り（newest を遡る）。
- **我々の利用**: text=`title`+`tags`（任意で `description_plain`）/ 日付=`created_at`（オフセット→UTC）/ source=`lobsters`・locale=`global` / 人気度=`score`,`comment_count` / dedup=`short_id`。`description` は untrusted（[04](04_security_multitenant.md)）。**議論層が HN・dev.to・Lobsters の 3 系統**になり F2 の独立裏取りが強化される。

---

## クロール対象まとめ

| 対象 | 状態 | セレクタ |
|---|---|---|
| **GitHub Trending** | ✅ 確認済（要実装時再検証） | 上記 §6 の表 |
| 記事本文（HN/Qiita/Zenn のトップ記事） | ⏳ MVP 後段 | per-site 差大。本文抽出は readability 系 + ボイラープレート除去。**SSRF/injection 対策必須**（[04](04_security_multitenant.md)） |
| CHANGELOG / docs | ⏳ fast-follow | per-site。ウォッチ対象を限定し週次 |

MVP の縦串は **API 主軸（HN Algolia + Qiita + GitHub REST/Trending）** で十分立つ。本文クロールは信号が API で足りない所だけ後段で足す。

---

## 正規化スキーマへのマッピング（横断）

各 Adapter は `CollectedItem`（[06](06_destinations.md)）へ正規化する。ソース差の吸収ポイント:

| 観点 | 揃え方 |
|---|---|
| **日付** | すべて **UTC の `occurred_date`** に正規化。Unix 秒（HN/SE）はそのまま、ISO8601（dev.to/GitHub）はパース、**Qiita は `+09:00` を UTC 変換** |
| **id（dedup）** | `source` + ソース内 id を複合キーに（HN は `objectID` str / Firebase `id` int の型差を吸収） |
| **text（用語抽出元）** | タイトル + タグ/トピック（+ 任意で本文/リリースノート） |
| **locale** | `qiita=jp`、それ以外（HN/dev.to/SO/npm/PyPI/GitHub）=`global`（dev.to は `language` 優先） |
| **人気度 weight** | points/score/likes/reactions/downloads をソース内で正規化（絶対値は比較不可） |
| **distinct_sources** | 新出のクロスソース裏取りは **HN・Qiita・dev.to・SO・GitHub の 5 系統**で担保（locale 跨ぎも可） |

---

## ロケール網羅性（JP / Global バランス）

現状の MVP ソースは **Global に偏っている**。F5（JP vs Global）と JP 側のクロスソース裏取りを成立させるには JP を増やす必要がある。

| locale | ソース | 数 |
|---|---|---|
| **global（英語圏）** | HN・GitHub(REST/Trending/Archive)・dev.to・Stack Overflow・npm・PyPI・**crates.io**・**Lobsters** | 8 系統 |
| **jp** | Qiita | **1 系統のみ** |

- 「Global」は実質**英語圏 global**。中国語圏（掘金 / SegmentFault 等）は規約・anti-bot で困難なため**意図的にスコープ外**。
- JP 増強候補（ToS / robots は個別確認）:

| 候補 | 取得 | 価値 | 備考 |
|---|---|---|---|
| **ja.stackoverflow** | Stack Exchange API `site=ja.stackoverflow` | 高・ほぼ無料 | §8 の SE アダプタを site 差し替えで流用 |
| **Zenn** | RSS（`zenn.dev/feed`・トピック別フィード） | 高 | モダンな JP 開発者プラットフォーム。公式 API は非公開 → RSS = 配信同意ルート |
| **はてブ テクノロジー** | hotentry RSS | 中〜高 | 「JP 開発者が今ブクマしてる」トレンド信号 |
| **connpass** | 公式 API（近年アクセス制限の変更あり → 要確認） | 中 | JP 技術イベント名から用語 |

最小で **ja.stackoverflow（SE 流用）+ Zenn（RSS）** を足せば JP が 1→3 系統になり、JP 側でも裏取り・F5 が成立する。**JP は後追い前提**（トレンドは global 先行 → JP に波及）なので、JP 拡充は後回しでよい。

## シグナル種別カバレッジ（global の厚み）

global は「議論・コード・Q&A」は厚い。唯一の実質的な穴は **採用（ダウンロード）シグナルが JS+Python に偏る**こと。

| シグナル種別 | カバー | 状態 |
|---|---|---|
| 議論 / buzz | HN・dev.to・**Lobsters** | ◯（独立裏取り 3 系統） |
| コード / repo・star | GitHub(REST/Trending/Archive) | ◎ |
| Q&A / 痛み | Stack Overflow | ◯ |
| リリース / 新版 | GitHub Releases | ◯ |
| **採用 / ダウンロード** | npm(JS)・PyPI(Python)・**crates.io(Rust)** | ◯（主要 3 エコシステム） |

- **重要**: 議論層（HN/GitHub/SO/Lobsters）は言語横断なので、Go 等の新ツールも**発見はできる**（HN で話題になる）。偏っているのは**採用の裏取り**（DL 数）で、現状 JS / Python / Rust の 3 エコシステム。
- crates.io（Rust 採用）と Lobsters（議論の独立裏取り）は **§11 / §12 で追加済み**。残る候補（必要になったら）:

| 候補 | 取得 | 埋める穴 |
|---|---|---|
| Go（deps.dev / pkg.go.dev） | deps.dev API | Go の採用シグナル |
| NuGet / Maven / RubyGems / Docker Hub | 各公式 API | .NET / Java / Ruby / コンテナの採用 |

Reddit（r/programming 等）は議論シグナルとして強いが **API が有料 / 制限**のため見送り。

## 設計への反映(03 / 05 / 06) — 反映済み（2026-06-11）

調査で**設計の仮定が概ね妥当**と確認できた。下記はすべて 03 / 05 / 06 に反映済み（加えて **mentions / metrics 分離**（`term_metrics`）と **`term_identities`** を 03 に追加、抽出の 2 層化を 05 に、`MetricsSourceAdapter` と discover 上限ハンドリングを 06 に追加した）:

1. **occurrence の日付ソースはソースごとに違う**（Unix秒 / ISO8601 / JST）。[03](03_db_schema.md) の `occurrences.occurred_date` は「各 Adapter が UTC 正規化して投入」と明記する（§マッピング）。
2. **HN は型が二重**（Algolia/Firebase）。[06](06_destinations.md) の `CollectedItem` 正規化で吸収する旨を Adapter 設計に残す。
3. **Search/Algolia/Qiita に 1,000〜10,000 件の取得上限**。[06](06_destinations.md) の `discover` は「期間スライス / 時間窓スライド」で上限を越える設計が要る（HN Algolia の `created_at_i<` スライドが代表）。
4. **GitHub Trending は絶対日付を持たない** → 取得時刻を occurrence 日付にする特例を [06](06_destinations.md) に明記。
5. **untrusted input は机上論でなく実在** ✅: 調査中、Qiita 記事本文に**エージェントへシェルコマンド実行を促す injection 文面**が実在した。[04](04_security_multitenant.md) の「収集物=信頼できない入力」（prompt injection / 本文をデータとして隔離）は**必須**であることが裏付けられた。
6. **PyPI `keywords` は使えない**（null 頻発）。[05](05_search_classification.md) の用語抽出で PyPI は `summary`+`classifiers`+パッケージ名を使う。

---

## 実装時の要再確認リスト（⚠️）

1. GitHub PAT スコープ無し = 5,000/hr を、発行後 `/rate_limit` で実測裏取り。
2. GitHub Trending のセレクタ（特に "stars today" の囲み span クラス）を生 HTML で再検証。HTML 変更前提で定期確認。
3. GitHub Archive の `payload` ネストスキーマを BigQuery `INFORMATION_SCHEMA` / 小レンジ試走で確認・スキャン量実測。
4. Stack Exchange アプリ key 取得 → 10,000/day を実測。
5. dev.to の正確なレート（ヘッダ非出力 → 429/`Retry-After` 前提で実装）。
6. PyPI BigQuery の実クエリ・課金（`details.installer.name='pip'` 絞り込み）。
7. Qiita `/tags/{tag}/items` の実レスポンス。
