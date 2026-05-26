# Sprint 2 Day 1 作業指示書（2026-05-22）

> テーマ: **検索基盤の足場を立てる**
> 完了時の状態: `Portfolio.Search` ライブラリができ、`ICandidateSearch` / `ClassifyCandidate` の型が確定し、`ExactMatch`（キーワード完全一致）の最初の 1 個が動く。Embedding 呼び出しの `query:`/`passage:` 使い分けが整理されている
> 推定所要: 5〜7 時間

---

## Day1-1. 残 CRUD（Knowledge / FieldDefinition）テンプレ展開 [AI]

**目的**
Sprint 1 で作った Category CRUD のパターン（`EditForm` + `DataAnnotationsValidator`）を Knowledge / FieldDefinition に複製し、検索対象データを画面から投入できる状態にする。今日以降の検索タスクで「手で INSERT する」手間を消すリハビリ。検索ロジックそのものではないので AI に委譲する。

**前提確認**
- [ ] Sprint 1 完了（`Components/Pages/Categories/Index.razor` `Create.razor` `Edit.razor` が動く）
- [ ] `KnowledgeEntry` / `FieldDefinition` エンティティの列を `Data/Entities/` で確認した
- [ ] RLS が効いているので、画面からの INSERT も `tenant_id` 自動分離される前提（Sprint 1 Day2-4 の `TenantConnectionInterceptor`）を理解した

**手順**
1. AI に下記テンプレで依頼し、`Components/Pages/Knowledge/` と `Components/Pages/FieldDefinitions/` に 3 ページずつ生成させる
2. `KnowledgeEntry` の配列列（`Keywords` / `ExampleQueries` / `RequiredFieldCodes` は `string[]`）はカンマ区切りの 1 行入力 → `Split(',')` で配列化する単純実装で良い（凝った multi-row UI は Sprint 4）
3. `Embedding` 列は **この画面では埋めない**（Day1-5 と Day2 で扱う）。`EmbeddingModel` も null のままで良い
4. 生成後、自テナントで 2〜3 件 Knowledge を登録（後続タスクの検索データになる。`Name` / `Keywords` / `ExampleQueries` を意味のある日本語で）

**完了確認**
- [ ] `/t/{slug}/knowledge` で一覧 → 作成 → 編集が回る
- [ ] 別テナントの Knowledge が見えない（RLS 目視確認）
- [ ] `dotnet build Portfolio.sln --configuration Release` が warning 0（`TreatWarningsAsErrors`）
- [ ] 検索検証用に 3 件以上の Knowledge が自テナントに入っている

**詰まったら**
- 配列列のバインドでビルドエラー → `string[]` を直接 `EditForm` にバインドせず、中間の `string` プロパティ（カンマ区切り）を介す
- 一覧に他テナント分が出る → RLS ではなく `AsNoTracking()` のクエリに `tenant_id` フィルタを足したくなるが不要。出るなら `SET LOCAL` が効いていない（Sprint 1 Day2-4 を疑う）

**AI 依頼テンプレ**
```
Sprint 1 で作った backend/Portfolio.Web/Components/Pages/Categories/ の Index.razor /
Create.razor / Edit.razor と同じパターンで、KnowledgeEntry と FieldDefinition の
CRUD 3 ページずつを Components/Pages/Knowledge/ と Components/Pages/FieldDefinitions/ に作って。

制約:
- ルートは /t/{Slug}/knowledge と /t/{Slug}/field-definitions、[Authorize] を付ける
- @rendermode InteractiveServer を明示、@inject AppDbContext Db
- KnowledgeEntry の string[] 列（Keywords, ExampleQueries, RequiredFieldCodes）は
  カンマ区切りの単一テキスト入力にし、保存時に Split(',') で配列化、表示時に string.Join(", ")
- Embedding と EmbeddingModel 列は触らない（null のまま）
- 楽観ロックは Category の Edit と同じ扱いに揃える
- AsNoTracking() を読み取りクエリに付ける、SQL は LINQ のみ（生 SQL 不要）
変更は Components/Pages/ 配下に閉じること。AppDbContext やエンティティは変更しない。
```

