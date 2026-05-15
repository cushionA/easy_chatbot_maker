# 03. 機能レビュー（easy_chatbot_maker / Service A）

レビュー日: 2026-05-15
対象範囲: `backend/Portfolio.Web/`, `embedding/`, `infra/db/`, 設計文書一式

---

## サマリ

設計文書（`design/` 配下、`platform_proposal.md`）は **MVP 約 70 機能項目 + Phase 2/3 拡張** までかなり詳細に整備されている。一方、実装（`backend/Portfolio.Web/`, `embedding/app/`）は **「地盤工事完了・上物未着工」** の段階：

- **完了**: EF Core エンティティ（10 種、全テナント分離考慮）、DB スキーマ SQL（`infra/db/migrations/0001_schema.sql`、267 行）、FastAPI 埋め込みサーバ（`/healthz`, `/embed`, `/embed/batch`）、Blazor Server の最小骨格（Home.razor で埋め込み次元の動作確認のみ）、ヘルスチェック、Docker Compose 基盤、Caddy
- **未着工**: 認証、テナント切替、マスタ管理画面、分類フロー（コンボボックス／キーワード／BM25／RRF／LLM 全段）、動的フォーム、エスカレーション、起票 Adapter、未分類キュー画面、ログ分析、埋め込みウィジェット、RLS ポリシー、利用ログ画面、ナレッジギャップ検出
- **欠落**: `Services/` に `EmbeddingClient` しかなく、`ITicketDestination`、Redmine/GitHub Adapter、検索エンジン（BM25/RRF）、認証ハンドラ、テナント解決、Vault 連携いずれも未実装
- **テスト**: `HealthTests` 1 本のみ。RLS E2E テスト、検索ロジック、Adapter テスト等は皆無

総体としては、**ポートフォリオ訴求の「面接で語る要素」自体は設計上揃っており、コア実装フェーズ（Sprint 1〜）への移行直前** という状況。本レビューは、これから機能を積み増す際の優先順位を明確化することを主目的とする。

---

## 1. 機能マッピング表（設計 vs 実装）

凡例:
- `✓` = 実装済み・動作可能
- `△` = 部分実装（モデル/スキーマあり、ロジック/UI 不足）
- `×` = 未実装

### 認証・組織管理

| 設計上の機能 | 状態 | 実装箇所 / 不足点 |
|---|---|---|
| サインアップ・サインイン（Supabase Auth） | × | 認証ミドルウェアも未追加（`Microsoft.AspNetCore.Authentication.JwtBearer` パッケージ参照のみ） |
| 組織（テナント）作成・編集 | △ | `Tenant` エンティティ・テーブルあり / 画面・API 無し |
| メンバー招待・ロール管理（admin/member） | △ | `UserTenant.Role` + CHECK 制約あり / 招待フロー無し |
| 組織別ボット URL 払い出し（`/t/{slug}/chat`） | × | `Tenant.Slug` 一意制約あり / ルーティング・スコープ解決無し |

### マスタ管理

| 設計上の機能 | 状態 | 実装箇所 / 不足点 |
|---|---|---|
| ナレッジマスタアップロード（Excel/JSON） | × | DB 受け皿あり / インポート機構無し |
| カテゴリ管理 CRUD | △ | `Category` エンティティ・スキーマあり / 画面無し |
| 問題エントリ管理 CRUD | △ | `KnowledgeEntry`（auto_resolution / guidance_message / ticket_priority / example_queries 列あり） / 画面無し |
| フィールド定義管理（`is_multi` 含む） | △ | `FieldDefinition`（`IsMulti` プロパティ含む） / 画面無し |
| バリデーションルール管理 | △ | `ValidationRule` あり（min/max length, regex, error_message） / 画面無し |

### 分類フロー

| 設計上の機能 | 状態 | 実装箇所 / 不足点 |
|---|---|---|
| カテゴリ選択 UI | × | エンティティあり / Razor 無し |
| コンボボックス | × | Razor コンポーネント未作成 |
| 自然言語入力 | △ | `Home.razor` に test 用 input があるのみ |
| キーワード完全一致検索 | × | `tsvector` 列は `KnowledgeEntry.SearchText` で生成済み / 検索クエリ実装無し |
| BM25 + Embedding ハイブリッド検索（RRF） | × | `tsvector` 列・`vector(768)` 列あり / `Classifier` サービス未実装 |
| `match_count` 重みランキング | × | `KnowledgeEntry.MatchCount` 列あり / 加算ロジック無し |
| LLM フォールバック（Gemini, BYOK） | × | `Shared.LLM` ラッパ無し |
| 新規問題自由入力 → 未分類キュー | △ | `UnclassifiedQueueEntry` あり / 画面・登録 API 無し |

