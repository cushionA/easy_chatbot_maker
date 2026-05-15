# 02. 設計・アーキテクチャレビュー（Service A：RAGチャットボット生成サービス）

レビュー日：2026-05-15
対象：`/home/user/easy_chatbot_maker`（設計フェーズ完了・実装フェーズ着手直後）
レビュー観点：技術スタック妥当性／アーキテクチャ全体／設計ドキュメント完成度／拡張性・セキュリティ

---

## 1. アーキテクチャ概要（実装から読み取った構成）

### 全体構成

```
[ブラウザ]
   │  HTTPS (HSTS / no-sniff / strict-origin)
   ↓
[Caddy 2-alpine]  (profiles=prod)
   │  /api/embed* → embedding:9000
   │  /*          → backend:8080  (X-Forwarded-Proto/For 付与)
   ↓
[backend: Portfolio.Web]
   .NET 8 + ASP.NET Core + Blazor Server
   - InteractiveServer レンダリングモード
   - EF Core 8.0.10 + Npgsql + Pgvector(0.2.0)
   - HealthChecks (/healthz)
   - HttpClient typed: IEmbeddingClient → http://embedding:9000
   │
   ├─→ [embedding: FastAPI]
   │     Python 3.11, sentence-transformers
   │     intfloat/multilingual-e5-base (CPU)
   │     /healthz /embed /embed/batch
   │     L2正規化済み、`query: ` プレフィクス固定
   │     FAKE_EMBEDDER=1 でモデルDL回避（CI用）
   │
   └─→ [postgres: pgvector/pgvector:pg16]
         init.sql: vector / pg_trgm / uuid-ossp 拡張
         migrations/0001_schema.sql: 全テーブル + HNSW + GIN + match_count トリガ
         RLS は未適用（コメント残し）
```

### 永続層

- 全テーブル定義は `infra/db/migrations/0001_schema.sql` に同梱され、Docker 起動時に自動投入
- EF Core 側は `backend/Portfolio.Web/Data/AppDbContext.cs` で同等の構造をモデリング（スネークケース変換ロジック付き）
- 設計書 `design/03_db_schema.md` に列挙された 10 テーブル（auth.users スタブを除く）が SQL／エンティティ／DbSet で 1:1 に揃っている

### Blazor レンダリングモード

- `Program.cs`：`AddInteractiveServerComponents()` + `AddInteractiveServerRenderMode()`
- `Components/Pages/Home.razor`：`@rendermode InteractiveServer` を明示
- App.razor は `blazor.web.js`（Blazor Web App テンプレート、.NET 8 新方式）を読み込み
- WebAssembly / Auto は未採用。サーバサイドのみ。

---

## 2. 採用技術の評価