---

## Day1-2. `search_text`（tsvector）と検索用インデックスの動作確認 [自分]

**目的**
ハイブリッド検索の BM25 側は `knowledge_entries.search_text`（生成列）に全面的に依存する。この列が **Knowledge 登録時に自動で埋まり、日本語クエリにマッチするか**を Day2 の前に自分の手で確かめる。ここを確認せずに進むと Day2-1 の BM25 SQL がなぜ 0 件なのか切り分け不能になる。面接では「BM25 のための tsvector を生成列で持ち、`simple` 構成を選んだ理由」を語れる。

**自分で書く理由**
検索のヒット/ミスの根本原因がこの列にある。AI に「動作確認して」と投げると確認の意味が消える。生成列の定義（`AppDbContext.cs` の `HasComputedColumnSql` = `make_search_tsvector(...)`）と `simple` テキスト検索構成の挙動を自分で握る。

**前提確認**
- [ ] Day1-1 で Knowledge が数件入っている
- [ ] `backend/Portfolio.Web/Data/AppDbContext.cs` の生成列定義を読んだ（`make_search_tsvector(name, keywords, example_queries)`）。これは `infra/db/migrations/0001_schema.sql` の **IMMUTABLE ラッパー関数**で、Supabase では `to_tsvector('simple', ...)` が STABLE 扱いされ生成列に直接使えないため、ラッパー経由にしている
- [ ] [`05_search_classification.md:39-57`](../05_search_classification.md) を読んだ

**手順**
1. owner 接続（`SUPABASE_DB_URL_OWNER`）で `search_text` が埋まっているか確認:
   ```sql
   SELECT name, search_text FROM knowledge_entries LIMIT 5;
   ```
   - 空なら生成列が migration で適用されていない。`dotnet ef migrations list` と DB の `\d knowledge_entries` を突き合わせる
2. 実際の検索演算子を手で試す（Day2-1 で使う SQL の核）:
   ```sql
   SELECT name, ts_rank(search_text, websearch_to_tsquery('simple', 'パスワード 再発行')) AS score
     FROM knowledge_entries
    WHERE search_text @@ websearch_to_tsquery('simple', 'パスワード 再発行')
    ORDER BY score DESC;
   ```
3. GIN インデックスの有無を確認（無ければ後で遅くなる。MVP では件数小なので必須ではないが把握しておく）:
   ```sql
   SELECT indexname, indexdef FROM pg_indexes
    WHERE tablename='knowledge_entries' AND indexdef ILIKE '%search_text%';
   ```
4. `simple` 構成は日本語を分かち書きしない（空白区切り依存）ことを体感する。`Keywords` / `ExampleQueries` に検索語が空白区切りで入っているほどヒットする、という設計上の含意をメモに残す

**完了確認**
- [ ] `search_text` が NULL でない行が複数ある
- [ ] 手で書いた `ts_rank` クエリが、登録した Knowledge をスコア降順で返す
- [ ] `simple` 構成では日本語の分かち書きをしないこと、ゆえに `keywords` 列の充実が効くことをメモした
- [ ] GIN インデックスの有無を確認した（無い場合は「MVP は許容、Phase 2 で追加」とメモ）

**詰まったら**
- `search_text` が全行 NULL → 生成列の migration 未適用。`AppDbContext.cs` の定義を変えず、`dotnet ef migrations add` で生成列の migration が出ているか確認
- `websearch_to_tsquery` が無い → Postgres 11+ なら存在。Supabase は OK。古いローカルなら `plainto_tsquery` で代替可
- 日本語が全くヒットしない → `simple` は形態素解析しない。1 語の完全一致や空白区切りでまず確認する

