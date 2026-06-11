# 13. テスト戦略・テスト仕様

## 方針

- **テストは設計の一部**。機能を作ってから足すのではなく、各機能の「完了の定義」にテストを含める（求人の必須要件「Web アプリ開発のコーディングから**テスト**まで」、担当工程の「テスト」、歓迎要件の上流＝**テスト設計**に対応）。
- **漏洩・不変条件は必ず自動テスト化**。特に RLS のテナント越境がないことは、書き間違えると即漏洩なので E2E で恒久ガードする。
- **検知ロジック（F2）は回帰テストで固定する**。新出/急上昇/廃れは閾値・統計式に依存し、しきい値をいじると静かに壊れる。固定データセットで期待結果を assert し、パラメータ較正の土台にする。
- **収集の作法は契約・フィクスチャで守る**。robots 遵守・レート制御・条件付き GET・`parser_broken` 検知は外部サイトに依存させず、フィクスチャ/モックサーバで決定的に検証する。
- **非決定的な出力は内容を assert しない**。LLM 要約や Embedding の数値そのものは検証対象にせず、**構造化出力のスキーマ妥当性・分岐の正しさ・スコア順序**を検証する（不安定なテストを作らない）。
- スタックは [02_architecture.md](02_architecture.md) に合わせ TypeScript / Node 一式（Playwright / Vitest / supertest / Testcontainers）。ML 推論サービスのみ Python のため**契約テスト**で境界を守る。

## テストピラミッド

| 層 | 比率目安 | 道具 | 対象 |
|---|---|---|---|
| 単体（Unit） | 多 | Vitest | 純ロジック：用語正規化（別名→正規・曖昧性解消・除外）、F2 判定式（emerging/rising/declining）、`share` 正規化・EWMA・z-score、`content_hash` 計算、robots パース、レートトークンバケット、スニペット切り出し |
| 結合（Integration） | 中 | Vitest + supertest + Testcontainers | API 層：Postgres（RLS）・Elasticsearch を本物コンテナで、BigQuery / Embedding / LLM はモック or エミュレータ |
| E2E | 少（厚いシナリオ） | Playwright | 主要ユーザーフロー（サインイン→トレンド→ドリルダウン→ウォッチリスト）、テナント越境、収集ヘルス |
| 契約（Contract） | 点 | Vitest + zod | Embedding（FastAPI）/ Gemini 構造化出力 / BigQuery 集計 / `SourceAdapter` の入出力スキーマ |

「少数の厚い E2E ＋ 多数の速い単体」。E2E は壊れやすいので**主要フローと不変条件に限定**し、分岐網羅は単体・結合で稼ぐ。Testcontainers（Node）で Postgres / Elasticsearch を実体として立て、ロジックは本物の DB / ES に対して検証する。

## E2E シナリオ仕様（Playwright）

各シナリオは Given / When / Then で記述し、`@playwright/test` の `projects` で chromium を基本、必要に応じ webkit を追加。