| 技術 | 評価 | 理由 |
|---|---|---|
| **.NET 8 LTS + Blazor Server** | ○ | 既存スキル（Unity C#）活用、SignalR 標準搭載、`<TreatWarningsAsErrors>` + `<Nullable>` + `<InvariantGlobalization>` と堅実な設定。レンダリングモード方針も Server 一本に絞られていて迷いがない。 |
| **EF Core 8 + Npgsql + Pgvector** | ○ | `NpgsqlDataSourceBuilder.UseVector()` で pgvector 直結、`HasColumnType("vector(768)")` / `HasComputedColumnSql(stored:true)` で tsvector も正しく扱える。 |
| **FastAPI + sentence-transformers** | ○ | `multilingual-e5-base` の C# 直接運用は ONNX 化が必要で重い。HTTP 境界を切ったことで Phase 2 で Transformers.js への置換も容易（`design/07` と整合）。`FAKE_EMBEDDER=1` の存在は CI 設計として優秀。 |
| **PostgreSQL + pgvector + pg_trgm** | ○ | ハイブリッド検索（BM25 + Embedding RRF）に必要な拡張が全て揃う。HNSW（vector_cosine_ops）と GIN（tsvector）の両方が migration で構築済み。 |
| **Caddy リバースプロキシ** | ○ | HTTPS 自動取得、HSTS/no-sniff/Referrer-Policy 設定済み。`profiles: [prod]` で開発時は外せる構成も良い。 |
| **Docker Compose 構成** | ○ | healthcheck によるサービス間依存、env_file 経由のシークレット分離、named volume での HF モデルキャッシュ（`hf_models`）。 |
| **Supabase Auth (Plan B)** | △ | 設計書では「採用」だが、Plan A（Oracle Cloud + 自己ホスト）では Supabase Auth は使えない。`migrations/0001_schema.sql` の auth.users が「スタブ」になっており、Plan A 時の認証実装はまだ不在。`AddAuthentication().AddJwtBearer()` 系の登録が `Program.cs` に無い。 |
| **Supabase Vault (pgsodium)** | △ | 設計書では API キー保管に Vault を前提とするが、Plan A の自前 Postgres では pgsodium をセットアップする必要があり、`init.sql` では拡張作成されていない。Plan A/B の代替手段が未整理。 |
| **Gemini BYOK** | ○ | サーバ側 API キー保持を回避してコスト爆発を抑える設計判断は妥当。CLAUDE.md にも「LLM キーは appsettings から読まない」と明文化されており規律が良い。 |

---

## 3. 設計と実装の乖離（具体的なファイル参照付き）

### 3.1 RLS が未適用（重要）

- 設計：`design/04_security_multitenant.md` で全テーブルに RLS ポリシー必須
- 実装：`infra/db/migrations/0001_schema.sql:243-251` でコメントアウト
- 影響：現状の DB は **テナント越境クエリを物理的に許す**状態。EF Core 側 (`AppDbContext.cs`) にもグローバルクエリフィルタが未設定。
- 行動：Sprint 1 の TODO として明記されている（README 該当箇所あり）が、**RLS 適用前に本番運用してはいけない**ことを明示するチェックリストが欲しい。

### 3.2 認証実装が未着手

- 設計：Supabase Auth + JWT 検証、`auth.uid()` を RLS から参照（`design/04` §認証フロー）
- 実装：
  - `Portfolio.Web.csproj` に `Microsoft.AspNetCore.Authentication.JwtBearer` の参照はあるが、`Program.cs` で `AddAuthentication()` / `UseAuthentication()` / `UseAuthorization()` が**未呼び出し**
  - `auth.users` はスタブテーブルのみ
- 影響：認証ガード無しで Blazor ページが叩ける状態。Home.razor は単一ユーザ前提のデモ。

### 3.3 LLM クライアントが未実装

- 設計：Gemini BYOK、`Shared.LLM` ラッパで Groq などへ切替容易（`design/02` / `design/11`）
- 実装：`Services/` に LLM クライアント無し（`EmbeddingClient.cs` / `IEmbeddingClient.cs` のみ）
- 影響：分類フロー第 ⑥ 段（LLM フォールバック）は未着手。MVP 必須項目。

### 3.4 ITicketDestination が未実装

- 設計：`design/06_destinations.md` で Adapter パターンを明示、Redmine + GitHub Issues の 2 実装
- 実装：`backend/` 配下に Destination 関連サービスは無し（DB エンティティ `Destination.cs` のみ存在）
- 影響：起票フロー全体（MVP の核機能）が未着手。

### 3.5 Embedding 利用方式の整合性

- 設計：`design/05` 5-1〜5-4 でハイブリッド検索擬似コードあり、`design/07` で Embedding はクライアント送信前に `query: ` プレフィクス
- 実装：
  - サーバ側 `embedder.py:39` で `f"query: {t}"` を**強制プレフィクス**している
  - これは「クエリ用途専用」設計だが、マスタ取込時の `passage: ` 用エンドポイントが存在しない
