# Sprint 2 Day 1 作業指示書（2026-05-22）

> テーマ: **検索基盤の足場を立てる**
> 完了時の状態: `apps/api/src/search/` モジュールができ、`ICandidateSearch` / `ClassifyCandidate` の型が確定し、`exactMatch`（キーワード完全一致）の最初の 1 個が動く。Embedding 呼び出しの `query:`/`passage:` 使い分けが整理されている
> 推定所要: 5〜7 時間

---

## Day1-1. 残 CRUD（Knowledge / FieldDefinition）テンプレ展開 [AI] [FE] [BE]

**目的**
Sprint 1 で作った Category CRUD のパターン（フォーム + バリデーション）を Knowledge / FieldDefinition に複製し、検索対象データを画面から投入できる状態にする。今日以降の検索タスクで「手で INSERT する」手間を消すリハビリ。検索ロジックそのものではないので AI に委譲する。

**前提確認**
- [ ] Sprint 1 完了（`/categories` の一覧・作成・編集が動く）
- [ ] `KnowledgeEntry` / `FieldDefinition` のスキーマ列を `apps/api/src/db/schema.ts`（または相当ファイル）で確認した
- [ ] テナント分離は `tenant_id` ルーティングで行われている前提（Sprint 1 Day2-4 の `tenantMiddleware`）を理解した

**手順**
1. AI に下記テンプレで依頼し、`apps/api/src/routes/knowledge/` と `apps/api/src/routes/fieldDefinitions/` にルートハンドラを生成させる
2. `KnowledgeEntry` の配列フィールド（`keywords` / `exampleQueries` / `requiredFieldCodes` は `string[]`）はカンマ区切りの 1 行入力 → `split(',').map(s => s.trim())` で配列化する単純実装で良い（凝った multi-row UI は Sprint 4）
3. `embedding` / `embeddingModel` フィールドは **この画面では埋めない**（Day1-5 と Day2 で扱う）。null のままで良い
4. 生成後、自テナントで 2〜3 件 Knowledge を登録（後続タスクの検索データになる。`name` / `keywords` / `exampleQueries` を意味のある日本語で）

**完了確認**
- [ ] `/t/:slug/knowledge` で一覧 → 作成 → 編集が回る
- [ ] 別テナントの Knowledge が見えない（テナント分離目視確認）
- [ ] `pnpm build` が warning 0（`strict` モード）
- [ ] 検索検証用に 3 件以上の Knowledge が自テナントに入っている

**詰まったら**
- 配列フィールドのバインドでエラー → `string[]` を直接フォームにバインドせず、中間の `string` プロパティ（カンマ区切り）を介す
- 一覧に他テナント分が出る → `tenantMiddleware` が効いていない。Sprint 1 Day2-4 を疑う

**AI 依頼テンプレ**
```
Sprint 1 で作った apps/api/src/routes/categories/ の index/create/edit ハンドラと同じパターンで、
KnowledgeEntry と FieldDefinition の CRUD ルートハンドラを
apps/api/src/routes/knowledge/ と apps/api/src/routes/fieldDefinitions/ に作って。

制約:
- ルートは /t/:slug/knowledge と /t/:slug/field-definitions、認証ミドルウェアを通す
- tenantId はリクエストコンテキストから取る（クライアント値を信用しない。design/04 参照）
- KnowledgeEntry の string[] フィールド（keywords, exampleQueries, requiredFieldCodes）は
  カンマ区切りの単一テキスト入力にし、保存時に split(',').map(s=>s.trim())、表示時に join(', ')
- embedding と embeddingModel フィールドは触らない（null のまま）
- 読み取りクエリは SELECT 限定、SQL はパラメータ化のみ（文字列連結禁止）
変更は routes/ 配下に閉じること。DB スキーマやエンティティ定義は変更しない。
```

---

## Day1-2. ES インデックス（mapping / kuromoji アナライザ）と検索用インデックスの動作確認 [自分] [INFRA]

**目的**
ハイブリッド検索の BM25 側は Elasticsearch の `knowledge_entries` インデックスに全面的に依存する。このインデックスの **mapping が正しく作られ、Knowledge 投入時にドキュメントが入り、日本語クエリにマッチするか**を Day2 の前に自分の手で確かめる。ここを確認せずに進むと Day2-1 の BM25 DSL がなぜ 0 件なのか切り分け不能になる。面接では「BM25 のためのフィールド設計と kuromoji アナライザを選んだ理由」を語れる。