| # | シナリオ | Given | When | Then |
|---|---|---|---|---|
| E1 | サインイン〜トレンド閲覧 | OIDC 登録済みユーザー、グローバル集計 seed 済み | サインイン → `/t/{slug}/trends` | F1 トレンド一覧（用語×時系列）が表示され、グローバルデータが読める |
| E2 | 用語ドリルダウン（F6 エビデンス） | トレンド一覧表示済み | 用語をクリック | 時系列（mentions/share）+ 出典記事リンク（ES `documents`）+ 例文スニペット + 関連語が出る。本文全文ではなくリンクで辿れる |
| E3 | 急上昇/新出の表示（F2） | 検知バッチ実行済み（`detections` あり） | トレンド画面の「急上昇」「新出」タブ | `rising`（z-score 降順）/ `emerging`（distinct_sources 付き）が出典付きで一覧表示 |
| E4 | ウォッチリスト追加 | member 以上、用語ページ表示中 | 「ウォッチに追加」→ ウォッチリスト画面へ | テナントの `watchlists` に登録、再訪で残る。**他テナントには一切出ない** |
| E5 | 新出のクロスソース裏取り表示 | `emerging` 検知（`distinct_sources>=N_min`） | 新出用語を開く | 「複数ソースで言及」が distinct_sources とソース別出典で裏取り表示される（1 媒体連発は新出に出ない） |
| E6 | 技術サマリ（F3 / RAG） | BYOK 設定済みテナント、サマリ未生成の用語 | サマリ生成を要求 | スニペット+メタから要約が生成・キャッシュされ、末尾に根拠リンク + 関連トピックが出る（本文全文はプロンプトに入らない） |
| E7 | 収集ヘルス（F8） | `last_status='parser_broken'` のソースあり | admin で収集ヘルス画面を開く | ソース別 鮮度 / 失敗率 / `parser_broken` が一覧表示、`consecutive_failures` 閾値超がアラート表示 |
| E8 | 用語辞書・正規化（F9） | admin、別名衝突あり（`k8s`/`Kubernetes`） | 別名を正規 term にマージ / 除外語に指定 | 別名が正規 `slug` に畳まれ、以後の集計が統合。除外語は出現に数えない |
| E9 | 検知レビューのフィードバック | 誤検知の `detection`（status=open） | admin が `dismissed` にし原因を別名/除外語へ反映 | 次回検知で再発しない（F9 フィードバックループ） |
| E10 | 権限（admin / member） | admin と member | member で BYOK 設定・ソース管理・検知 confirm/dismiss の **write API** を直接叩く | **サーバ側 403 が一次防御**（UI 非表示は副次）。閲覧は可 |

メインの「ゴールデンパス」は **E1→E2→E4**（サインイン → トレンド閲覧 → 用語ドリルダウン → ウォッチリスト追加）+ **E3/E5**（急上昇・新出の表示）。CI 必須通過に含める。

## セキュリティ E2E：テナント越境分離（最重要）

RLS の不変条件を恒久ガードする。本体トレンドは**グローバル共有**で分離対象外、分離するのは**テナントオーバーレイ**（`tenant_settings` / `watchlists` / `watchlist_items` / プライベート `sources`）のみ（[04_security_multitenant.md](04_security_multitenant.md) の軽量マルチテナント）。アプリ接続は `portfolio_app`（`NOBYPASSRLS`）で行い、`SET LOCAL app.tenant_id` / `app.user_id` をトランザクション先頭で発行する前提。

### 越境マトリクス（テナント単位テーブル）

テナント A と B を作り、A のセッション（`SET LOCAL app.tenant_id = A`）から B のオーバーレイ行を操作できないことを全 CRUD で確認。対象: `tenant_settings` / `watchlists` / `watchlist_items` / プライベート `sources`。

| 操作 | 期待 |
|---|---|
| SELECT 他テナント行 | 0 件（存在が見えない） |
| INSERT に他テナント `tenant_id` 指定 | 拒否（RLS `WITH CHECK` 違反） |
| UPDATE 他テナント行 | 影響 0 行 |
| DELETE 他テナント行 | 影響 0 行 |
| INSERT `sources` に `tenant_id=NULL`（グローバル）指定 | 拒否（`sources_modify` の `WITH CHECK tenant_id IS NOT NULL`。グローバルコーパス汚染・SSRF 起点を防ぐ） |
| INSERT `watchlist_items` に**他テナントの `watchlist_id`** 指定（自 `tenant_id`） | 拒否（複合 FK `(watchlist_id, tenant_id)` 不一致で親子テナントを跨げない） |

### フェイルセーフ