- 影響：`multilingual-e5` の入力規約（query / passage 区別）違反になる可能性。マスタの embedding を生成する際は passage プレフィクスが必要なはずだが、現状のサービスでは query 固定。`design/07` の「マスタアップロード後の処理フロー」で Embedding 推論を経由するが、ここで品質劣化する。

### 3.6 Caddy リバプロのパス分け

- 設計：`design/02` ではフロントが直接 Embedding を呼ばない（Blazor 経由）
- 実装：`infra/caddy/Caddyfile:6-8` で `/api/embed*` を直接 Embedding にバイパス
- 影響：ブラウザから直接 `/api/embed` を叩ける状態。CORS / 認証無し。`embed.js` ウィジェット用と思われるが、`tenant_public_keys` での認可機構と結びついていない。設計書 `design/04` §埋め込みウィジェット の RLS ポリシーが Embedding 推論レイヤには適用できない（Postgres 層の話のため）ので、Caddy 層もしくは FastAPI 層で別の認可が必要。

### 3.7 `tenant_public_keys` テーブルの位置づけ

- 設計：`design/03` 末尾「将来追加されるテーブル」に分類されつつも「MVP（埋め込みウィジェットと並行設計）」と書かれており曖昧
- 実装：すでに migration / エンティティに登録済み
- 影響：実装側が設計の曖昧さを「MVP に入れる」方向で確定させた形。設計書を実装に追従させる更新が必要。

### 3.8 EF Migrations と SQL Migration の二重管理

- 実装：`docker-compose.yml:14-16` で `0001_schema.sql` を Postgres 初回起動時に投入する仕組み
- 一方 `CLAUDE.md`（backend）と `0001_schema.sql:255-267` に「EF Core マイグレーションも別途追加する」コメントあり
- 影響：将来の運用で「どちらを正とするか」が決まっていない。設計 09 のタスク分担では EF Core が正とも読めるが、現状の SQL は手書き。Sprint 早期に方針確定すべき（特に Plan A/B 切替時に効く）。

---

## 4. リスク

### 重要度：高

1. **RLS 未適用のままアプリ層を進めるリスク**：実装が進んでから RLS 適用すると、各クエリが想定外の挙動（フィルタが効きすぎる／効かない）になる回帰を発生させる。EF Core の `OnSaveChanges` 経由で `tenant_id` が常にセットされている保証もまだ無い。
2. **認証スタックの「Plan A 用代替」が空白**：Plan A（Oracle Cloud）で Supabase Auth を捨てた場合、ASP.NET Core Identity か外部 IdP（GitHub OAuth など）を立てる必要があるが、設計書に具体方針なし。`design/02` のホスティング構成と `design/04` の認証構成がプラン別に分かれていない。
3. **`multilingual-e5` の query/passage プレフィクス問題**：マスタ側 embedding が `query: ` で生成されると、recall が体感で 5〜10pt 程度落ちる既知パターン。本気で検索品質を訴求する設計なので、**実装前に必ず分岐エンドポイントを追加**するべき。

### 重要度：中

4. **Plan A / Plan B の運用差を吸収する抽象化が薄い**：Supabase 依存（Auth / Vault）が `design` 全体に染み出しており、Plan A 採用時のフォールバック実装コストが見えづらい。例：Vault 相当は Plan A だとどう実現するのか？（dotnet user-secrets？KMS 相当？）
5. **`Portfolio.Web.Tests` ディレクトリの中身が見えない**（Dockerfile では参照あり）：Sprint 1 の RLS / 多テナントテストを誰がいつ書くかの計画が `design/09` レベルにしか無く、CI 統合の具体策が薄い。
6. **Blazor Server の同時接続スケール**：SignalR を握りっぱなしになるため、Azure F1（Plan B）の 60 分 CPU/日制約と相性が悪い。設計書 `design/11` でも触れられているが、**Plan B の本気運用は厳しい**点を訴求側で先に語る整理が要る。
7. **Embedding サービスの単一障害点**：FastAPI コンテナが落ちると全分類フローが止まる。`docker-compose.yml:42-43` で `depends_on: embedding.service_started` のみ（healthy では無い）。起動直後のモデルロード未完了で 502 が返る可能性。
8. **HF Spaces (Plan B) では 500MB モデルが OOM 多発の既知問題**（`design/11` で言及済み）。代替として量子化版モデル（multilingual-e5-base-quantized 等）の検証が必要。