### 3 段階エスカレーション

| 設計上の機能 | 状態 | 実装箇所 / 不足点 |
|---|---|---|
| `auto_resolution` 自動回答 + 「解決した？」 | × | 列はあり / 表示ロジック無し |
| `guidance_message` 表示 → セルフ解決 → フォーム | × | 列はあり / 表示ロジック無し |
| 両方なし → 直接フォーム | × | 分岐ロジック無し |

### 動的フォーム

| 設計上の機能 | 状態 | 実装箇所 / 不足点 |
|---|---|---|
| 全 11 種のフィールド型（text/choice/file...） | × | `FieldDefinition.FieldType` は単なる string、enum/型別レンダラ無し |
| `is_multi` 行追加 UI | × | フラグ列のみ / コンポーネント無し |
| バリデーション（必須/長さ/正規表現/拡張子/サイズ） | × | ルール定義列あり / 検証エンジン無し |
| 確認画面 | × | 未実装 |

### 起票

| 設計上の機能 | 状態 | 実装箇所 / 不足点 |
|---|---|---|
| `ITicketDestination` Adapter インターフェース | × | ファイル無し |
| Redmine Adapter | × | 既存 Streamlit に資産あるが移植無し |
| GitHub Issues Adapter | × | 未着手 |
| destination 登録・編集 + 接続テスト | △ | `Destination` テーブルあり / 画面・接続テスト無し |
| プライマリ＋切替 | △ | `IsPrimary` 列あり / UNIQUE 部分インデックス未確認・UI 無し |
| フィールドマッピング JSONB | △ | `FieldMapping` 列あり / 編集 UI・適用ロジック無し |
| API キー Supabase Vault 保管 | △ | `SecretVaultId` 参照列あり / Vault スキーマ・復号呼出無し |
| 起票本文 Markdown 化（`build_description` 移植） | × | 未移植 |
| 起票失敗時 `draft_fields` 短期保持・リトライ | △ | `Inquiry.DraftFields` 列あり / リトライ／Polly 等無し |

### 引用元表示

| 設計上の機能 | 状態 | 実装箇所 / 不足点 |
|---|---|---|
| マッチした `knowledge_entries` 表示 | × | 未実装 |
| admin 向けマスタ管理リンク | × | 未実装 |

### 未分類キュー

| 設計上の機能 | 状態 | 実装箇所 / 不足点 |
|---|---|---|
| 自由入力登録 | × | テーブルあり / API 無し |
| admin レビュー画面 | × | 未実装 |
| マスタ追加 / 破棄 / コメント | △ | `ReviewedBy` / `ReviewedAt` / `ReviewNote` 列あり / 画面無し |

### ナレッジギャップ検出

| 設計上の機能 | 状態 | 実装箇所 / 不足点 |
|---|---|---|
| `confidence_score` 集計 | △ | `Inquiry.ConfidenceScore` 列あり / 集計画面無し |
| 低確信度回答リスト | × | 未実装 |

### 暗黙フィードバック

| 設計上の機能 | 状態 | 実装箇所 / 不足点 |
|---|---|---|
| `status` / `match_strategy` 記録 | △ | 列あり / 書き込みロジック無し |
| 「解決した？」 → `resolved` | △ | `Inquiry.Resolved` 列あり / UI 無し |

### 埋め込みウィジェット

| 設計上の機能 | 状態 | 実装箇所 / 不足点 |
|---|---|---|
| `tenant_public_keys` テーブル | △ | `TenantPublicKey` あり（key_hash, rate_limit_rpm, allowed_origins） |
| `embed.js` 配信エンドポイント | × | wwwroot に未配置 |
| `<script>` 埋込手順・shadow DOM | × | 未実装 |
| CORS / Origin チェック | × | Program.cs に CORS 設定無し |
| レートリミット | × | `Shared.RateLimit` 無し |
| 匿名 RLS ポリシー（widget 用） | × | RLS ポリシー全体未作成 |

### 利用ログ・分析