| ケース | 期待 |
|---|---|
| `SET LOCAL app.tenant_id` **未発行**でテナント単位テーブルを SELECT | **空集合**（ポリシーは `current_setting('app.tenant_id', true)` で未設定時 NULL→空。例外を出さないこと） |
| `portfolio_app` ロールに `BYPASSRLS` が付いていない | ロール権限テストで検証（マイグレーション後のスモーク） |
| グローバル共有データ（`terms` / `detections` / `daily_term_stats` / 公開 `documents`） | テナント変数の有無に関わらず**全テナントから読める**ことを確認（過剰分離していないこと） |
| `sources` 混在ポリシー | グローバル（`tenant_id IS NULL`）+ 自テナント分のみ可視。他テナントのプライベートソースは不可、書込は自テナント分のみ |

これらは結合テスト（Testcontainers の Postgres）でも二重化し、CI 失敗時に即検知する。**「テスト設計を自分が握る」面接エピソード**の中核。

## F2 検知ロジックの回帰テスト（核）

検知は閾値・統計式に依存し、静かに壊れるのが最悪。**固定データセット（golden）**で `daily_term_stats` 相当のシリーズを与え、期待される検知結果を assert する。パラメータ（`ε / N_min / M_min / Z_TH / halflife / K`）の較正もここで回す（[05_search_classification.md](05_search_classification.md)）。

| # | ケース | 入力（固定シリーズ） | 期待 |
|---|---|---|---|
| D1 | 新出（emerging）成立 | baseline≈0、直近窓で `distinct_sources>=N_min` かつ `mentions>=M_min` | `type='emerging'`、`distinct_sources` が score、term の `first_seen_at` 記録 |
| D2 | 新出を裏取り不足で却下 | baseline≈0 だが 1 ソースが連発（`distinct_sources<N_min`） | **emerging を出さない**（クロスソース裏取り必須。1 媒体連発はノイズ） |
| D3 | 新出を最小サポート不足で却下 | `distinct_sources>=N_min` だが `mentions<M_min` | emerging を出さない（タイポ・一発ネタ除外） |
| D4 | 急上昇（rising）成立 | ベースラインあり、`share` が急増し `z>=Z_TH`、`mentions>=M_min` | `type='rising'`、score=z。総量正規化済み `share` で判定 |
| D5 | 投稿過多日の偽陽性を抑制 | 全用語が一律に増えた日（生 mentions 増、`share` 横ばい） | rising を出さない（`share` 正規化が効くこと） |
| D6 | 低カウントのノイズ除外 | `z` は高いが `mentions<M_min` | rising を出さない（ベイズ平滑化/最小サポート） |
| D7 | 廃れ（declining）成立 | `share` が trailing peak の一定割合を K 期間連続で下回る（jQuery 型） | `type='declining'`、score=減衰の大きさ |
| D8 | 冪等 upsert | 同 `as-of` で 2 回実行 | `detections` が `(term, type, locale, window_end)` で重複しない |
| D9 | locale 分離 | 同一 `term_slug` を jp / global で別シリーズ | locale ごとに独立に検知（F5 の素） |

- 検知は**順序関係・分岐**で assert し、score の絶対値は固定しない（A が B より rising score 上位、emerging に出る/出ない、等）。
- 固定データセットは BigQuery 実体に依存させず、`dailyTermStats()` をフィクスチャ注入できる形で検知関数を単体テストする。BigQuery への結線は契約テスト（後述）で別途担保。

## 収集テスト：SourceAdapter / FetchContext

収集の作法（礼儀正しさ・堅牢性）を外部サイトに依存させず、ローカルのモックサーバ（msw / nock / ローカル HTTP フィクスチャ）で決定的に検証する（[06_destinations.md](06_destinations.md)）。

