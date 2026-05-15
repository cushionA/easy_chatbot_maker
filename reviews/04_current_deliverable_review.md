# 04. 現状成果物レビュー（easy_chatbot_maker）

レビュー日: 2026-05-15
対象: `main` 時点のリポジトリ全体（設計書ではなく、実コード／設定ファイル）
レビュー観点: 「いま push されているファイル群が、設計書を読まずに `cp .env.example .env && docker compose up --build` して動く水準にあるか」

---

## 現状サマリ

**完成度: 3 / 10（「動く土台」スケルトン段階）**

- リポジトリ周辺の足場（CI、pre-commit、Dependabot、CodeQL、Makefile、Docker、Caddy、DBスキーマSQL、EFエンティティ、Pydanticモデル、テスト）はほぼプロ品質で揃っている。**スキャフォールド層の完成度だけなら 8 / 10**。
- 一方、**業務ロジック・画面・API は事実上ゼロ**。Blazor ページは `Home.razor` 1 枚で `Embedding.EmbedAsync` を叩いて次元数を表示するだけのデモであり、設計書 (`design/08_features.md` 等) で語られている「ナレッジ起票補助 RAG」「未分類キュー」「テナント管理」「BYOK」「ハイブリッド検索」「Redmine/GitHub 起票」のいずれも実装されていない。
- **README が「現状の機能」を語っていない**ため、現状のリポジトリだけ見せられた読者は「動くプロダクト」と誤解する可能性が高い。
- DB 接続文字列・Embedding URL が必須に固定されているため、ユニットテストは通るが、`appsettings.json` が DB を空のまま指していないので **`docker compose up` で起動はするが、最初の画面ロード後に Postgres を一切叩かないので "動いて見える" だけ**である点に注意。
- 良いニュースとして、ここから「機能を足すだけ」で進められる土台にはなっている。とはいえ「現時点の成果物」としてポートフォリオに提示するのは時期尚早。

### サマリ判定マトリクス

| 観点 | 評価 |
|---|---|
| ビルド可能性（dotnet build / pytest） | OK だが下記の Pgvector NuGet 問題でビルド失敗の可能性が高い |
| `docker compose up` で起動可能か | 部分的に OK（embedding は要モデル DL、backend は起動するが Home 1 枚） |
| データ層（EF Core エンティティ） | スキーマと突き合わせ済みで一致しており優秀 |
| ビジネスロジック | ほぼ未実装 |
| 画面 / UI | デモ画面のみ |
| 認証 | 未実装（Supabase ハンドラ未登録、JwtBearer は参照だけ） |
| マルチテナント分離 | 未実装（RLS は SQL 内コメントのみ） |
| テスト | 健全に書かれているがカバレッジは表面のみ |
| ドキュメント | 設計書は充実、README はやや過大広告ぎみ |
| セキュリティ | 重大な欠陥は未確認だが、HTTPS 強制まわりにバグあり（後述） |

---

## 動くもの / 動かないもの（ファイル単位）

### 動く（実機能を持つ実装）

- `/home/user/easy_chatbot_maker/embedding/app/main.py`
  FastAPI で `/healthz`, `/embed`, `/embed/batch` の 3 エンドポイントが実装済み。`FAKE_EMBEDDER=1` でも本番モデルでも動作する。
- `/home/user/easy_chatbot_maker/embedding/app/embedder.py`
  `lru_cache` + 遅延ロード + FAKE モード（決定的ハッシュ→正規化ベクトル）まで丁寧に実装されている。
- `/home/user/easy_chatbot_maker/embedding/app/models.py`
  Pydantic v2 でリクエスト境界の長さ制限 (`min_length`, `max_length`) を正しく付与。
- `/home/user/easy_chatbot_maker/embedding/tests/test_main.py`
  ヘルス・成功系・空文字 422・空白要素 400・バッチ成功の 5 ケース。**現状唯一の実質的に意味のあるテスト**。
