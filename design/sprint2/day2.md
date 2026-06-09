# Sprint 2 Day 2 作業指示書（2026-05-23）

> テーマ: **ハイブリッド検索（BM25 + Embedding を 1 本のランキングに束ねる）**
> 完了時の状態: BM25 検索と Embedding 検索がそれぞれ候補を返し、RRF で 1 本のランキングに結合され、`match_count` 重みが加味された top-N が出る
> 推定所要: 5〜7 時間

---

## Day2-1. BM25 検索（ES multi_match / kuromoji）Query DSL [AI] [BE]

**目的**
分類フロー⑤の片肺、BM25 側（[`05_search_classification.md:47-57`](../05_search_classification.md)）を実装する。Day1-2 で確認した ES インデックスと kuromoji アナライザを使い、`ICandidateSearch` 実装として候補 20 件を返す。Query DSL の型は Day1-2 で自分が手で確認済みなので、TypeScript 実装は AI に複製させる。

**前提確認**
- [ ] Day1-2 で `multi_match` クエリが手で動いた
- [ ] Day1-3 の `ICandidateSearch` / `ClassifyCandidate` がある
- [ ] ES クライアントで Query DSL を直接発行することを理解した（ORM は使わない。パラメータはオブジェクトで渡すのでインジェクション不可）

**手順**
1. AI に下記テンプレで `apps/api/src/search/bm25Search.ts` を生成させる
2. Query DSL は設計書 [`05_search_classification.md:49-57`](../05_search_classification.md) の形。`filter` に `{ term: { tenant_id } }` を**必ず含める**（04_security_multitenant.md）。`category_id` は undefined のとき省略
3. レビュー観点: ① `filter` に `tenant_id` が入っているか ② `_score` を `ClassifyCandidate.score` に入れ `strategy: 'hybrid'` にしているか ③ `size: 20`

**完了確認**
- [ ] Day1-2 で叩いた語で BM25 候補がスコア降順 20 件以内で返る
- [ ] `categoryId` 指定でカテゴリ内に絞られ、undefined で全件対象になる
- [ ] 別テナントのドキュメントが漏れない（`tenant_id` filter）
- [ ] ES クライアントへの引数がオブジェクト（文字列連結なし）になっている

**詰まったら**
- `multi_match` が 0 件 → Day1-2 の手動クエリと同じ `analyzer: 'kuromoji'` か確認。`fields` 指定（`name`, `keywords`, `example_queries`）が mapping のフィールド名と一致しているか
- スコアが全件同じ → `_score` でなく固定値を入れてしまっている。`hit._score` を使う

**AI 依頼テンプレ**
```
apps/api/src/search/bm25Search.ts を作って。ICandidateSearch を実装する。
仕様（design/05_search_classification.md の 5-1 が正）:
- ES クライアントを DI で受ける
- Query DSL:
  {
    "query": {
      "bool": {
        "must": {
          "multi_match": {
            "query": "<query>",
            "fields": ["name", "keywords", "example_queries"],
            "analyzer": "kuromoji"
          }
        },
        "filter": [
          { "term": { "tenant_id": "<tenantId>" } }
          // categoryId が undefined でなければ: { "term": { "category_id": "<categoryId>" } }
        ]
      }
    },
    "size": <limit>
  }
- tenant_id filter は必須（design/04 参照）
- 各 hit を ClassifyCandidate{ id, name, score: hit._score, strategy: 'hybrid' } に詰めて返す
- Promise<readonly ClassifyCandidate[]> を返す非同期関数
制約: TypeScript strict、パラメータはオブジェクトで渡す（文字列連結禁止）。
container.ts に DI 登録も足して。
```

---

## Day2-2. Embedding 検索（ES knn dense_vector コサイン）Query DSL [AI] [BE] [ML]

**目的**
⑤のもう片肺、Embedding 側（[`05_search_classification.md:59-72`](../05_search_classification.md)）。Day1-5 で整理した `mode: 'query'` で分類クエリをベクトル化し、ES knn（dense_vector 768、cosine）で近傍 20 件を返す。BM25 と同じ `ICandidateSearch` 形なので、Day2-1 のパターン複製として AI に出す。