### 重要度：低

9. **`InvariantGlobalization=true`** が `Portfolio.Web.csproj` に設定されている：日本語処理が前提の Service A において、文化依存ソート・大小文字変換・正規化で罠を踏みうる。実装時にユニットテストでフェイルファストすべき。
10. **`embed.js` 配信が未着手**：MVP 対象だが backend/wwwroot に該当ファイルなし。
11. **`example_queries` 配列の言い換え管理 UI が `design/08` で見えない**：データ構造はあるが「誰がどう編集するか」のフロー粒度が薄い。
12. **`updated_at` の更新トリガが migration に無い**：`knowledge_entries.updated_at` は DEFAULT now() のみで、UPDATE 時の自動反映なし。EF Core 側で `SaveChanges` フック追加が要る。

---

## 5. 改善提案

### 短期（Sprint 1〜2 で着手）

- **RLS を最優先で適用**：`knowledge_entries` を皮切りに、`auth.uid()` 代替（自前 JWT クレーム → `current_setting('app.user_id', true)`）を Postgres セッション変数で立てる方式を決め、EF Core の `DbContext.SaveChanges` でセットする。
- **認証スタックの Plan 別決定木**：`design/04` を「Plan A：自前 JWT（ASP.NET Core Identity or 外部 IdP）」「Plan B：Supabase Auth」の 2 ブランチに分岐して書く。Vault も同様。
- **Embedding API に `kind` フィールドを足す**：`/embed` リクエストに `kind: "query"|"passage"` を加え、`multilingual-e5` の入力規約に従う。マスタ取込・クエリで使い分け。
- **`Portfolio.Web.Tests` を実体化**：`WebApplicationFactory<Program>` ベースで `/healthz` を叩く最小テスト → Testcontainers で Postgres + RLS E2E まで段階拡張。
- **LLM クライアントの抽象実装**：`ILlmClient` + `GeminiClient` を切り、未実装でも `Program.cs` に DI 登録だけ済ませる（呼び出しは Phase 2 で OK だが、形だけ握る）。

### 中期（MVP リリースまで）

- **Adapter 雛形**：`ITicketDestination` を `Portfolio.Web/Services/Destinations/` 配下に切り、`RedmineDestination` / `GitHubIssuesDestination` のスケルトンを作る（中身は Phase 2 で OK）。
- **マルチテナント横断のテスト戦略**：xUnit `[Trait("Category","DB")]` ＋ Testcontainers ベースの統合テストで「テナント越境 SELECT/INSERT/UPDATE/DELETE が全部弾かれる」を担保。`design/04` で言及済みだが、テストケースを `design/09` ではなく `design/04` に列挙する方が見つけやすい。
- **Embedding サービスの起動時ヘルスチェックを healthy 連動に**：`docker-compose.yml:42-43` を `condition: service_healthy` に変更。Dockerfile の HEALTHCHECK の `start-period=60s` も実モデル DL を考慮し 120s 程度に伸ばすべき。
- **Caddy の `/api/embed` バイパスを廃止**：ブラウザ → Embedding 直結はセキュリティリスク。Blazor 側に薄いプロキシエンドポイントを置く。
- **`updated_at` トリガ追加**：Postgres トリガで自動更新するか、EF Core の `ChangeTracker` で更新する。

### 長期（Phase 2 以降）