**自分で書く理由**
検索のヒット/ミスの根本原因がこのインデックス mapping にある。AI に「動作確認して」と投げると確認の意味が消える。mapping の定義（`infra/es/mappings/knowledge_entries.json`）と kuromoji アナライザの挙動を自分で握る。

**前提確認**
- [ ] Day1-1 で Knowledge が数件入っている（ES への同期も済んでいるか確認）
- [ ] `infra/es/mappings/knowledge_entries.json` を読んだ。フィールド構成は:
  - `name`（`text`, analyzer: kuromoji）/ `name.raw`（`keyword`）
  - `keywords`（`text`, analyzer: kuromoji）/ `keywords.raw`（`keyword`）
  - `example_queries`（`text`, analyzer: kuromoji）
  - `embedding`（`dense_vector`, dims: 768, similarity: cosine）
  - `tenant_id`（`keyword`, routing）
  - `match_count`（`integer`）
- [ ] [`05_search_classification.md:39-57`](../05_search_classification.md) を読んだ

**手順**
1. インデックスの mapping を確認:
   ```bash
   curl -s http://localhost:9200/knowledge_entries/_mapping | jq .
   ```
   - `name` に `kuromoji` アナライザが付いているか、`embedding` が `dense_vector` dims=768 か確認
2. ドキュメントが入っているか確認:
   ```bash
   curl -s 'http://localhost:9200/knowledge_entries/_search?q=*&size=5' | jq '.hits.hits[]._source.name'
   ```
   - 空なら Knowledge 登録後の ES 同期が動いていない。インデクサのコードを確認
3. 実際の BM25 クエリを手で試す（Day2-1 で使う DSL の核）:
   ```bash
   curl -s -XPOST 'http://localhost:9200/knowledge_entries/_search' \
     -H 'Content-Type: application/json' \
     -d '{
       "query": {
         "bool": {
           "must": {
             "multi_match": {
               "query": "パスワード 再発行",
               "fields": ["name", "keywords", "example_queries"],
               "analyzer": "kuromoji"
             }
           },
           "filter": { "term": { "tenant_id": "<自テナントID>" } }
         }
       }
     }' | jq '.hits.hits[] | {name: ._source.name, score: ._score}'
   ```
4. kuromoji アナライザが日本語を形態素解析することを体感する。`keywords` / `exampleQueries` の充実がヒット率に直結する設計上の含意をメモに残す

**完了確認**
- [ ] mapping に `name`（kuromoji）と `embedding`（dense_vector 768）が宣言されている
- [ ] ドキュメントが複数件入っている
- [ ] 手で書いた `multi_match` クエリが、登録した Knowledge をスコア降順で返す
- [ ] `tenant_id` filter なしで別テナントのドキュメントが出ないことを確認した（kuromoji は形態素解析するのでキーワード充実が効くことをメモ）

**詰まったら**
- mapping がデフォルトのまま → `infra/es/` の初期化スクリプトが実行されていない。`curl -XPUT` でインデックスを作り直す
- kuromoji プラグインが入っていない → `GET /_cat/plugins` で確認。docker-compose の ES イメージに `analysis-kuromoji` が含まれているか確認
- 日本語が全くヒットしない → analyzer が `standard` になっている。mapping を確認して kuromoji を明示

**AI 依頼テンプレ**: なし（自分で確認する範囲）

---

## Day1-3. `apps/api/src/search/` モジュールと型の骨子定義 [自分] [BE]

**目的**
分類ロジックを API ルートハンドラから切り離した `apps/api/src/search/` モジュールに置く。今日この境界（インターフェースと戻り値の型）を確定させると、Day2 の検索 DSL も Day3 の LLM も「この型を返す/受ける」だけで AI に委譲できる。面接で「分類エンジンをサービス層として独立させ、UI と DB の都合から切り離した」と語れる中核。

**自分で書く理由**
ここが Sprint 2 全体の **インターフェース定義**。`09_task_split.md:123` の「ステップ3＝自分が握る最重要部分」に当たる。型を AI に決めさせると、後続タスクが全部その型に引きずられ、自分が説明できないコードになる。

**前提確認**
- [ ] [`05_search_classification.md:188-219`](../05_search_classification.md)（擬似コード全文）を読んだ
- [ ] 設計書の擬似コードは戻り値が `KnowledgeEntry[]` だが、**スコアと match_strategy を呼び出し側に返したい**ので候補は専用の型にする、という判断を理解した
- [ ] モジュール命名は `search/` 配下に揃える（設計書の擬似コードとファイル名が違っても従わない）