- `/home/user/easy_chatbot_maker/infra/db/init.sql` + `/home/user/easy_chatbot_maker/infra/db/migrations/0001_schema.sql`
  全 10 テーブル / インデックス / トリガ / 拡張までフル実装。docker-compose のボリュームマウントで初回起動時に流れる。
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Data/AppDbContext.cs`
  10 エンティティをマッピング、`vector(768)` / `tsvector` 計算列 / 複合ユニーク / `snake_case` 変換まで実装。スキーマと矛盾なし。
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Services/EmbeddingClient.cs`
  Typed HttpClient で `/embed` を叩く実装は完成。
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Program.cs`
  `/healthz` を返し、Blazor InteractiveServer を立ち上げる最小ホスト。
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web.Tests/HealthTests.cs`
  `WebApplicationFactory<Program>` で `/healthz` のステータスコードのみ検証。
- `/home/user/easy_chatbot_maker/docker-compose.yml`
  postgres / embedding / backend / caddy（prod profile）の 4 サービス構成、healthcheck と depends_on もきちんと張られている。

### 動かない・「画面はあるが何もできない」

- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Components/Pages/Home.razor`
  Embedding サービスを叩いて `dim = 768, first3 = [...]` を表示するだけ。データベースには一切触れない。
- `/home/user/easy_chatbot_maker/backend/Portfolio.Web/Components/Layout/MainLayout.razor`
  `<header><h1>Portfolio - Service A</h1></header>` のみ。サイドバー、ナビ、ログイン状態表示などは無い。
- ナレッジ管理画面、起票フォーム、未分類キュー画面、テナント設定、API キー発行、Redmine/GitHub 連携設定、ダッシュボード … **すべて未存在**。
- 認証パイプライン: `Microsoft.AspNetCore.Authentication.JwtBearer` を NuGet 参照しているが `Program.cs` で `AddAuthentication` / `AddAuthorization` / `UseAuthentication` / `UseAuthorization` の呼び出しがゼロ。**JWT を入れた "ふり" のみ**。
- RLS: `0001_schema.sql:242-252` にコメントアウトとして残っているだけで、実体は無い。アプリ層でも `tenant_id` フィルタは入っていない（クエリ自体無い）。
- BYOK Gemini 連携: コード上に痕跡なし。

### ハリボテ（雛形のみ）の主要ファイル一覧

| パス | 内容 |
|---|---|
| `backend/Portfolio.Web/Components/Layout/MainLayout.razor` | h1 一行 |
| `backend/Portfolio.Web/Components/Pages/Home.razor` | デモ用 1 画面 |
| `backend/Portfolio.Web/Components/Routes.razor` | 標準テンプレほぼそのまま |
| `backend/Portfolio.Web/Components/_Imports.razor` | using のみ |
| `backend/Portfolio.Web/Components/App.razor` | HTML ホスト |
| `backend/Portfolio.Web.Tests/HealthTests.cs` | 1 テストのみ |
| `embedding/app/__init__.py`, `embedding/tests/__init__.py` | 空ファイル |

---

## 重要なバグ・問題点

### 1. `Pgvector` NuGet パッケージ単体では `UseVector()` 拡張メソッドは無い（ビルド失敗の可能性）

`/home/user/easy_chatbot_maker/backend/Portfolio.Web/Program.cs:15-16`
```csharp
var dataSourceBuilder = new NpgsqlDataSourceBuilder(connectionString);
dataSourceBuilder.UseVector();
```

`/home/user/easy_chatbot_maker/backend/Portfolio.Web/Portfolio.Web.csproj:16`
```xml
<PackageReference Include="Pgvector" Version="0.2.0" />
```

`NpgsqlDataSourceBuilder.UseVector()` は **`Pgvector.Npgsql`** パッケージで提供される拡張メソッドであり、`Pgvector`（型のみ）には含まれない。さらに EF Core で `vector(768)` 列を扱うには `o.UseNpgsql(dataSource, x => x.UseVector())` で **EF 側の `UseVector` も呼ぶ必要**があり、これも `Pgvector.EntityFrameworkCore.PostgreSQL` パッケージで提供される。

**結果: 現状 `dotnet build` が CS1061（拡張メソッド未解決）でこける可能性が高い。** CI が通っているとすれば、`Pgvector` 0.2.0 のメタパッケージが両方を引き込んでいる可能性もあるが、いずれにせよ依存を明示しないと将来確実に折れる。

修正案:
```xml
<PackageReference Include="Pgvector" Version="0.2.0" />
<PackageReference Include="Pgvector.Npgsql" Version="0.2.0" />
<PackageReference Include="Pgvector.EntityFrameworkCore.PostgreSQL" Version="0.2.0" />
```
そして
```csharp
builder.Services.AddDbContext<AppDbContext>(opt =>
    opt.UseNpgsql(dataSource, x => x.UseVector()));