**前提確認**
- [ ] Day1-5 完了（`embed(text, 'query')` が使える）
- [ ] Day2-1 のパターン（ES クライアント直叩き + tenant_id filter）を踏襲する
- [ ] Knowledge に `embedding` フィールドが埋まっているドキュメントがあるか確認（Day1-1 では埋めていない → このタスクの前に数件 `'passage'` で embedding を入れる必要がある。下記手順1）

**手順**
1. 検証データを用意する: 自テナントの Knowledge 数件に対し `embed(name, 'passage')` で算出したベクトルを `embedding` フィールドに、使用モデル名を `embedding_model` フィールドに投入する（小さな一回限りのスクリプト or デバッグ画面ボタンで可）。**ここは `'passage'`**
2. `current_model` の供給元を決める: MVP は環境変数 `EMBEDDING_MODEL` から取り `intfloat/multilingual-e5-base` を 1 箇所に。`embedding_model = currentModel` でフィルタ（モデル混在対応 [`05_search_classification.md:178-186`](../05_search_classification.md)）
3. AI に下記テンプレで `apps/api/src/search/embeddingSearch.ts` を生成させる
4. レビュー観点: ① クエリのベクトル化が `mode: 'query'` か（`'passage'` になっていないか — recall 劣化の罠）② knn の `filter` に `tenant_id` と `embedding_model` が入っているか ③ `_score`（cosine 類似度）を `ClassifyCandidate.score` に入れているか

**完了確認**
- [ ] embedding を入れた Knowledge に対し、意味が近い別表現のクエリで上位に出る（exact では出ない語で試す）
- [ ] `embedding_model` が `current_model` と違う行は除外される（knn filter）
- [ ] クエリ側が `mode: 'query'` でベクトル化されている（コード確認）
- [ ] `categoryId` 指定で絞られる

**詰まったら**
- knn が 0 件 → `embedding` フィールドにベクトルが入っているドキュメントが無い（手順1 未実施）か、`dense_vector` の `dims` が mapping と一致していない
- 結果がランダム → knn は similarity=cosine で自動的にスコア降順になる。`_score` を確認
- knn filter が効かない → ES 8.x 以降は `knn.filter` が使える。ES バージョンを確認

**AI 依頼テンプレ**
```
apps/api/src/search/embeddingSearch.ts を作って。ICandidateSearch を実装。
Day2-1 の bm25Search.ts と同じ構造で、検索手段だけ ES knn に変える。
仕様（design/05_search_classification.md の 5-2 が正）:
- コンストラクタで ES クライアントと IEmbedClient を受ける
- まず const vec = await embedClient.embed(query, 'query');  ← 必ず 'query' モード
- Query DSL（knn）:
  {
    "knn": {
      "field": "embedding",
      "query_vector": vec,
      "k": <limit>,
      "num_candidates": 100,
      "filter": [
        { "term": { "tenant_id": "<tenantId>" } },
        { "term": { "embedding_model": "<currentModel>" } }
        // categoryId が undefined でなければ: { "term": { "category_id": "<categoryId>" } }
      ]
    }
  }
- currentModel は環境変数 EMBEDDING_MODEL（デフォルト "intfloat/multilingual-e5-base"）から
- 各 hit を ClassifyCandidate{ id, name, score: hit._score, strategy: 'hybrid' } に
制約: TypeScript strict。container.ts に DI 登録も。
注意: クエリ側を 'passage' モードで埋め込まないこと（recall が静かに落ちる。embedding/CLAUDE.md）。
```

---

## Day2-3. RRF（Reciprocal Rank Fusion）結合の実装 [自分] [BE]

**目的**
BM25 と Embedding という **スケールの違う 2 つのスコア**を、スコアそのものではなく**順位**で束ねる RRF（[`05_search_classification.md:74-84`](../05_search_classification.md)）を実装する。`RRF_score(d) = Σ 1/(k + rank_i(d))`。これがハイブリッド検索の心臓で、面接の主役。`apps/api/src/search/` に純粋関数として置く（ES 非依存 → テストしやすい）。