| 設計上の機能 | 状態 | 実装箇所 / 不足点 |
|---|---|---|
| 日次・週次・月次の件数 | × | 集計画面無し |
| `match_strategy` 分布 | × | 同上 |
| 上位 N 問題 | △ | `match_count` 列でランキング可能 / 画面無し |
| 未分類キュー件数推移 | × | 同上 |
| 低確信度比率 | × | 同上 |

### 運用

| 設計上の機能 | 状態 | 実装箇所 / 不足点 |
|---|---|---|
| RLS ポリシー E2E テスト | × | RLS ポリシー自体未作成。`HealthTests` 1 本のみ |
| エラー監視（Sentry） | × | パッケージ未追加 |
| Keep-alive ping | × | GitHub Actions workflow 未確認（infra 配下に無し） |
| ヘルスチェック | ✓ | `/healthz`（Blazor 側）+ FastAPI `/healthz` |
| Docker Compose 基盤 | ✓ | `docker-compose.yml` あり |
| Caddy（HTTPS 自動化） | ✓ | `infra/caddy/Caddyfile` あり |

### 既存 Streamlit 機能のカバレッジ

| 既存機能 | 状態 | コメント |
|---|---|---|
| Phase 管理（CATEGORY/CLASSIFY/COLLECT/CONFIRM/DONE） | × | Blazor ページ階層への再構成未着手 |
| `build_query`（直近 3 発言結合） | × | C# 未移植 |
| `search_by_embedding` | △ | FastAPI 側で embed 可能 / pgvector クエリ未実装 |
| `classify`（Embedding + LLM フォールバック） | × | 未移植 |
| `get_candidate_with_solution` | △ | スキーマ列で代替可能 / 取得関数無し |
| `render_field` / `validate_field` / `format_collected_info` | × | 未移植 |
| `build_system_prompt` / `classify`（Ollama→Gemini） | × | 未移植 |
| `build_description`（起票本文 Markdown 化） | × | 未移植 |
| `Candidate` / `ClassificationResult` 構造化出力 | × | C# record 未定義 |
| MOCK_MODE | △ | embedding 側に `FAKE_EMBEDDER=1` あり / 分類側未対応 |

### Phase 2 / Phase 3

| 機能 | 状態 |
|---|---|
| Re-ranker / HyDE / マルチターン強化 | × |
| `document_chunks` / PDF・Word 取込 | × |
| Git リポジトリ同期 / webhook | × |
| Transformers.js ブラウザ embedding | × |
| PII マスキング / GDPR エクスポート | × |
| 管理画面の会話履歴閲覧・CSV エクスポート | × |
| Slack / Teams / Discord 連携 | × |
| Jira / Backlog / Notion / Asana / Linear Adapter | × |
| 日本語特化モデル FT / ONNX 化 | × |

---

## 2. 欠けている重要機能（優先度付き）

### P0（MVP の根幹、これが無いと「動くデモ」にならない）

1. **認証・テナント解決ミドルウェア**
   - JWT 検証 + `user_tenants` ルックアップ + `/t/{slug}/chat` のスコープ検証は全機能の前提。
   - ユーザー価値: テナント分離が無いと「マルチテナント SaaS」のストーリーが成立しない。面接の中核訴求が破綻する。

2. **RLS ポリシー SQL の作成と適用**
   - 設計（`design/04_security_multitenant.md`）に SQL 例はあるが、`infra/db/migrations/` に未反映。
   - ユーザー価値: 漏洩はサイレント。RLS が無い状態で機能を積むほど、後から「全テーブル分書き直し」のリスクが増える。

3. **分類フローの本体（コンボボックス → キーワード → BM25 + Embedding RRF）**
   - 設計済みの差別化軸。`tsvector` / `vector(768)` 列はあるので、`Services/Classifier.cs` を作って 4 段の検索を実装する。
   - ユーザー価値: 「ハイブリッド検索」「3 段階エスカレーション」は面接 1 番訴求。

4. **動的フォーム（11 種フィールド型 + `is_multi` + バリデーション）**
   - `field_definitions` 駆動の Blazor `<DynamicField>` コンポーネント。
   - ユーザー価値: 設計書で「差別化軸 #1」と明言されている機能。Streamlit 版から移植する明確な資産がある。