- **Transformers.js への移行**：`design/07` 戦略2 が成立すれば FastAPI コンテナの一台分の RAM を空けられる。Plan B では決定的に効く。
- **Re-ranker の導入**：bge-reranker など。設計書記載済みだが、`embedding/app/` 内に分離サービスとして実装するか、Blazor 側で呼び出すかの方針を `design/05` に追記。
- **`Shared.LLM` ライブラリ化**：プロバイダ切替（Gemini / Groq / Claude）を見越して別アセンブリ化。`platform_proposal.md` の Service B（Ronkaku）でも共通利用が見込めるため、Phase 2 の段階で別 csproj に切り出す価値あり。
- **データガバナンス文書整備**：`design/07` の「データは外部システム」を前面に出す形で、利用規約・プライバシーポリシーのテンプレ化（`design/11` で「弁護士確認」フラグだけ立っている）。
- **observability**：Sentry 言及はあるが、ASP.NET Core 側の OpenTelemetry 構成、`ILogger<T>` の集約先、メトリクス（Prometheus → Grafana の自前運用 or Better Stack 無料枠）まで整理しておくと採用面接の説得力が増す。

---

## 6. 設計ドキュメントの整合性（design/ 配下12ファイル）

- **整合度は高い**：技術スタック・分類フロー・データ戦略の主要決定は `README.md` クイックリファレンスに集約され、本文側の重複や矛盾が少ない。
- **抜け漏れ**：
  - Plan A 採用時の「認証」「Vault」「auth.uid 相当」の具体実装方針。`04` は Supabase 前提で書かれており、Plan A 章への分岐がない。
  - `embedding/` 側の query/passage プレフィクス指定が `design/07` に明記されていない（CLAUDE.md だけに書かれている）。設計書本体に上げるべき。
  - テスト戦略（特に RLS E2E）が `09_task_split.md` 内の項目どまり。`04_security_multitenant.md` 末尾に独立節があるとレビュー観点で見やすい。
  - 監視・ログ・運用（SLO / アラート）章が不在。`README.md` レベルで Sentry / Dependabot に言及はあるが、`design/` 本体には章立てなし。`13_observability.md` を新設する価値あり。
- **platform_proposal.md との整合**：proposal で示された「`/Shared.*` モノレポ構成」は現状の単一 csproj に縮約されており、Service B（Ronkaku）と組み合わせる際の物理分割設計が未確定。proposal 末尾の補足（CI/CD共通化、監視、デモシナリオ）も `design/11_open_questions.md` でほぼ拾えているが、proposal で書いた「`/Shared.LLM`」を `design/` 側で「Phase 2 で別 csproj に出す」と明記すれば一貫性が増す。

---

## 7. 拡張性・スケーラビリティ・セキュリティ評価

| 観点 | 評価 | コメント |
|---|---|---|
| 拡張性（起票先） | ○ | Adapter パターン + `field_mapping` JSONB の柔軟性は十分。 |
| 拡張性（検索戦略） | ○ | `embedding_model` 列でモデル混在許容、`match_strategy` 列で計測可能。Re-ranker や HyDE を後から積みやすい。 |
| 拡張性（マスタソース） | ○ | `IKnowledgeSource` の抽象化が `design/07` で示されており、Git 同期は後で差し込める。 |
| スケーラビリティ（同時接続） | △ | Blazor Server の SignalR ハブ依存。Plan B で詰む可能性。WASM ハイブリッドを Phase 2 の選択肢に置くべき。 |
| スケーラビリティ（DB） | ○ | RLS + HNSW + GIN の組合せはマルチテナント SaaS の現代標準。500MB 上限は設計書通り 15-20 テナント。 |
| スケーラビリティ（Embedding） | △ | サーバ集中型のため、テナント数増加で CPU bottleneck になる。Phase 2 のブラウザ移行が現実解。 |
| セキュリティ（テナント分離） | △ | 設計は強いが**未実装**。実装が進むほど後付け RLS のコストが上がる。 |
| セキュリティ（秘匿情報） | △ | Vault 前提だが Plan A 時の代替不在。MVP 直前に詰まる。 |
| セキュリティ（外部公開API） | △ | `/api/embed` バイパスがあるが認可機構なし。 |
| セキュリティ（依存性） | ○ | Dependabot + CodeQL + ruff/mypy + dotnet TreatWarningsAsErrors。CLAUDE.md 規律も堅い。 |

