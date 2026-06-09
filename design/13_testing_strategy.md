# 13. テスト戦略・テスト仕様

## 方針

- **テストは設計の一部**。機能を作ってから足すのではなく、各機能の「完了の定義」にテストを含める（求人の必須要件「Web アプリ開発のコーディングから**テスト**まで」、担当工程の「テスト」、歓迎要件の上流＝**テスト設計**に対応）。
- **漏洩・不変条件は必ず自動テスト化**。特に RLS のテナント越境がないことは、書き間違えると即漏洩なので E2E で恒久ガードする。
- **非決定的な出力は内容を assert しない**。LLM 応答や Embedding の数値そのものは検証対象にせず、**構造化出力のスキーマ妥当性・分岐の正しさ・スコア順序**を検証する（不安定なテストを作らない）。
- スタックは [02_architecture.md](02_architecture.md) に合わせ TypeScript / Node 一式（Playwright / Vitest）。ML 推論サービスのみ Python のため**契約テスト**で境界を守る。

## テストピラミッド

| 層 | 比率目安 | 道具 | 対象 |
|---|---|---|---|
| 単体（Unit） | 多 | Vitest | 純ロジック：RRF 結合、`match_count` 重み、閾値判定、フィールドバリデーション、起票本文 Markdown 生成、フィールドマッピング |
| 結合（Integration） | 中 | Vitest + supertest + Testcontainers | API 層：DB（PostgreSQL/RLS）・Elasticsearch・Embedding/LLM/起票先はモック or コンテナ |
| E2E | 少（厚いシナリオ） | Playwright | 主要ユーザーフロー、テナント分離、埋め込みウィジェット |
| 契約（Contract） | 点 | Vitest + zod | Embedding（FastAPI）/ Gemini 構造化出力 / 起票 Adapter の入出力スキーマ |

「少数の厚い E2E ＋ 多数の速い単体」。E2E は壊れやすいので**主要フローと不変条件に限定**し、分岐網羅は単体・結合で稼ぐ。

## E2E シナリオ仕様（Playwright）

各シナリオは Given / When / Then で記述し、`@playwright/test` の `projects` で chromium を基本、必要に応じ webkit を追加。

| # | シナリオ | Given | When | Then |
|---|---|---|---|---|
| E1 | サインアップ〜テナント作成 | 未登録ユーザー | OIDC サインアップ → テナント作成 | `/t/{slug}/chat` が払い出され、admin ロールで管理画面に入れる |
| E2 | メンバー招待とロール | admin | member を招待 | member はマスタ編集 UI が非表示／403、チャットは可 |
| E3 | マスタ取込 | admin | Excel（既存 `data.xlsx` 流用）/ JSON をアップロード | カテゴリ・問題エントリ・フィールド定義が反映、件数一致 |
| E4 | 分類：ドロップダウン確定 | 取込済みテナント | カテゴリ → コンボボックスで問題選択 | `match_strategy=dropdown` で確定、確認画面へ |
| E5 | 分類：キーワード完全一致 | 同上 | 問題名を自然言語入力 | exact ヒット → `match_strategy=keyword` で即確定 |
| E6 | 分類：ハイブリッド | 同上 | 曖昧な自然文を入力 | 上位候補が提示され、選択 → `match_strategy=hybrid` |
| E7 | 3段階エスカレーション | `auto_resolution` あり／`guidance` あり／両方なし の3エントリ | それぞれ確定 | ①自動回答＋「解決した？」②ガイダンス→フォーム③直接フォーム |
| E8 | 動的フォーム + is_multi | 起票エントリ | `is_multi` フィールドで行追加し送信 | 値が配列で送信、バリデーション（必須・文字数・正規表現・拡張子・サイズ）が UI とサーバ両方で発火 |
| E9 | 起票（Redmine/GitHub） | destination 登録済み（モックサーバ） | フォーム送信 → 起票 | チケット作成 API が期待ペイロードで呼ばれ、チケット URL を表示 |
| E10 | 起票失敗→リトライ | destination が一時 500 | 起票実行 | `draft_fields` 保持、リトライで成功、二重起票しない |
| E11 | 未分類キュー | どの段でも該当なし | 「新規問題として」自由入力 | `unclassified_queue` 登録、admin レビュー画面に出現 → マスタ追加で解消 |
| E12 | 埋め込みウィジェット | 公開鍵発行済みテナント | 別オリジンの HTML に `embed.js` 設置 | Shadow DOM で隔離表示、匿名スコープでチャット可、許可外オリジンは CORS で拒否 |

## セキュリティ E2E：テナント分離（最重要）

RLS の不変条件を恒久ガードする。アプリ接続は `portfolio_app`（`NOBYPASSRLS`）で行い、`SET LOCAL app.tenant_id` / `app.user_id` をセッションに発行する前提（[04_security_multitenant.md](04_security_multitenant.md)）。

### 越境マトリクス

テナント A と B、各テーブル（`knowledge_entries` / `categories` / `field_definitions` / `inquiries` / `unclassified_queue` / `destinations` / `tenant_public_keys` …）に対し、A のセッションから B の行を操作できないことを全 CRUD で確認。

| 操作 | 期待 |
|---|---|
| SELECT 他テナント行 | 0 件（存在が見えない） |
| INSERT に他テナント `tenant_id` 指定 | 拒否（RLS WITH CHECK 違反） |
| UPDATE 他テナント行 | 影響 0 行 |
| DELETE 他テナント行 | 影響 0 行 |