5. **`ITicketDestination` インターフェース + Redmine + GitHub Issues Adapter**
   - 設計（`design/06_destinations.md`）にインターフェース定義 + フィールドマッピング JSON 例まで揃っている。
   - ユーザー価値: 「Adapter パターン」で抽象化を語る根拠。

6. **マスタ管理 CRUD 画面（最低: カテゴリ・知識エントリ・フィールド定義）**
   - 採用デモで「Excel から取り込んだマスタ」を見せるために必須。
   - ユーザー価値: 管理画面なしではデモが手で SQL 叩く格好になる。

7. **起票本文 Markdown 化（`build_description` 移植）**
   - 起票実装と組で必要。

### P1（MVP 完成度を上げる、面接訴求の幅を広げる）

8. **未分類キュー UI + 暗黙シグナル記録**
   - `inquiries.status` / `match_strategy` / `confidence_score` の書き込みと admin 向けレビュー画面。
   - 「フィードバックループ」のストーリーを完結させる。

9. **Supabase Vault または等価な暗号化保管**
   - `destinations.secret_vault_id` 参照だけあって保管側が未実装。Oracle Cloud 自前運用なら pgsodium を直接使う必要があるので、設計の早期確定が必要。

10. **埋め込みウィジェット (`embed.js` + CORS + レートリミット + 匿名 RLS)**
    - 差別化軸 #6。Shadow DOM・公開鍵検証・Origin チェックまでセットで作る。

11. **利用ログ・分析画面**
    - Inquiry 集計画面。grafana 等は要らず、Razor で SQL クエリすればよい。

12. **LLM フォールバック（Gemini BYOK ラッパ）**
    - `Shared.LLM` 抽象（テナント別 API キー）+ `classify` プロンプト移植。

### P2（採用面接でのストーリー強化、Phase 2 要素）

13. **マスタ Excel/JSON アップロード**
    - 既存 Streamlit の `data.xlsx` をそのまま取込めると、デモテナント作成が楽。

14. **接続テスト機能（destination 登録時）**
    - 失敗時に登録させないガードで運用品質を訴求。

15. **Sentry 連携 + 構造化ログ**
    - 監視の話を面接で出せる。

16. **RLS E2E テスト（テナント間漏洩確認）**
    - 「漏洩確認テストを書いた」と語れる資産。AI に書かせるにせよ、ケースを自分で定義する必要がある。

17. **ナレッジギャップ検出ダッシュボード**
    - 「データから改善する PM 視点」を訴求。

---

## 3. 改善余地のある機能（既に着手済み or 計画済みの箇所）

### 3.1 `EmbeddingClient` の堅牢化

現状（`backend/Portfolio.Web/Services/EmbeddingClient.cs`）:
- リトライ無し（一時的なネットワーク障害で即失敗）
- バッチ API（`/embed/batch`）を呼べる関数が無い
- レスポンスのモデル名・次元数を検証していない（モデル切替時の安全弁が無い）

改善案:
- `Polly` で指数バックオフリトライ（HTTP 5xx + タイムアウト）
- `EmbedBatchAsync(IReadOnlyList<string>)` 追加（マスタ embedding 再計算でバッチ必須）
- レスポンスの `model` を検証し、`knowledge_entries.embedding_model` 列と一致しない場合は警告ログ

### 3.2 `Embedder` クラスの query/passage プレフィックス

現状（`embedding/app/embedder.py`）:
- すべてのテキストに `query: ` プレフィックスを付与している（39 行目）。
- multilingual-e5 では **クエリは `query:`、文書は `passage:`** を付ける規約。マスタ embedding でも `query:` を付けると recall が劣化する。

改善案:
- `embed(texts, kind: Literal["query","passage"])` のように切替可能にする
- `/embed/passage` エンドポイントを追加 or リクエスト本体に `kind` を載せる
- CLAUDE.md にもこの規約は書かれている。ここでの誤用は仕様違反。

### 3.3 EF Core モデルの完成度

現状:
- `Destination` の `IsPrimary` に `UNIQUE WHERE is_primary` の部分インデックスが未定義（EF 側）。SQL 側は `0001_schema.sql` で確認推奨。
- `KnowledgeEntry.SearchText` の `to_tsvector` は `simple` configuration を使用しているが、日本語形態素解析（`pgroonga` / `textsearch_ja`）が必要かは検討余地。`simple` のみだと「印刷できない」等の部分一致が弱い。
- `Inquiry.QueryEmbedding` も `vector(768)` 固定。モデル変更時に次元差分が出ると壊れるので、設計通り `embedding_model` 列との整合を実行時に取る仕組みが要る。