```

### 2. `UseHttpsRedirection()` が Docker 構成では誤動作

`/home/user/easy_chatbot_maker/backend/Portfolio.Web/Program.cs:41`
```csharp
app.UseHttpsRedirection();
```

docker-compose では backend は `http://+:8080` でしか listen していない（`ASPNETCORE_URLS: http://+:8080`、HTTPS 証明書も注入していない）。`UseHttpsRedirection` が有効だと**全リクエストが HTTPS にリダイレクトされ、Caddy 経由でない直接アクセス（`localhost:8080`）でブラウザがエラーになる**ことがある。Caddy がフロントに居る Plan A 構成では、backend 側は HTTP のままで良い。

修正案: `app.Environment.IsDevelopment()` でガード、または `UseHttpsRedirection` を呼ばず Caddy 側で完結させる。

### 3. `appsettings.json` を git ignore している（重大）

`/home/user/easy_chatbot_maker/.gitignore:5-7`
```
appsettings.*.json
!appsettings.json
!appsettings.Development.json
```

書き方は一見正しく見えるが、`appsettings.*.json` パターンは `appsettings.json` には**マッチしない**（`*` は 1 文字以上）。`appsettings.Production.json` などは無視されるが `appsettings.json` 自体は無視されない。意図通り動いているが、コメントとしては誤解を招く構造。実害は無いが将来「`appsettings.Local.json` を一時的にコミットしたい」となった時に混乱を生む。低優先。

### 4. テストカバレッジが実質ゼロ

`/home/user/easy_chatbot_maker/backend/Portfolio.Web.Tests/HealthTests.cs` は `/healthz` の 200 だけを見ている。`AppDbContext` の `OnModelCreating` ロジック（`ToSnakeCase`, 計算列定義、複合 UNIQUE）も一切テストされていない。Embedding 側の `embedder.py` も FAKE モードしかカバーされていないため、`SentenceTransformer` のローダー周りは未検証。

`/home/user/easy_chatbot_maker/embedding/tests/test_main.py:8` ～
```python
def test_healthz_ok():
    resp = client.get("/healthz")
    ...
```
書き方は健全（status → body shape → values の順）。CLAUDE.md の方針通り。

### 5. `EmbeddingClient` のリクエスト DTO 命名が PEP 8 / C# のスタイル違反

`/home/user/easy_chatbot_maker/backend/Portfolio.Web/Services/EmbeddingClient.cs:7-8`
```csharp
private sealed record EmbedRequest(string text);
private sealed record EmbedResponse(float[] embedding);
```

C# の record コンストラクタ引数はパブリックプロパティになるため、ここは PascalCase（`Text`, `Embedding`）であるべき。`[JsonPropertyName("text")]` を付ければ Pydantic 側の snake_case と互換が取れる。現状 System.Text.Json はデフォルトで PascalCase シリアライズを行うため、**現在の `Embed_request → {"text": ...}` が動いているのは "小文字プロパティのまま" だから**であり、`TreatWarningsAsErrors=true` 環境では analyzer（CA1707 等）に怒られて build に失敗する可能性がある。`Portfolio.Web.Tests.csproj` は `NoWarn>CA1707` を入れているが、本体側は入れていない点も含めて要レビュー。

### 6. embedding サービスの prefix が常に `query:` で固定

`/home/user/easy_chatbot_maker/embedding/app/embedder.py:39`
```python
prefixed = [f"query: {t}" for t in texts]
```

CLAUDE.md の方針には「query/passage を使い分ける」とあるが、現状 `/embed` も `/embed/batch` も常に `query:` 接頭辞を付けるため、**ナレッジ文書側を投入する用途で使うとリコールが下がる**。エンドポイント分割 or `mode: query|passage` パラメータ追加が必要。

### 7. `EmbeddingClient` のタイムアウトが固定 15 秒、リトライなし

`/home/user/easy_chatbot_maker/backend/Portfolio.Web/Program.cs:25-29`
```csharp
builder.Services.AddHttpClient<IEmbeddingClient, EmbeddingClient>(c =>
{
    c.BaseAddress = new Uri(embeddingBaseUrl);
    c.Timeout = TimeSpan.FromSeconds(15);
});
```