**自分で書く理由**
`09_task_split.md:16,25` で「RRF + match_count 重み付け式」は明示的に自分が書く領域。スコアでなく順位を使う理由（BM25 の `_score` と Embedding の cosine 類似度はスケールが違い、足し算できない）を自分の言葉で説明できる必要がある。ここを AI に書かせると面接で詰む。

**前提確認**
- [ ] Day2-1 / Day2-2 で 2 系統の候補リストが取れる
- [ ] [`05_search_classification.md:74-84`](../05_search_classification.md)（RRF の式と `k=60`）を読んだ
- [ ] 「score ではなく rank（順位）を式に入れる」ことを理解した（つまづき表の典型ミス）

**手順**
1. `apps/api/src/search/rrf.ts` に純粋関数として書く（ES クライアント非依存）。骨格・式だけ示す。中身は自分で実装する:
   ```typescript
   import type { ClassifyCandidate } from './types.js';

   // 各ランキング（順位順に並んだ候補列）を RRF で 1 本に束ねる。
   // score は使わず順位だけ使う（BM25 と Embedding はスケールが違い、足し算できないため）。
   // 式: RRF_score(d) = Σ_i 1 / (k + rank_i(d))   ※ rank は 1 始まり、k は標準値 60
   export function fuse(
     rankings: ReadonlyArray<readonly ClassifyCandidate[]>,
     k = 60
   ): readonly ClassifyCandidate[] {
     // ここを自分で実装:
     //   1) knowledgeEntry の id をキーに、累積 RRF スコア（+ 表示名）を貯める Map を用意
     //   2) 各 ranking を走査し、index を rank に変換（0 始まり → +1）して 1/(k + rank) を加算
     //      ※ ここで candidate.score は使わない。使ったら BM25 と Embedding のスケール差で壊れる
     //   3) 同じ id が複数ランキングに出たら寄与を足し込む（和集合・スコア合算）
     //   4) ClassifyCandidate に詰め直し、累積スコアの降順に並べて返す（strategy: 'hybrid'）
     throw new Error('NotImplemented');
   }
   ```
2. 入力は「順位順に並んだ候補列」。Day2-1 / 2-2 はすでにスコア降順で返るので、配列の index がそのまま rank になる
3. `k=60` は標準値。なぜ 60 かを 1 行コメント（外れ値の影響を薄め、上位の差を残す経験則）

**完了確認**
- [ ] 両ランキングで 1 位の文書が、片方だけ 1 位の文書より上に来る（簡単な手計算と一致）
- [ ] 片方にしか出ない文書も結合結果に含まれる（和集合）
- [ ] スコアではなく順位を使っている（BM25 の `_score` を 100 倍しても結果順が変わらないことで確認）
- [ ] `apps/api/src/search/rrf.ts` が ES クライアントに依存していない（純粋関数）

**詰まったら**
- 結果が BM25 とほぼ同じ → score を足してしまっている。rank（index+1）を使う
- 同点が多い → `k` が大きすぎ or 候補が少なすぎ。MVP の小データでは正常

**AI 依頼テンプレ**: なし（式の中核は自分で書く。テストは Day3-4 で AI に出す）

---

## Day2-4. match_count 重み付け式と top-N 整形 [自分] [BE]

**目的**
RRF スコアに「過去によくマッチした問題ほど少し優遇する」`match_count` 重み（[`05_search_classification.md:86-93`](../05_search_classification.md)）を加える。`final_score = RRF_score + α * log(1 + match_count)`、`α=0.1`。`log` で頭打ちにする理由（match_count=1 と 100 で 100 倍にしない）を自分で握る。最後に top-3 に整形して `ClassifyResult` 手前まで作る。

**自分で書く理由**
`09_task_split.md` で重み付け式は自分の領域。`α` と `log` の選択は分類品質のチューニングポイントで、面接で「なぜ線形でなく対数か」を説明する。

**前提確認**
- [ ] Day2-3 の RRF が動く
- [ ] `knowledge_entries` ドキュメントの `match_count` フィールドの存在を ES mapping で確認した
- [ ] `ClassifyCandidate` には現状 match_count が無い → 重み加算のために候補に match_count を持たせるか、加算を別ステップで行うか判断する