改善案:
- IVF / HNSW インデックスの追加（`embedding` 列）。設計 02 で HNSW を謳っているのに DB スキーマで確認要。
- `tsvector` の日本語対応（少なくとも面接でのデモ精度のため `pgroonga` 検討）。

### 3.4 `HealthTests` だけのテスト戦略

現状: テストは Blazor 側 1 本、embedding 側 5 本のみ。

改善案:
- Testcontainers で Postgres + pgvector を立てた **RLS テスト**（テナント間漏洩確認、SELECT/INSERT/UPDATE/DELETE 4 種類）
- `Classifier` のユニットテスト（BM25 / Embedding / RRF / match_count 重み各段）
- `ITicketDestination` Adapter のテスト（Mock HTTP で Redmine / GitHub API レスポンスを検証）

### 3.5 セキュリティ・運用観点

- **CORS**: `Program.cs` に明示無し。`embed.js` 経由の匿名アクセスを受けるので、公開鍵検証と Origin allow-list が必要。
- **アンチフォージェリ**: `app.UseAntiforgery()` は入っているが、`/embed` 等の API 経路の policy 設計はまだ。
- **HSTS**: 設定済み。
- **Secret 管理**: 現状 Vault 未実装。`appsettings.json` には secret 無し（`Embedding:BaseUrl` のみ）。
- **ログ機密**: ガイドライン上 JWT/SQL params をログしない方針だが、ロガー設定が未整備。
- **レートリミット**: 公開ウィジェット用に必須。`AspNetCoreRateLimit` 等の導入時期を早めに。

### 3.6 UX / 機能性

- `Home.razor` がいきなり test 入力欄。**少なくともテナント選択 → カテゴリ選択へのナビゲーション骨格** を早期に置くと、後続実装の取り回しが楽。
- レイアウト（`MainLayout.razor`）が極小（h1 のみ）。サイドバー / ヘッダー / モバイル幅対応は採用デモで効くので Sprint 1 で整える。

---

## 4. 不要 / 削減候補の機能（over-engineering）

### 4.1 過剰な可能性: テーブル数

10 種のエンティティはマスタ管理機能としては適正だが、MVP デモ範囲（採用面接で 5 分見せる）を考えると **`validation_rules` テーブル** は最初は省略可能。
- 「最大文字数 / 必須」程度は `field_definitions` に直接持たせれば事足りる。
- 正規表現バリデーションを実装するのは面倒な割に面接で語れる量は少ない。
- **判断**: 残す方が「実プロダクト感」が出るので、最終的には残してよい。ただし優先度は P2 で OK。

### 4.2 `TenantPublicKey.AllowedOrigins` / `RateLimitRpm` の早すぎる作り込み

埋め込みウィジェット自体が Phase 2 寄りなのに、関連テーブルだけ MVP 段階で作ってある。
- **判断**: テーブル自体は残してよいが、レビュー観点では「ウィジェット実装の優先度を上げるか、テーブルを Phase 2 まで保留にするか」のどちらかに揃えるべき。中途半端な「テーブルだけある」状態は最も価値が低い。

### 4.3 `Inquiry.DraftFields` の短期保持仕様

`draft_fields` を JSONB で持つ設計は良いが、「短期保持 + 成功時 NULL クリア」の運用 cron が無いと残骸蓄積する。
- **判断**: 起票機能と同時に **TTL ジョブ** までセットで設計する必要がある。単独で実装すると debug 用残骸でしかない。

### 4.4 Phase 3 機能群（Slack/Teams/Discord、Jira/Backlog/Notion/Asana/Linear、音声、OGP）

設計書には列挙されているが、**ポートフォリオ訴求としては「語るだけ」で十分**。実装しなくてよい。Adapter パターンを示せるなら 2 種（Redmine + GitHub Issues）で十分。

### 4.5 `Shared.*` モジュール群（platform_proposal）

`/Shared.Auth`, `/Shared.LLM`, `/Shared.UI`, `/Shared.Domain`, `/Shared.Notification`, `/Shared.Analytics`, `/Shared.RateLimit` が宣言されているが、Service B（Ronkaku）が無い現状では over-engineering。
- **判断**: 1 つのソリューションに直書きで OK。Service B 着手時に切り出す。「YAGNI」を採用面接で語れる材料にもなる。