**手順**
1. モジュールディレクトリを作成し、エントリポイントを用意する:
   ```bash
   mkdir -p apps/api/src/search
   touch apps/api/src/search/index.ts
   touch apps/api/src/search/types.ts
   touch apps/api/src/search/interfaces.ts
   ```
2. 戻り値の型を自分で定義する（`apps/api/src/search/types.ts`）。骨格だけ示す。中身（フィールド・値）は自分で埋める:
   ```typescript
   // match_strategy（design 05 章の確定値）。確定後にどの段で当たったかを呼び出し側に返す。
   // ここを自分で定義: design 05 章のどの段で当たったかを表す union（'keyword' | 'hybrid' | 'llm' | 'none'）
   export type MatchStrategy = /* ... */;

   // 1 件の候補。スコアと match_strategy を呼び出し側に返したい（だから設計擬似コードの KnowledgeEntry[] ではなく専用型）。
   // ここを自分で定義: 候補を一意に識別する id、表示名、スコア、当たった段（MatchStrategy）を持つ readonly な型
   export type ClassifyCandidate = {
     readonly /* ... */
   };

   // 分類全体の結果。候補リスト + 最終的にどの段で確定/打ち切ったか + top1 が confident 閾値以上か。
   // ここを自分で定義: 候補リスト、最終 strategy、isConfident（boolean）を持つ型
   export type ClassifyResult = {
     readonly /* ... */
   };
   ```
   - 設計書の擬似コードは戻り値が `KnowledgeEntry[]` だが、**スコアと match_strategy を呼び出し側に返したい**ので専用型にする、という判断は前提確認で握ったとおり
3. 検索段ごとのインターフェースを定義する（`apps/api/src/search/interfaces.ts`）。**実装は Day1-4 / Day2 で埋める**。シグネチャの設計（引数に何を載せるか）が後続全段を縛るので自分で決める:
   ```typescript
   import type { ClassifyCandidate } from './types.js';

   // 1 段 = 1 つの検索ストラテジ。query は生の自然文（プレフィクス未付与）。
   export interface ICandidateSearch {
     // ここを自分で定義: search メソッド。
     //   - 入力: 生クエリ / tenantId / categoryId?（不明時 undefined で全件）/ 取得件数 limit
     //   - 出力: Promise<readonly ClassifyCandidate[]>
     //   - tenant_id は ES filter 必須（04_security_multitenant.md）だが、引数では受ける（監査・将来用）
   }
   ```
4. `apps/api/src/search/` は **DB クライアントに直接依存させない**方針を決める（ES クエリ発行は各実装クラスが担い、search/ は式とインターフェースに集中）。この境界をコメントに 1 行残す
5. ビルドを通す（実装は空でもインターフェースと型だけで通る）

**完了確認**
- [ ] `pnpm build` が green（型エラー 0）
- [ ] API ルートから `apps/api/src/search/` の型が参照できる
- [ ] `ClassifyCandidate` / `ClassifyResult` / `MatchStrategy` / `ICandidateSearch` の 4 つが定義された
- [ ] 「search/ はエンジン、DB/ES アクセスは各実装」という境界をコメントで明示した

**詰まったら**
- 参照が循環する → `search/` から上位ルートを参照してはいけない。依存は routes → search の一方向
- Vector 型を search/ に持ち込みたくなる → 持ち込まない。Embedding 検索の ES クエリ発行は実装側、search/ は順位だけ受け取る設計に倒す（Day2-3 で効いてくる）

**AI 依頼テンプレ**: なし（自分で書くインターフェース定義）

---

## Day1-4. `exactMatch`（キーワード完全一致）の最初の 1 個 [自分] [BE]

**目的**
分類フロー④（[`05_search_classification.md:39-43`](../05_search_classification.md)）を実装する。問題名 exact match で即確定する「高信頼ショートカット」。検索段の最初の 1 個を自分の手で書くことで、Day2 の BM25 / Embedding 段が同じ `ICandidateSearch` 形に複製できる型を確定させる。

**自分で書く理由**
「最初の 1 個」（SKILL.md の委譲ルール）。`ICandidateSearch` を最初に実装することで、戻り値の作り方・パラメータ化・テナント分離の前提（`tenant_id` は ES filter に必ず含める）を自分で握る。残り 2 段は AI が複製可能になる。