| 観点 | テスト |
|---|---|
| **SSRF 防御（最重要）** | プライベート IP / `169.254.169.254`（メタデータ）/ 非 http(s) スキーム / 内部ホストへのリダイレクトを `FetchContext` が拒否すること（[04_security_multitenant.md](04_security_multitenant.md) 信頼境界） |
| **ReDoS 防御** | 病的入力（長大・ネスト構造）で用語抽出がタイムアウト / 入力長上限内に収まり、ワーカーが飽和しないこと |
| robots 遵守 | フィクスチャ robots.txt の `Disallow` / `Crawl-delay` を `FetchContext` が尊重し、禁止パスを取得しないこと |
| レート制御 | `sources.rate_limit_rpm` のトークンバケットで、ホスト別に上限を超える同時取得が起きないこと（時刻をモック） |
| 条件付き GET | 保存済み `ETag` / `If-Modified-Since` を送り、`304` 応答時に再パースせずスキップすること |
| 指数バックオフ | `429` / `5xx` でバックオフ + ジッタが効き、リトライ上限で打ち切ること |
| User-Agent | 連絡先入り UA が常に付与されること |
| Playwright 切替 | `render:true` のときだけ Playwright 経路、静的は `fetch` 経路（呼び分けのみ検証、実ブラウザは最小スモーク） |
| `discover`/`collect` 分離 | フィクスチャ一覧から `DiscoveredRef` を列挙し、各参照を `CollectedItem` に正規化できること |
| **`parser_broken` 検知（F8）** | `discover` が 0 件 / `collect` が必須フィールド欠落のフィクスチャで `last_status='parser_broken'`、`consecutive_failures++` になること |
| 取得成功時のヘルス更新 | 有効アイテムで `last_ok_at` 更新・`consecutive_failures=0` |
| dedup | 同一 `content_hash` を弾き、近重複は embedding kNN で 1 件に寄せること（kNN はモック embedding で順序のみ） |
| データ最小化 | `CollectedItem.body` が抽出後に永続化されないこと（保存対象はメタ + スニペット + 用語 + embedding のみ。[07_data_strategy.md](07_data_strategy.md)） |

`SourceAdapter` は新ソースが増えるので、**1 つの共通テストハーネス**（フィクスチャ in → `CollectedItem` out のスキーマ contract）に各 adapter を通す形にし、追加コストを下げる。

## 契約・結合テスト

| 境界 | テスト |
|---|---|
| Embedding（FastAPI `/embed`） | `mode=query`→`query:` / `mode=passage`→`passage:` プレフィクスが付くこと、戻りベクトル次元（768）、異常時の扱い。zod スキーマで I/O 契約を固定し、実サービスへはスモーク 1 本 |
| Elasticsearch `documents` | Testcontainers の ES に対し、`term_slugs` フィルタの F6 エビデンスクエリ・kNN 関連トピックが期待文書を返すこと、kuromoji アナライザでの日本語ヒット、`content_hash` での重複排除 |
| **ES テナント分離（プライベート文書・fast-follow）** | `visibleDocsQuery(tenantId, q)` チョークポイントが、グローバル文書（`tenant_id` なし）+ 自テナント文書のみ返し、他テナントのプライベート文書を返さないこと。未ログイン（`tenantId=null`）は public のみ |
| **BigQuery 集計の契約** | `occurrences`→`daily_term_stats` の集計式（`mentions` / `distinct_sources` / `distinct_docs` / `share` 総量正規化）が固定入力で期待値を出すこと。`occurred_date` パーティション + `term_slug` クラスタリングでの絞り込み。実 BigQuery でなく**エミュレータ or 固定 SQL のローカル実行 + 入出力スキーマ（zod）**で契約を固定し、本番は集計結果のスモーク 1 本 |
| LLM 構造化出力（F3） | Gemini をモックし、要約・`evidence[]`・`related_terms[]` が zod スキーマに適合すること、スキーマ不一致時のリカバリ分岐。文言は検証しない。**本文全文がプロンプトに入っていない**ことも検証。**プロンプトインジェクション回帰**: スニペットに指示の上書きを試みる命令文を仕込んだ入力で、要約が当該命令に従わず・グローバル `summaries` を汚染しないこと（混入検知ヒューリスティック。具体的な攻撃文言はテストフィクスチャ側に置き、ドキュメントには書かない） |
| Secret Manager（BYOK） | キー保管・取得をモック層で抽象化し、`tenant_settings.llm_secret_ref` の参照→取得経路と、**平文がログに出ない**ことを検証 |
| Postgres↔ES↔BigQuery 同期 | 1 文書の Store で ES `doc_id` 冪等 upsert・BigQuery `occurrences` 追記（`doc_id`+`term_slug` 重複排除）が整合すること、ES/BQ 反映失敗時にリトライ/再インデックスジョブで突合・修復されること（結果整合） |