### 4.6 `auth.users` スタブ（`0001_schema.sql` 上の `CREATE SCHEMA auth`）

Oracle Cloud 自前運用パスのみ必要。Supabase 運用ならコメントアウト必須。
- **判断**: スキーマ生成パスをホスティングプランで分岐できるよう、`init.sql` 側で条件付きに。あるいは「最初から Supabase 想定」に倒すなら削除。

---

## 5. ロードマップ提案（フェーズ分け）

### Sprint 0（完了済み・現在の状態）

- [x] Blazor Web App 雛形
- [x] EF Core エンティティ 10 種
- [x] DB スキーマ migration（0001）
- [x] FastAPI 埋め込みサービス
- [x] Docker Compose / Caddy
- [x] Health endpoint + 動作確認 Razor

### Sprint 1（短期: 1〜2 週間）— "デモが動く" 最小セット

目的: **採用面接で「ローカル起動 → カテゴリ選択 → 自然言語 → 候補 → 起票」が通る** ところまで。

- [ ] **認証スタブ + テナント解決ミドルウェア** ※Supabase Auth の代わりにローカル開発用簡易ログインで OK
- [ ] **RLS ポリシー migration（0002）** + Testcontainers での RLS E2E テスト 1 本
- [ ] **マスタシーディング**（既存 `data.xlsx` を JSON 変換 → ローカル DB 投入スクリプト）
- [ ] **分類フロー本体**（`Classifier` サービス: keyword exact → BM25 → embedding → RRF → match_count 重み）
- [ ] **コンボボックス + 自然言語入力の Blazor コンポーネント**
- [ ] **動的フォーム最小版**（text / choice / radio / date / number / bool の 6 型 + is_multi）
- [ ] **`ITicketDestination` + Redmine Adapter + GitHub Issues Adapter**
- [ ] **`build_description` 移植**
- [ ] **3 段階エスカレーション分岐**（auto_resolution / guidance_message / 直接フォーム）
- [ ] **EmbeddingClient の query/passage 区別修正**（バグ修正性質、Sprint 1 中に）

### Sprint 2（中期: 2〜4 週間）— "ポートフォリオとして見せられる" レベル

- [ ] **マスタ管理 CRUD 画面**（カテゴリ・知識エントリ・フィールド定義）
- [ ] **未分類キュー UI**（admin レビュー画面、マスタ昇格 or 破棄）
- [ ] **暗黙シグナル記録**（match_strategy, confidence_score の書き込み）
- [ ] **利用ログ・分析画面**（最低: 件数推移 + match_strategy 分布 + match_count Top10）
- [ ] **接続テスト機能**（destination 登録時に TestConnectionAsync 呼出）
- [ ] **マスタアップロード**（Excel / JSON、最低 JSON）
- [ ] **Sentry 連携**
- [ ] **構造化ログ + リクエストロガー**
- [ ] **LLM フォールバック**（BYOK Gemini, 任意機能として）
- [ ] **「解決した？」ボタン + `inquiries.resolved` 書込**
- [ ] **残りフィールド型（time / datetime / file / text_short / multi）**

### Sprint 3（長期: 1〜2 ヶ月、Phase 2 相当）

- [ ] **埋め込みウィジェット (`embed.js`)** ※shadow DOM, Origin check, rate limit, 匿名 RLS ポリシー
- [ ] **Supabase Vault または pgsodium 直接利用**（API キー暗号化）
- [ ] **ナレッジギャップ検出ダッシュボード**
- [ ] **マルチターン文脈保持**（直近 3 発言結合）
- [ ] **Re-ranker（bge-reranker）** ※面接の「拡張で語る」用、実装するなら Sprint 3 後半
- [ ] **`document_chunks` + PDF アップロード**（チャンクベース RAG）
- [ ] **Git リポジトリ同期**（GitOps for knowledge base）

### "やらない" / 語るだけ（Phase 3 相当）

- Slack / Teams / Discord 連携
- Jira / Backlog / Notion / Asana / Linear Adapter
- 音声入出力
- A/B プロンプトテスト
- 多言語対応
- 日本語特化モデル FT + ONNX 化
- Transformers.js ブラウザ embedding 化

これらは設計書で「拡張可能性」として語る材料に留め、実装はしない。