### フェイルセーフ

| ケース | 期待 |
|---|---|
| セッション変数 `app.tenant_id` 未設定でクエリ | **空集合**（ポリシーは `current_setting('app.tenant_id', true)` で未設定時 NULL→空。例外を出さないこと） |
| `portfolio_app` ロールに `BYPASSRLS` が付いていない | ロール権限テストで検証（マイグレーション後のスモーク） |
| 匿名（ウィジェット）スコープ | 自テナントの公開許可データのみ。admin 用テーブル・他テナントは不可 |

これらは結合テスト（DB コンテナ）でも二重化し、CI 失敗時に即検知する。**「テスト設計を自分が握る」面接エピソード**の中核。

## 検索品質の回帰テスト

非決定でない範囲を golden set で固定する。固定テナントに既知エントリを seed し、クエリ→期待挙動を表で持つ。

| 観点 | 検証内容 |
|---|---|
| RRF 結合（単体） | BM25 順位と Embedding 順位を入力 → `RRF = Σ 1/(k+rank)`（k=60）の期待スコア・並び |
| `match_count` 重み（単体） | `final = RRF + α·log(1+match_count)`（α=0.1）。`match_count` 1 と 100 で 100 倍にならない（対数頭打ち） |
| 閾値分岐（結合） | top1 ≥ `THRESHOLD_CONFIDENT` → 候補提示／中間 → 3 候補確認／< `THRESHOLD_LOW` → LLM フォールバック段へ |
| キーワード完全一致 | `name.raw`（keyword サブフィールド）への `term` で exact ヒット → ハイブリッドを経ず即確定。解析済み text では exact 一致しないことも担保 |
| カテゴリ「わからない」 | `category_id` 条件を外して全件横断検索になる |
| Embedding モデル混在 | `embedding_model` が `current_model` 不一致の行は BM25 のみ対象 |
| LLM フォールバック | Gemini をモックし、**構造化出力スキーマ（zod）に適合**することと Pattern ID 引き当て分岐のみ検証（文言は検証しない） |

検索ランキングは閾値定数に依存するため、テストは**順序関係（A が B より上位）**で書き、絶対スコアに固定しない。

## 契約・結合テスト

| 境界 | テスト |
|---|---|
| Embedding（FastAPI `/embed`） | `mode=query`→`query:` / `mode=passage`→`passage:` プレフィクスが付くこと、戻りベクトル次元、異常時の扱い。zod スキーマで I/O 契約を固定し、実サービスへはスモーク 1 本 |
| 起票 Adapter | `ITicketDestination` をモック（msw / nock）。Redmine（priority_id 等）・GitHub（ラベル）への**フィールドマッピング（JSONB）**が正しく変換されること、`testConnection` の成功 / 失敗分岐（APIキー無効・URL到達不可・権限不足）、primary 切替、fan-out しないこと |
| LLM 構造化出力 | JSON Schema 指定の戻りを zod で検証、スキーマ不一致時のリカバリ分岐 |
| Secret Manager（BYOK） | キー保管・取得をモック層で抽象化し、**平文がログに出ない**ことを検証 |
| Postgres↔ES 同期 | `knowledge_entries` の作成/更新/削除後に ES ドキュメントが一致すること、ES 反映失敗時に再インデックスジョブで Postgres を真として修復されること（結果整合） |

## テストデータ戦略

- **マルチテナント fixture**：最低 2 テナント（A/B）＋匿名ウィジェット用。越境テストの土台。
- **デモテナント seed**：既存 Streamlit 版 `data/data.xlsx` を取込スクリプトで投入し、E2E と手動デモで共用。
- **分離**：各結合テストはトランザクションロールバック or `TRUNCATE ... CASCADE` で独立。E2E は専用 seed をテスト前に流す。
- **秘匿値**：テスト用 BYOK キー・OIDC トークンはダミー。リポジトリにコミットしない（gitleaks / pre-commit で担保）。

## CI（GitHub Actions）

- ジョブ：`lint` → `unit`（Vitest）→ `integration`（service containers: postgres / OpenSearch / embedding を docker 起動）→ `e2e`（Playwright）。
- Playwright は **trace on first retry** を有効化、失敗時に trace/動画をアーティファクト保存。
- 失敗ゲート：RLS 越境テストと主要 E2E（E1/E3/E7/E9/E12）は**必須通過**。
- カバレッジ：純ロジック（RRF・重み・バリデーション・マッピング）は行カバレッジ目標を設定。UI は E2E でフロー網羅を優先しカバレッジ率は追わない。
- 既存 [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) の backend ジョブを TS/Node 構成へ置換する前提（実コード PR で対応）。

## テストしないと決めたもの（割り切り）

| 対象 | 理由 |
|---|---|
| LLM 応答の文言品質 | 非決定・BYOK 依存。スキーマと分岐のみ検証 |
| Embedding ベクトルの絶対値 | モデル依存で脆い。順序関係で代替 |
| 外部起票先の本物 API | レート・副作用。モックで契約を固定し、スモーク 1 本のみ実通信 |
| ピクセル単位のビジュアル回帰 | MVP では過剰。主要画面のスナップショットに留める |

## 完了の定義（各機能 PR 共通）

- [ ] 追加ロジックに単体テスト
- [ ] API 追加に結合テスト（正常系＋テナント分離）
- [ ] ユーザー価値のあるフローに E2E 1 本
- [ ] RLS に触れる変更は越境マトリクスを更新
- [ ] CI 緑（必須 E2E 通過）