## テストデータ戦略

- **マルチテナント fixture**：最低 2 テナント（A/B）。テナント越境（オーバーレイ）テストの土台。本体トレンドは共有なのでテナント非依存の seed。
- **グローバル集計 seed**：`terms` / `term_aliases` / `daily_term_stats`（用語×日×ソース×locale）の golden を投入し、F1/F2/F6 の E2E と検知回帰で共用。
- **収集フィクスチャ**：robots.txt・一覧ページ・記事 HTML・API レスポンスのフィクスチャ群（正常 / `parser_broken` / 304 / 429 の各バリアント）。
- **検知 golden データセット**：D1〜D9 用の `daily_term_stats` 相当シリーズ（新出/急上昇/廃れ/偽陽性抑制の各シナリオ）。パラメータ較正の基準値もここに固定。
- **分離**：各結合テストはトランザクションロールバック or `TRUNCATE ... CASCADE` で独立。E2E は専用 seed をテスト前に流す。Testcontainers は per-suite で立て、テスト間はデータをリセット。
- **秘匿値**：テスト用 BYOK キー・OIDC トークンはダミー。リポジトリにコミットしない（gitleaks / pre-commit で担保）。

## CI（GitHub Actions / Node・TS）

- ジョブ：`lint` → `unit`（Vitest）→ `integration`（Testcontainers で postgres / Elasticsearch を起動、BigQuery / Embedding / LLM はモック）→ `e2e`（Playwright）。**dotnet ジョブは廃止**し、Node/TS 一式に統一する。
- Embedding（Python/FastAPI）は契約テスト（zod）+ スモーク 1 本でジョブを分け、ruff / mypy / pytest を回す（唯一の非 TS）。
- Playwright は **trace on first retry** を有効化、失敗時に trace / 動画をアーティファクト保存。
- 失敗ゲート：**RLS 越境テスト**と**F2 検知回帰**、主要 E2E（E1/E2/E3/E4）は**必須通過**。
- カバレッジ：純ロジック（用語正規化・F2 判定式・robots/レート・スニペット）は行カバレッジ目標を設定。UI は E2E でフロー網羅を優先しカバレッジ率は追わない。
- 既存 [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) の backend（dotnet）ジョブを TS/Node 構成へ置換する前提（実コード PR で対応）。

## テストしないと決めたもの（割り切り）

| 対象 | 理由 |
|---|---|
| LLM 要約の文言品質 | 非決定・BYOK 依存。スキーマと分岐・出典リンクの有無のみ検証 |
| Embedding ベクトルの絶対値 | モデル依存で脆い。kNN は順序関係で代替 |
| 外部収集先の本物サイト / API | レート・規約・構造変化。フィクスチャ/モックで作法を固定し、スモーク 1 本のみ実通信 |
| 実 BigQuery への課金クエリ | スキャン量・コスト。集計式はローカル/エミュレータで契約固定、本番はスモーク |
| ピクセル単位のビジュアル回帰 | MVP では過剰（UI は作り込まない方針）。主要画面のスナップショットに留める |

## 完了の定義（各機能 PR 共通）

- [ ] 追加ロジックに単体テスト
- [ ] API 追加に結合テスト（正常系＋テナント越境）
- [ ] ユーザー価値のあるフローに E2E 1 本
- [ ] RLS に触れる変更は越境マトリクスを更新
- [ ] F2 検知に触れる変更は golden データセットの回帰を更新
- [ ] 新 `SourceAdapter` 追加は共通ハーネス + `parser_broken` ケースを通す
- [ ] CI 緑（必須 E2E + RLS 越境 + 検知回帰 通過）