初回起動時にモデルロード（HF から数百 MB DL）がかかると 15 秒では足りない。`HEALTHCHECK --start-period=60s` と整合させると 60 秒以上欲しい。Polly でのリトライも未導入。

### 8. データベース所有者の権限と RLS の不整合（将来）

スキーマは `portfolio` ユーザーで作られる。`portfolio` は `BYPASSRLS` を持つ通常スーパー的ロールなので、後から `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` を入れても、アプリが `portfolio` で接続している限り**ポリシーが効かない**。今は被害ゼロだが、Sprint 1 で RLS を入れる際に「効かない」とハマる定番ポイント。

### 9. embedding サービスが「初回モデル DL」で固まる可能性

Dockerfile では `HF_HOME=/models` ボリュームマウントしているが、**初回 `docker compose up` ではモデル未取得**で `/healthz` を叩いた瞬間に重い DL が走る。テスト用に `FAKE_EMBEDDER=1` を `docker-compose.yml` でもデフォルト ON にしておく方が体験は良い。

### 10. `Inquiry.Status` / `UnclassifiedQueueEntry.Status` に列挙制約が DB のみ

DB 側は `CHECK (status IN ('pending', 'added_to_master', 'discarded'))` 等で守っているが、C# 側は `public string Status { get; set; } = "";` の生文字列。型安全性をリスクとして取りに行っている形。`enum` + `HasConversion<string>()` を検討。

### 11. `Destination.Config` の `JsonDocument` を直接プロパティに持つのは罠

`/home/user/easy_chatbot_maker/backend/Portfolio.Web/Data/Entities/Destination.cs:11`
```csharp
public JsonDocument Config { get; set; } = JsonDocument.Parse("{}");
```

`JsonDocument` は `IDisposable`、かつ初期値が静的 `Parse` のためインスタンスごとに新規確保される。EF が tracking 中にライフサイクルを管理してくれない型なので、メモリリーク・`ObjectDisposedException` の原因になりやすい。`string` で保持して使うときにパース、もしくは `record` 型に直接マップするのが定石。

### 12. README と実態の乖離（過大広告）

`/home/user/easy_chatbot_maker/README.md:62-65`
```
| Blazor (Web) | http://localhost:8080 |
| FastAPI (Embedding) | http://localhost:9000/healthz |
| Swagger UI | http://localhost:9000/docs |
```

これ自体は事実だが、`README.md` 全体の語り口が「ナレッジ起票補助 RAG チャットボット**を実装する**」と現在形で書かれており、**現時点ではほぼスケルトンしか無い** ことが読者に伝わらない。`## Status` セクションで「Sprint 0 完了。Sprint 1 で RLS と CRUD 実装予定」等を明示すべき。

### 13. `Caddyfile` のリバプロパスがおそらく誤り

`/home/user/easy_chatbot_maker/infra/caddy/Caddyfile:6-8`
```
handle_path /api/embed* {
    reverse_proxy embedding:9000
}
```

`handle_path` は path prefix を**剥がす**ので、外部 `/api/embed` → 内部 `/`、外部 `/api/embed/batch` → 内部 `/batch` に飛ぶ。FastAPI 側は `/embed`, `/embed/batch` で待っているので **404 になる**。`handle /api/embed*` か、`reverse_proxy embedding:9000` の前に `rewrite * /embed{path}` を入れる必要がある。embedding サービスを外部公開する意図が無いなら、そもそもこのブロックを消すのが手早い（backend からは内部ネットワークで直接 9000 を叩いている）。

---

## すぐ直すべきこと（クイックウィン）

優先度高い順に。半日〜1 日で消化できる範囲のもの。