---

## 6. ユーザー価値観点での優先順位（採用面接インパクト × 実装コスト）

| 順 | 機能 | 採用インパクト | 実装コスト | 備考 |
|---|---|---|---|---|
| 1 | 認証 + テナント解決 + RLS | 高 | 中 | 全機能の前提 |
| 2 | 分類フロー（ハイブリッド検索）本体 | 最高 | 中 | 差別化軸 #5、面接の中核 |
| 3 | 動的フォーム + バリデーション | 最高 | 中 | 差別化軸 #1、Streamlit 移植資産あり |
| 4 | Adapter（Redmine + GitHub Issues） | 高 | 中 | 差別化軸 #3、Streamlit 移植資産あり |
| 5 | 3 段階エスカレーション分岐 | 高 | 小 | 差別化軸 #2、ロジック小 |
| 6 | マスタ管理 CRUD | 中 | 中 | デモ進行に必須 |
| 7 | 未分類キュー UI + 暗黙シグナル | 中 | 小 | 差別化軸 #7、フィードバックループ訴求 |
| 8 | 埋め込みウィジェット | 高 | 大 | 差別化軸 #6、Sprint 3 推奨 |
| 9 | 利用ログ・分析 | 中 | 小 | データ意識を訴求 |
| 10 | LLM フォールバック（BYOK） | 中 | 小 | 差別化軸 #4 |
| 11 | Vault 暗号化 | 中 | 中 | セキュリティ訴求 |
| 12 | Sentry + 構造化ログ | 小 | 小 | 運用感覚訴求 |
| 13 | マスタアップロード（Excel） | 小 | 中 | デモ準備の効率化 |
| 14 | ナレッジギャップ検出 | 小 | 小 | 8 と組み合わせて訴求倍化 |
| 15 | Phase 2 拡張（Re-ranker / PDF / Git 同期） | 中 | 大 | 「拡張余地」として語るなら不要 |

---

## 7. 全体所感

- **設計品質は非常に高い**（採用面接で読み合わせできるレベル）。差別化軸 7 つを明示し、Phase 分けと却下機能も明文化されている。
- **実装はまだ「Sprint 0 完了」段階**。地盤工事（DB スキーマ / EF Core / embedding サービス / Docker / health）は終わっているので、ここから機能を 1 つずつ積めば形になる。
- **最大のリスク**: 「設計は綺麗だが動かない」状態のまま放置されること。Sprint 1 で **最小デモパス** を貫通させ、「動く」状態を早期に作るのが採用ポートフォリオとして最も価値が高い。
- **二番目のリスク**: RLS ポリシーを書かずに機能を増やすと、後から全テーブルの policy 追加とテスト書き直しが必要になる。**Sprint 1 で RLS を最初に通すこと** を強く推奨。
- **三番目のリスク**: Embedding の `query:` / `passage:` プレフィックス誤用は **デモの精度を直接下げる**。CLAUDE.md にも記載のとおりであり、Sprint 1 で必ず修正する。

---

参照したファイル:

- `/home/user/easy_chatbot_maker/design/01_overview.md` ～ `12_interview_narratives.md`（一部のみ確認、08/06/05/04/10/01/09/02 を中心に通読）
- `/home/user/easy_chatbot_maker/platform_proposal.md`
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Program.cs`
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Data/AppDbContext.cs`
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Data/Entities/*.cs`（10 ファイル）
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Components/Pages/Home.razor`
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Components/Layout/MainLayout.razor`
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Components/App.razor`
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Components/Routes.razor`
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Services/EmbeddingClient.cs`
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Services/IEmbeddingClient.cs`
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web.Tests/HealthTests.cs`
- `/home/user/easy_chatbot_maker/embedding/app/main.py`
- `/home/user/easy_chatbot_maker/embedding/app/embedder.py`
- `/home/user/easy_chatbot_maker/embedding/app/models.py`
- `/home/user/easy_chatbot_maker/embedding/tests/test_main.py`
- `/home/user/easy_chatbot_maker/embedding/tests/conftest.py`
- `/home/user/easy_chatbot_maker/infra/db/init.sql`
- `/home/user/easy_chatbot_maker/infra/db/migrations/0001_schema.sql`
- `/home/user/easy_chatbot_maker/backend/CLAUDE.md`
- `/home/user/easy_chatbot_maker/embedding/CLAUDE.md`