**AI 依頼テンプレ**: なし（自分で確認する範囲）

---

## Day1-3. `Portfolio.Search` クラスライブラリと型の骨子定義 [自分]

**目的**
分類ロジックを Blazor の `Portfolio.Web` から切り離した `Portfolio.Search` クラスライブラリに置く。今日この境界（インターフェースと戻り値の型）を確定させると、Day2 の検索 SQL も Day3 の LLM も「この型を返す/受ける」だけで AI に委譲できる。面接で「分類エンジンをサービス層として独立させ、UI と DB の都合から切り離した」と語れる中核。

**自分で書く理由**
ここが Sprint 2 全体の **インターフェース定義**。`09_task_split.md:123` の「ステップ3＝自分が握る最重要部分」に当たる。型を AI に決めさせると、後続タスクが全部その型に引きずられ、自分が説明できないコードになる。

**前提確認**
- [ ] [`05_search_classification.md:188-219`](../05_search_classification.md)（擬似コード全文）を読んだ
- [ ] 設計書の擬似コードは戻り値が `List<KnowledgeEntry>` だが、**スコアと match_strategy を呼び出し側に返したい**ので候補は専用 record にする、という判断を理解した
- [ ] 実リポジトリの命名は `Portfolio.*`（設計書 05 章の擬似コードは neutral だが、`Chatbot.*` 等が出てきても従わず `Portfolio.*` に揃える）

**手順**
1. ライブラリを作成し、ソリューションと Web プロジェクトに参照を通す:
   ```bash
   cd backend
   dotnet new classlib -n Portfolio.Search -o Portfolio.Search -f net8.0
   dotnet sln Portfolio.sln add Portfolio.Search/Portfolio.Search.csproj
   dotnet add Portfolio.Web/Portfolio.Web.csproj reference Portfolio.Search/Portfolio.Search.csproj
   ```
2. 戻り値の型を自分で定義する（`Portfolio.Search/ClassifyCandidate.cs`）。骨格だけ示す。中身（列・引数）は自分で埋める:
   ```csharp
   namespace Portfolio.Search;

   // match_strategy（design 05 章の確定値）。確定後にどの段で当たったかを呼び出し側に返す。
   // ここを自分で定義: design 05 章のどの段で当たったかを表す列挙（keyword / hybrid / llm / 該当なし）
   public enum MatchStrategy { /* ... */ }

   // 1 件の候補。スコアと match_strategy を呼び出し側に返したい（だから設計擬似コードの List<KnowledgeEntry> ではなく専用 record）。
   // ここを自分で定義: 候補を一意に識別する id、表示名、スコア、当たった段（MatchStrategy）を持つ immutable な record
   public sealed record ClassifyCandidate(/* ... */);

   // 分類全体の結果。候補リスト + 最終的にどの段で確定/打ち切ったか + top1 が confident 閾値以上か。
   // ここを自分で定義: 候補リスト、最終 Strategy、IsConfident（bool）を持つ record
   public sealed record ClassifyResult(/* ... */);
   ```
   - 設計書の擬似コードは戻り値が `List<KnowledgeEntry>` だが、**スコアと match_strategy を呼び出し側に返したい**ので専用 record にする、という判断は前提確認で握ったとおり
3. 検索段ごとのインターフェースを定義する（`Portfolio.Search/ICandidateSearch.cs`）。**実装は Day1-4 / Day2 で埋める**。シグネチャの設計（引数に何を載せるか）が後続全段を縛るので自分で決める:
   ```csharp
   namespace Portfolio.Search;

   // 1 段 = 1 つの検索ストラテジ。query は生の自然文（プレフィクス未付与）。
   public interface ICandidateSearch
   {
       // ここを自分で定義: 1 メソッド SearchAsync。
       //   - 入力: 生クエリ / tenantId / categoryId?（不明時 null で全件）/ 取得件数 limit / CancellationToken
       //   - 出力: Task<IReadOnlyList<ClassifyCandidate>>
       //   - tenant_id は RLS 任せ（SQL に書かない）前提だが、引数では受ける（監査・将来用）
   }
   ```