**手順**
1. `match_count` を候補に渡す経路を決める。**RRF は ES 非依存に保ちたい**ので、match_count 加算は ES を引ける層で行う設計に倒す。Day2-1/2-2 の候補に `matchCount` を載せるか、結合後に id 群で ES から `match_count` を引き直す。MVP は「結合後に id 群で `match_count` を mget → 加算」がシンプル
2. `apps/api/src/search/matchCountWeighting.ts` に重み式だけ純粋関数で置く（テスト容易性）。骨格・式だけ示す。中身は自分で実装する:
   ```typescript
   // α は分類品質のチューニングポイント。1 箇所に定数で持つ（将来テナント別チューニングは Sprint 2 範囲外）。
   export const DEFAULT_ALPHA = 0.1;

   // final = rrf + α * log(1 + matchCount)。
   // なぜ線形でなく log か: match_count=1 と 100 で 100 倍に効かせず頭打ちにするため（面接で説明する）。
   export function applyMatchCount(
     rrfScore: number,
     matchCount: number,
     alpha = DEFAULT_ALPHA
   ): number {
     // ここを自分で実装: 上式（rrfScore に α*log(1+matchCount) を加える）を 1 行で返す
     throw new Error('NotImplemented');
   }
   ```
3. 結合後の候補に `applyMatchCount` を適用し、スコア降順で `slice(0, 3)` して top-3 に整形（[`05_search_classification.md:211`](../05_search_classification.md)）
4. `α` を定数 1 箇所に。閾値同様「将来テナント別チューニング」は Sprint 2 範囲外とメモ

**完了確認**
- [ ] match_count が大きい候補がわずかに上がる（差が `α*log` の桁＝ RRF スコアを逆転しない程度）であることを手計算で確認
- [ ] match_count=0 の候補は `log(1)=0` で素の RRF スコアのまま
- [ ] top-3 に整形され、各候補に `finalScore` が入る
- [ ] `α` と `log` の選択理由をコメントに残した

**詰まったら**
- match_count が候補を支配する → `α` が大きすぎる。0.1 から動かさない（RRF を覆さないのが狙い）
- `matchCount` をどこで引くか迷う → 結合後の id 群で ES mget（`_mget`）か、別途 `terms` クエリで `match_count` だけ取得。N+1 にしない

**AI 依頼テンプレ**: なし（式は自分。match_count を引く ES クエリ部分だけ AI に出すなら下記）
```
RRF 結合後の ClassifyCandidate のリスト（id を持つ）を受け取り、
ES の mget（または terms filter）で対応する knowledge_entries の match_count を 1 リクエストまとめ取得し、
matchCountWeighting.applyMatchCount(score, matchCount) でスコアを更新して
スコア降順 top-3 を返すヘルパーを apps/api/src/search/ に書いて。N+1 にしないこと。
```

---

## Day 2 終了チェックリスト

- [ ] `Bm25Search` が `ICandidateSearch` 実装として候補を返す（ES Query DSL、tenant_id filter 必須）
- [ ] `EmbeddingSearch` が `mode: 'query'` でベクトル化し ES knn で近傍を返す
- [ ] `fuse`（RRF）が順位ベースで 2 系統を 1 本に束ねる（ES 非依存）
- [ ] `applyMatchCount` で `α*log(1+match_count)` が加味され top-3 が出る
- [ ] スコアでなく順位を使っていることを「BM25 スコアを定数倍しても順位不変」で確認した
- [ ] `pnpm build` が型エラー 0

## Day 3 への引き継ぎメモ（自分宛て）

- Day3 で `ClassifyService` がこれらを順に呼ぶ: exactMatch（即確定なら終了）→ BM25 + Embedding → RRF → match_count 重み → 閾値判定 → 必要なら LLM
- 閾値（`THRESHOLD_CONFIDENT` / `THRESHOLD_LOW`）は環境変数で固定（MVP）。`final_score` の桁感（RRF は 1 系統 1 位で約 0.0164、両系統 1 位で約 0.0328）を見て初期値を決める
- LLM フォールバックは BYOK 未設定なら呼ばない。`ClassifyService` のコンストラクタで「BYOK 利用可否」をどう受けるか Day3-3 で決める