1. **NuGet 依存を確定する** — `Pgvector.Npgsql` と `Pgvector.EntityFrameworkCore.PostgreSQL` を追加し、`Program.cs` の `UseNpgsql(dataSource)` を `UseNpgsql(dataSource, x => x.UseVector())` に変更（問題 1）。
2. **`UseHttpsRedirection` を `IsDevelopment` 限定にする**、または削除（問題 2）。
3. **`record` プロパティを PascalCase + `[JsonPropertyName]` に**（問題 5、`TreatWarningsAsErrors=true` 環境のビルド維持）。
4. **`EmbeddingClient` のタイムアウトを 60 秒以上に**、`HF_HOME` ボリュームの事前ウォームアップ手順を README に追記（問題 7, 9）。
5. **Caddyfile の `/api/embed*` を消す or 直す**（問題 13）。
6. **`README.md` に "現在の到達点" セクションを追加**し、「現状動くのは Embedding サービスと Blazor のデモ画面 1 枚」と明記（問題 12）。
7. **`HealthTests.cs` に Embedding が落ちている時の挙動も 1 ケース追加**（簡単なフィクスチャ差し替え）。
8. **`appsettings.Development.json` に DB が無くてもアプリが立ち上がる "DesignTime" モードを追加**（接続文字列が `""` のときは EF を登録しない）。
9. **embedding サービスに `mode` パラメータ追加**（query/passage 切り替え、問題 6）。
10. **CLAUDE.md / pyproject.toml の `mypy strict` が `embedder.py:40` の `# type: ignore[union-attr]` で逃げている** のを `assert self._model is not None` に変えて静的解析を強化。

---

## 中期的に手を入れるべきこと

「Sprint 1 で着手する単位」感のもの。

1. **認証パイプラインの組み立て**
   `AddAuthentication().AddJwtBearer(...)` を `Program.cs` に追加し、Supabase JWKS or HS256 シークレットを設定経由で読む。`UseAuthentication`/`UseAuthorization` を Razor のセクションより前に挟む。
2. **テナントコンテキストの確立**
   `IHttpContextAccessor` から JWT クレームを取って `current_tenant_id` を `SET LOCAL app.tenant_id = ...` で Postgres セッションに流す `DbContext` のインターセプタを書く。これが RLS 有効化の前提。
3. **RLS の実装**
   `0001_schema.sql` のコメントを実体化、`portfolio` ロールから `BYPASSRLS` を剥がして専用アプリロール `portfolio_app` を作る（問題 8）。
4. **ナレッジ CRUD 画面**
   `/knowledge`, `/knowledge/{id}/edit` 等 4 〜 5 ページ。`EditForm` + データアノテーション。
5. **未分類キュー → ナレッジ昇格フロー**
   設計書 `design/05_search_classification.md` で語られている UX を実装。
6. **ハイブリッド検索（pgvector + BM25 + reranker）**
   現状 EF だけで pgvector を叩く実装は無い。`AppDbContext` に `FromSql` + `EF.Functions.ToTsVector` ベースのクエリを足す。
7. **Redmine / GitHub Issues 連携**
   `IDestinationClient` 抽象 + 2 実装。BYOK の Vault からのキー取り出しは pgsodium で。
8. **Gemini 呼び出し**
   現状コードゼロ。BYOK 設計の通り、テナント毎キーを Vault から取り出して呼ぶ抽象を `IChatCompletionClient` で定義。
9. **観測性**
   `Serilog` or `Microsoft.Extensions.Logging` の構造化ログ、OpenTelemetry + OTLP エクスポータの追加。
10. **テスト基盤の格上げ**
    `Testcontainers.PostgreSql` を導入し、`AppDbContext` の `OnModelCreating` + 主要クエリを実 DB で検証。`Trait("Category","DB")` で fast/slow を分割。
11. **dim 768 の DB スキーマと、将来のモデル切替の整合**
    `intfloat/multilingual-e5-base` は 768 だが、将来 `large`（1024）に変えると DB マイグレーションが必要。`embedding_model` カラムは既にあるので、複数次元同居（partial index で `WHERE embedding_model = 'base'` 等）の運用ポリシーを決める。
12. **CI に docker-compose 起動 → smoke E2E**
    `up -d && curl /healthz && curl POST /embed` までを GitHub Actions に組み込む。`docker-build` job は build 止まりなので、起動確認まで進める。

---

## 総評

「外見だけ整った完成品」ではなく、「外側のレールが完璧に敷かれて、本体の組み立てがこれから始まる Sprint 0 終了時点」のリポジトリ。**ポートフォリオとして「コードの綺麗さ」「設計力」をアピールする用途には十分価値があるが、「動く SaaS」として見せる段階には到達していない**。次の 1 〜 2 スプリントで RLS と CRUD 画面を入れれば、見せ筋として急激に化ける土台ではある。