4. `Portfolio.Search` は **EF Core エンティティに依存させない**方針を決める（DB アクセスは Web 側の実装クラスが担い、Search は式とインターフェースに集中）。この境界をコメントに 1 行残す
5. ビルドを通す（実装は空でも interface とレコードだけで通る）

**完了確認**
- [ ] `dotnet build Portfolio.sln --configuration Release` が green（warning 0）
- [ ] `Portfolio.Web` から `Portfolio.Search` の型が参照できる
- [ ] `ClassifyCandidate` / `ClassifyResult` / `MatchStrategy` / `ICandidateSearch` の 4 つが定義された
- [ ] 「Search はエンジン、DB アクセスは Web 側」という境界をコメントで明示した

**詰まったら**
- 参照が循環する → `Portfolio.Search` から `Portfolio.Web` を参照してはいけない。依存は Web → Search の一方向
- `Vector` 型を Search に持ち込みたくなる → 持ち込まない。Embedding 検索の SQL は Web 側、Search は順位だけ受け取る設計に倒す（Day2-3 で効いてくる）

**AI 依頼テンプレ**: なし（自分で書くインターフェース定義）

---

## Day1-4. `ExactMatch`（キーワード完全一致）の最初の 1 個 [自分]

**目的**
分類フロー④（[`05_search_classification.md:39-43`](../05_search_classification.md)）を実装する。問題名 exact match で即確定する「高信頼ショートカット」。検索段の最初の 1 個を自分の手で書くことで、Day2 の BM25 / Embedding 段が同じ `ICandidateSearch` 形に複製できる型を確定させる。

**自分で書く理由**
「最初の 1 個」（SKILL.md の委譲ルール）。`ICandidateSearch` を最初に実装することで、戻り値の作り方・パラメータ化・RLS 依存の前提（`tenant_id` は SQL に書かず RLS 任せ）を自分で握る。残り 2 段は AI が複製可能になる。

**前提確認**
- [ ] Day1-3 完了（型がある）
- [ ] [`05_search_classification.md:39-43`](../05_search_classification.md)（④の判定基準）を読んだ
- [ ] 「問題名 exact match は即確定、部分一致は信頼せずハイブリッドに流す」という設計判断を理解した

**手順**
1. `Portfolio.Web/Services/ExactMatchSearch.cs` を作る（DB アクセスを伴うので Web 側に置く。`ICandidateSearch` を実装）
2. 骨子だけ示す。`Name` の完全一致 + キーワード配列の完全一致を `tsvector` ではなく素直な等価/配列包含で引く（④は「完全一致」なので `ts_rank` ではない）。クエリ本体は自分で書く:
   ```csharp
   public sealed class ExactMatchSearch(AppDbContext db) : ICandidateSearch
   {
       public async Task<IReadOnlyList<ClassifyCandidate>> SearchAsync(
           string query, Guid tenantId, Guid? categoryId, int limit, CancellationToken ct = default)
       {
           // tenant_id は RLS が SET LOCAL で強制するので WHERE に書かない（design 04）。
           // ここを自分で実装:
           //   1) db.KnowledgeEntries を AsNoTracking() で読み取り専用に
           //   2) Name の完全一致 OR Keywords 配列に query を含む（Npgsql が = ANY(keywords) に翻訳）で絞る
           //      ※ 部分一致や ts_rank は使わない（④は完全一致のみ。部分一致は Day2 のハイブリッド）
           //   3) categoryId が来たら CategoryId == categoryId でさらに絞る（null なら絞らない）
           //   4) Take(limit) して ClassifyCandidate に射影（Score は exact なので最高信頼の固定値、Strategy=Keyword）
           //   5) ToListAsync(ct)
           throw new NotImplementedException();
       }
   }
   ```
   - `Score` は exact なので最高信頼の固定値にする（値は自分で決める）。`Keywords.Contains(query)` は Npgsql が `= ANY(keywords)` に翻訳する点だけ押さえておく