**前提確認**
- [ ] Day1-3 完了（型がある）
- [ ] [`05_search_classification.md:39-43`](../05_search_classification.md)（④の判定基準）を読んだ
- [ ] 「問題名 exact match は即確定、部分一致は信頼せずハイブリッドに流す」という設計判断を理解した

**手順**
1. `apps/api/src/search/exactMatch.ts` を作る（`ICandidateSearch` を実装）
2. ES の `term` クエリ（`name.raw` への完全一致）と `terms` クエリ（`keywords.raw` への完全一致）を使う（④は「完全一致」なので `multi_match` ではない）。クエリ本体は自分で書く:
   ```typescript
   import type { ICandidateSearch, ClassifyCandidate } from './index.js';

   export class ExactMatchSearch implements ICandidateSearch {
     constructor(private readonly esClient: /* ES クライアント型 */) {}

     async search(
       query: string,
       tenantId: string,
       categoryId: string | undefined,
       limit: number
     ): Promise<readonly ClassifyCandidate[]> {
       // tenant_id は ES filter に必ず含める（design 04）。
       // ここを自分で実装:
       //   1) bool.filter に { term: { tenant_id: tenantId } } を必ず入れる
       //   2) bool.should に name.raw の term 完全一致 OR keywords.raw の term 完全一致を入れる
       //      ※ multi_match や fuzzy は使わない（④は完全一致のみ。部分一致は Day2 のハイブリッド）
       //   3) categoryId が来たら filter に { term: { category_id: categoryId } } を追加（undefined なら省略）
       //   4) size: limit で結果を取得し ClassifyCandidate に射影（score は exact なので最高信頼の固定値、strategy: 'keyword'）
       throw new Error('NotImplemented');
     }
   }
   ```
   - `_score` は exact なので最高信頼の固定値にする（値は自分で決める）
3. **問題名の完全一致のみ即確定**にしたいので、`name.raw` ヒットは `isConfident` 相当として扱える設計にする（確定判定は Day3-3 の `ClassifyService` 側で `strategy==='keyword' && top1` を見る、と決めておく。ここでは候補を返すだけ）
4. DI / サービスロケータに `ExactMatchSearch` を登録（`apps/api/src/container.ts` または相当ファイル）

**完了確認**
- [ ] 登録済み Knowledge の `name` を丸ごとクエリに渡すと、その 1 件が `score=1.0` で返る
- [ ] `keywords` に含まれる語を渡すとヒットする
- [ ] 無関係な語では 0 件
- [ ] `categoryId` を渡すとそのカテゴリ内に絞られる
- [ ] ES クエリに `filter: { term: { tenant_id }}` が含まれ、別テナント分が漏れない

**詰まったら**
- `term` クエリでヒットしない → `name.raw` が `keyword` 型として mapping されているか確認。`name`（kuromoji text）に term を当てると分析済みトークンと合わず 0 件になる
- 部分一致もヒットさせたくなる → ④は完全一致のみ。部分一致は Day2 のハイブリッドの仕事。ここで欲張らない
- 別テナントでヒットしてしまう → `filter` に `tenant_id` が入っていない。`must` でなく `filter` に入れること

**AI 依頼テンプレ**: なし（最初の 1 個は自分で書く）

---

## Day1-5. Embedding 呼び出しの `query:`/`passage:` プレフィクス整理 [自分] [BE] [ML]

**目的**
`multilingual-e5-base` は **query には `query:`、文書には `passage:`** を付けないと recall が静かに劣化する（CLAUDE.md 横断ルール / [`embedding/CLAUDE.md`](../../embedding/CLAUDE.md)）。分類クエリは `query:` 側。現状 `embedClient.ts` は `mode` が `"query"` 固定で、文書側（`passage`）を呼べない。分類で正しく `query` を、Knowledge 登録/再 embedding で `passage` を使い分けられるよう、クライアント API を自分で整理する。面接で「e5 のプレフィクス規約と、間違えると recall が落ちる理由」を語れる。

**自分で書く理由**
検索品質に直結する規約で、かつ「気づきにくいバグ」の温床。`mode` をどう渡すかのインターフェース判断は自分が握り、内部実装の量産は AI に出せる状態にしておく。

**前提確認**
- [ ] `apps/api/src/services/embedClient.ts` を読んだ（現状 `embed(text)` が `mode="query"` 固定）
- [ ] `embedding/app/main.py` の `/embed` が `mode` を受け、サーバ側でプレフィクスを付ける設計を確認した
- [ ] [`embedding/CLAUDE.md`](../../embedding/CLAUDE.md) の「prefix `query: ` for queries, `passage: ` for documents」を読んだ