---

## 8. 総合評価

**8.0 / 10**

**良い点（評価を押し上げた要因）**

- 設計フェーズが 12 章×10KB 規模で書き込まれ、「やらない判断」まで明文化されており、面接訴求物として極めて強い。
- `README` クイックリファレンス＋本文の二段構成、`却下した設計` の列挙、`未確定の運用判断` の独立章など、ドキュメント工学的にも完成度が高い。
- 技術選定の動機（既存スキル活用 + 採用市場ターゲット）が一貫しており、ブレない。
- 実装スケルトン（`Program.cs` / `AppDbContext.cs` / 全エンティティ / migration / Caddy / Docker Compose）が**設計に忠実**に揃っており、設計→実装の橋渡しに迷いがない。
- CI/CD・コード規約（CLAUDE.md）・型安全・nullable warning as error などのプロフェッショナルな下地。

**評価を下げた要因**

- セキュリティの核（RLS / 認証 / Vault）が**実装側でほぼ未着手**。設計と実装の乖離が一番大きい領域がセキュリティであるため、MVP 完成までに後付けコストが高い。
- Plan A / Plan B の分岐が `02_architecture` 以外には反映されていない（特に `04_security_multitenant`）。
- `multilingual-e5` の query/passage 規約違反となる Embedding 実装は MVP で必ず直すべき。
- 設計書に「監視・運用」章が独立で存在しない。

**総評**

設計はシニア寄りの説得力があり、`platform_proposal.md` の「シニア寄りの設計力訴求」という当初目的を十分に達成できる水準。実装も雛形としては clean で、テストの素地（FAKE_EMBEDDER、healthchecks、TreatWarningsAsErrors）が整っている。次の Sprint で **RLS と認証**を片付け、**Embedding の query/passage 分岐**を入れ、**Adapter / LLM の抽象スケルトン**を据えれば、面接デモまでの軌跡が一気通貫で語れる状態になる。

---

## 9. 参考：このレビューで参照した主要ファイル

- `/home/user/easy_chatbot_maker/platform_proposal.md`
- `/home/user/easy_chatbot_maker/design/01_overview.md` 〜 `12_interview_narratives.md`（全 12 ファイル + README.md）
- `/home/user/easy_chatbot_maker/docker-compose.yml`
- `/home/user/easy_chatbot_maker/infra/caddy/Caddyfile`
- `/home/user/easy_chatbot_maker/infra/db/init.sql`
- `/home/user/easy_chatbot_maker/infra/db/migrations/0001_schema.sql`
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Program.cs`
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Portfolio.Web.csproj`
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Data/AppDbContext.cs`
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Data/Entities/*.cs`（10 ファイル）
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Services/EmbeddingClient.cs`
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Services/IEmbeddingClient.cs`
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Components/{App,Routes,Pages/Home,Layout/MainLayout}.razor`
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/appsettings.json`
- `/home/user/easy_chatbot_maker/backend/CLAUDE.md`
- `/home/user/easy_chatbot_maker/backend/Dockerfile`
- `/home/user/easy_chatbot_maker/embedding/pyproject.toml`
- `/home/user/easy_chatbot_maker/embedding/app/{main,embedder,models}.py`
- `/home/user/easy_chatbot_maker/embedding/Dockerfile`
- `/home/user/easy_chatbot_maker/embedding/CLAUDE.md`
- `/home/user/easy_chatbot_maker/.env.example`
- `/home/user/easy_chatbot_maker/README.md`