3. **問題名の完全一致のみ即確定**にしたいので、`Name == query` ヒットは `IsConfident` 相当として扱える設計にする（確定判定は Day3-3 の `ClassifyService` 側で `Strategy==Keyword && top1` を見る、と決めておく。ここでは候補を返すだけ）
4. DI 登録（`Program.cs`）に `ExactMatchSearch` を追加（型付きで `AddScoped`）

**完了確認**
- [ ] 登録済み Knowledge の `Name` を丸ごとクエリに渡すと、その 1 件が `Score=1.0` で返る
- [ ] `Keywords` に含まれる語を渡すとヒットする
- [ ] 無関係な語では 0 件
- [ ] `categoryId` を渡すとそのカテゴリ内に絞られる
- [ ] EF が生成した SQL に `tenant_id` フィルタが無くても、RLS で他テナント分が漏れない（手で別テナントの Name を渡して 0 件を確認）

**詰まったら**
- `Keywords.Contains` でビルドエラー → Npgsql の配列マッピングが効く環境か確認。ダメなら `EF.Functions` の配列演算子に切替
- 部分一致もヒットさせたくなる → ④は完全一致のみ。部分一致は Day2 のハイブリッドの仕事。ここで欲張らない
- 別テナントの Name でヒットしてしまう → RLS が効いていない。Sprint 1 Day2-4 の interceptor を疑う

**AI 依頼テンプレ**: なし（最初の 1 個は自分で書く）

---

## Day1-5. Embedding 呼び出しの `query:`/`passage:` プレフィクス整理 [自分]

**目的**
`multilingual-e5-base` は **query には `query:`、文書には `passage:`** を付けないと recall が静かに劣化する（CLAUDE.md 横断ルール / [`embedding/CLAUDE.md`](../../embedding/CLAUDE.md)）。分類クエリは `query:` 側。現状 `EmbeddingClient.cs:17` は `mode` が `"query"` 固定で、文書側（`passage`）を呼べない。分類で正しく `query` を、Knowledge 登録/再 embedding で `passage` を使い分けられるよう、クライアント API を自分で整理する。面接で「e5 のプレフィクス規約と、間違えると recall が落ちる理由」を語れる。

**自分で書く理由**
検索品質に直結する規約で、かつ「気づきにくいバグ」の温床。`mode` をどう渡すかのインターフェース判断は自分が握り、内部実装の量産は AI に出せる状態にしておく。

**前提確認**
- [ ] `backend/Portfolio.Web/Services/IEmbeddingClient.cs` と `EmbeddingClient.cs` を読んだ（現状 `EmbedAsync(text)` が `mode="query"` 固定）
- [ ] `embedding/app/main.py` の `/embed` が `mode` を受け、サーバ側でプレフィクスを付ける設計を確認した
- [ ] [`embedding/CLAUDE.md`](../../embedding/CLAUDE.md) の「prefix `query: ` for queries, `passage: ` for documents」を読んだ

**手順**
1. プレフィクスの「正」がサーバ側（`embedding/app/`）にあることを確認する。**Web からは生テキスト + `mode` を送り、`query:`/`passage:` 文字列をクライアントで手付けしない**（二重付与防止）。この方針を 1 行コメントで残す
2. `IEmbeddingClient` に mode を表す enum を導入して使い分けを型で強制する（`EmbeddingClient.cs:17` の `"query"` 即値リテラルを消す）。骨格だけ示す:
   ```csharp
   namespace Portfolio.Web.Services;

   // ここを自分で定義: query / passage を表す 2 値の列挙（e5 のプレフィクス規約に対応）
   public enum EmbedMode { /* ... */ }

   public interface IEmbeddingClient
   {
       // ここを自分で定義: EmbedAsync(string text, EmbedMode mode, CancellationToken ct) のシグネチャ。
       //   - 戻り値はベクトル（float[]）
       //   - mode は既定 Query にして既存呼び出し元の移行を楽にするか、必須にして付け忘れを防ぐかを自分で判断
   }
   ```