**手順**
1. プレフィクスの「正」がサーバ側（`embedding/app/`）にあることを確認する。**Web からは生テキスト + `mode` を送り、`query:`/`passage:` 文字列をクライアントで手付けしない**（二重付与防止）。この方針を 1 行コメントで残す
2. `EmbedMode` を表す union 型を導入して使い分けを型で強制する（`"query"` 即値リテラルを消す）。骨格だけ示す:
   ```typescript
   // apps/api/src/services/embedClient.ts

   // ここを自分で定義: query / passage を表す 2 値の union（e5 のプレフィクス規約に対応）
   export type EmbedMode = /* ... */;

   export interface IEmbedClient {
     // ここを自分で定義: embed(text: string, mode: EmbedMode): Promise<number[]> のシグネチャ。
     //   - mode は既定 'query' にして既存呼び出し元の移行を楽にするか、必須にして付け忘れを防ぐかを自分で判断
   }
   ```
3. `EmbedClient` 側で union → `/embed` の `mode` 文字列（`"query"` / `"passage"`）に変換する。**変換（マッピング）は 1 箇所に閉じる**こと。即値 `"query"` がコードから消える状態を自分で作る
4. 既存呼び出し元（Sprint 1 のデバッグ画面 / Seed ツールがあれば）を新シグネチャに直す。**分類クエリは必ず `'query'`、Knowledge の embedding 生成は `'passage'`** という対応を決める
5. サーバ側がプレフィクスを正しく付けているかを 1 度実機確認（`mode` を変えると返るベクトルが変わる）

**完了確認**
- [ ] `embed` が `mode` を必須概念として受ける（即値 `"query"` がコードから消えた）
- [ ] 分類で呼ぶときは `'query'`、Knowledge 登録/再 embedding は `'passage'` を使うルールをコメント/メモに明記
- [ ] `query` と `passage` で `/embed` のレスポンスベクトルが異なることを実機で確認
- [ ] `pnpm build` 型エラー 0、既存呼び出し元が新シグネチャで通る

**詰まったら**
- どこでプレフィクスを付けるか迷う → サーバ側（embedding service）が付ける。API 側は生テキスト + mode のみ。両方で付けると `query: query: ...` になり劣化する
- 既存呼び出し元が見つからない → `grep -rn "embed(" apps/` で洗い出してから署名変更

**AI 依頼テンプレ**: なし（インターフェース判断は自分。実装の機械的修正だけ AI に出すなら下記）
```
apps/api/src/services/embedClient.ts に EmbedMode = 'query' | 'passage' を定義し、
embed(text: string, mode: EmbedMode = 'query'): Promise<number[]> に変更した。
EmbedClient 側で mode をそのまま /embed の mode パラメータに渡す実装に直し、
既存の embed(...) 呼び出し元（grep -rn "\.embed(" apps/ で洗い出す）を新シグネチャに合わせて。挙動は変えない。
```

---

## Day 1 終了チェックリスト

- [ ] Knowledge / FieldDefinition の CRUD が動き、検索検証用データが自テナントに入っている
- [ ] ES インデックスに Knowledge ドキュメントが入り、`multi_match`（kuromoji）クエリが手で叩いてヒットする
- [ ] `apps/api/src/search/` モジュールと `ClassifyCandidate` / `ClassifyResult` / `ICandidateSearch` / `MatchStrategy` が定義され、ビルドが通る
- [ ] `ExactMatchSearch` が `ICandidateSearch` 実装として動き、完全一致で `score=1.0` を返す
- [ ] Embedding クライアントが `query:`/`passage:` を `mode` で使い分けられる
- [ ] `pnpm build` が型エラー 0

## Day 2 への引き継ぎメモ（自分宛て）

- 検索段は全部 `ICandidateSearch` を実装する（Day2 の BM25 / Embedding も同じ形 → AI に複製依頼できる）
- BM25 / Embedding は ES の Query DSL を直接発行する。ORM は使わない
- **全 ES クエリに `filter: { term: { tenant_id } }` 必須**（04_security_multitenant.md）。`categoryId` だけ「わからない」時に省略する分岐を入れる
- Embedding 検索は `embedding_model = current_model` でフィルタ（[`05_search_classification.md:178-186`](../05_search_classification.md) のモデル混在対応）。`current_model` の供給元（設定値）を Day2 で決める