3. `EmbeddingClient` 側で enum → `/embed` の `mode` 文字列（`"query"` / `"passage"`）に変換する。**変換（マッピング）は 1 箇所に閉じる**こと。即値 `"query"` がコードから消える状態を自分で作る
4. 既存呼び出し元（Sprint 1 のデバッグ画面 / Seed ツールがあれば）を新シグネチャに直す。**分類クエリは必ず `EmbedMode.Query`、Knowledge の embedding 生成は `EmbedMode.Passage`** という対応を決める
5. サーバ側がプレフィクスを正しく付けているかを 1 度実機確認（`mode` を変えると返るベクトルが変わる）

**完了確認**
- [ ] `EmbedAsync` が `mode` を必須概念として受ける（即値 `"query"` がコードから消えた）
- [ ] 分類で呼ぶときは `EmbedMode.Query`、Knowledge 登録/再 embedding は `EmbedMode.Passage` を使うルールをコメント/メモに明記
- [ ] `query` と `passage` で `/embed` のレスポンスベクトルが異なることを実機で確認
- [ ] `dotnet build` warning 0、既存呼び出し元が新シグネチャで通る

**詰まったら**
- どこでプレフィクスを付けるか迷う → サーバ側（embedding service）が付ける。Web は生テキスト + mode のみ。両方で付けると `query: query: ...` になり劣化する
- 既存呼び出し元が見つからない → `grep -rn "EmbedAsync" backend/` で洗い出してから署名変更

**AI 依頼テンプレ**: なし（インターフェース判断は自分。実装の機械的修正だけ AI に出すなら下記）
```
backend/Portfolio.Web/Services/IEmbeddingClient.cs に EmbedMode { Query, Passage } enum を足し、
EmbedAsync(string text, EmbedMode mode = EmbedMode.Query, CancellationToken ct = default) に変更した。
EmbeddingClient.cs の "query" 即値を mode から導く実装に直し、既存の EmbedAsync 呼び出し元
（grep -rn EmbedAsync backend/ で洗い出す）を新シグネチャに合わせて。挙動は変えない。
```

---

## Day 1 終了チェックリスト

- [ ] Knowledge / FieldDefinition の CRUD が動き、検索検証用データが自テナントに入っている
- [ ] `search_text`（tsvector）が自動で埋まり、`ts_rank` クエリが手で叩いてヒットする
- [ ] `Portfolio.Search` ライブラリと `ClassifyCandidate` / `ClassifyResult` / `ICandidateSearch` / `MatchStrategy` が定義され、ビルドが通る
- [ ] `ExactMatchSearch` が `ICandidateSearch` 実装として動き、完全一致で `Score=1.0` を返す
- [ ] Embedding クライアントが `query:`/`passage:` を `mode` で使い分けられる
- [ ] `dotnet build Portfolio.sln --configuration Release` が warning 0

## Day 2 への引き継ぎメモ（自分宛て）

- 検索段は全部 `ICandidateSearch` を実装する（Day2 の BM25 / Embedding も同じ形 → AI に複製依頼できる）
- BM25 / Embedding は `<=>` や `ts_rank` を使うため LINQ では書けない。EF の `FromSql` で生 SQL（パラメータ化）を Web 側に置く
- `tenant_id` は SQL に書かない（RLS 任せ）。`category_id` だけ「わからない」時に省略する分岐を入れる
- Embedding 検索は `embedding_model = current_model` で絞る（[`05_search_classification.md:178-186`](../05_search_classification.md) のモデル混在対応）。`current_model` の供給元（設定値）を Day2 で決める
