# Sprint 2 Day 2 作業指示書（2026-05-23）

> テーマ: **ハイブリッド検索（BM25 + Embedding を 1 本のランキングに束ねる）**
> 完了時の状態: BM25 検索と Embedding 検索がそれぞれ候補を返し、RRF で 1 本のランキングに結合され、`match_count` 重みが加味された top-N が出る
> 推定所要: 5〜7 時間

---

## Day2-1. BM25 検索（tsvector / ts_rank）SQL [AI]

**目的**
分類フロー⑤の片肺、BM25 側（[`05_search_classification.md:47-57`](../05_search_classification.md)）を実装する。Day1-2 で確認した `search_text` と `ts_rank` を使い、`ICandidateSearch` 実装として候補 20 件を返す。SQL の型は Day1-2 で自分が手で確認済みなので、C# 実装は AI に複製させる。

**前提確認**
- [ ] Day1-2 で `ts_rank` クエリが手で動いた
- [ ] Day1-3 の `ICandidateSearch` / `ClassifyCandidate` がある
- [ ] EF Core では `ts_rank` / `@@` を LINQ で書けないため `FromSql`（パラメータ化）を使うと理解した（backend/CLAUDE.md: 生 SQL は文字列連結禁止・必ずパラメータ化）

**手順**
1. AI に下記テンプレで `Portfolio.Web/Services/Bm25Search.cs` を生成させる
2. SQL は設計書 [`05_search_classification.md:49-57`](../05_search_classification.md) の形。`tenant_id` は **WHERE に書かない**（RLS 任せ）。`category_id` は null のとき省略
3. レビュー観点: ① パラメータ化されているか（`{0}` / `FromSql` 補間で Npgsql パラメータになっているか、生連結でないか）② `ts_rank` のスコアを `ClassifyCandidate.Score` に入れ `Strategy=Hybrid` にしているか ③ `LIMIT 20`

**完了確認**
- [ ] Day1-2 で叩いた語で BM25 候補がスコア降順 20 件以内で返る
- [ ] `categoryId` 指定でカテゴリ内に絞られ、null で全件対象になる
- [ ] EF が出した SQL（ログ）に `tenant_id` が無くても他テナント分が漏れない
- [ ] 生成 SQL がパラメータ化されている（`query` がそのまま埋め込まれていない）

**詰まったら**
- `FromSql` が型不一致で落ちる → `KnowledgeEntry` 全列を SELECT する形にするか、`[Keyless]` の射影 record を別途用意する。`ClassifyCandidate` には `id` / `name` / `score` の 3 列だけ取れれば十分
- 0 件 → Day1-2 の手動 SQL と同じ語・同じ構成（`simple`）か確認

**AI 依頼テンプレ**
```
backend/Portfolio.Web/Services/Bm25Search.cs を作って。Portfolio.Search.ICandidateSearch を実装する。
仕様（design/05_search_classification.md の 5-1 が正）:
- AppDbContext を DI で受ける（primary constructor）
- FromSql でパラメータ化した生 SQL を発行（文字列連結は禁止、必ず Npgsql パラメータ）
  SELECT id, name, ts_rank(search_text, websearch_to_tsquery('simple', @query)) AS score
    FROM knowledge_entries
   WHERE search_text @@ websearch_to_tsquery('simple', @query)
     [AND category_id = @categoryId]   -- categoryId が null なら省略
   ORDER BY score DESC
   LIMIT @limit
- tenant_id は WHERE に書かない（RLS が SET LOCAL で強制する。design/04 参照）
- 各行を ClassifyCandidate(id, name, score, MatchStrategy.Hybrid) に詰めて返す
- AsNoTracking 相当（読み取り専用）。CancellationToken を最後の引数に
制約: backend/CLAUDE.md（nullable enable, TreatWarningsAsErrors, sealed, async/Async サフィックス）に従う。
Program.cs に AddScoped で DI 登録も足して。
```

---

## Day2-2. Embedding 検索（pgvector コサイン距離）SQL [AI]

**目的**
⑤のもう片肺、Embedding 側（[`05_search_classification.md:59-72`](../05_search_classification.md)）。Day1-5 で整理した `EmbedMode.Query` で分類クエリをベクトル化し、pgvector の `<=>`（コサイン距離）で近傍 20 件を返す。BM25 と同じ `ICandidateSearch` 形なので、Day2-1 のパターン複製として AI に出す。

**前提確認**
- [ ] Day1-5 完了（`EmbedAsync(text, EmbedMode.Query)` が使える）
- [ ] Day2-1 のパターン（`FromSql` + RLS 任せ）を踏襲する
- [ ] Knowledge に `embedding` 列が埋まっている行があるか確認（Day1-1 では埋めていない → このタスクの前に数件 `passage` で embedding を入れる必要がある。下記手順1）

**手順**
1. 検証データを用意する: 自テナントの Knowledge 数件に対し `EmbedAsync(name, EmbedMode.Passage)` で算出したベクトルを `embedding` 列に、使用モデル名を `embedding_model` 列に入れる（小さな一回限りのスクリプト or デバッグ画面ボタンで可）。**ここは `passage`**
2. `current_model` の供給元を決める: MVP は `appsettings` ではなく環境変数 or 定数で `intfloat/multilingual-e5-base` を 1 箇所に。`embedding_model = @currentModel` でフィルタ（モデル混在対応 [`05_search_classification.md:178-186`](../05_search_classification.md)）
3. AI に下記テンプレで `Portfolio.Web/Services/EmbeddingSearch.cs` を生成させる
4. レビュー観点: ① クエリのベクトル化が `EmbedMode.Query` か（`passage` になっていないか — recall 劣化の罠）② `<=>` 距離を `1 - distance` で類似度スコアに直しているか ③ `embedding IS NOT NULL AND embedding_model = @currentModel`

**完了確認**
- [ ] embedding を入れた Knowledge に対し、意味が近い別表現のクエリで上位に出る（exact では出ない語で試す）
- [ ] `embedding_model` が `current_model` と違う行は除外される
- [ ] クエリ側が `EmbedMode.Query` でベクトル化されている（コード確認）
- [ ] `categoryId` 指定で絞られる

**詰まったら**
- `<=>` でビルド/実行エラー → LINQ ではなく `FromSql`。Vector パラメータは Npgsql の `Vector` 型でバインド（`Pgvector` パッケージ）
- 全部 0 件 → `embedding IS NOT NULL` の行が無い（手順1 未実施）か、`embedding_model` フィルタで全除外。まず WHERE を緩めて切り分け
- 結果がランダム → 距離の符号。`<=>` は距離（小さいほど近い）。`ORDER BY embedding <=> @vec` 昇順、スコアは `1 - 距離`

**AI 依頼テンプレ**
```
backend/Portfolio.Web/Services/EmbeddingSearch.cs を作って。Portfolio.Search.ICandidateSearch を実装。
Day2-1 の Bm25Search.cs と同じ構造で、検索手段だけ pgvector に変える。
仕様（design/05_search_classification.md の 5-2 が正）:
- コンストラクタで AppDbContext と IEmbeddingClient を受ける
- まず var vec = await embeddingClient.EmbedAsync(query, EmbedMode.Query, ct);  ← 必ず Query モード
- FromSql でパラメータ化した生 SQL:
  SELECT id, name, 1 - (embedding <=> @vec) AS score
    FROM knowledge_entries
   WHERE embedding IS NOT NULL
     AND embedding_model = @currentModel
     [AND category_id = @categoryId]
   ORDER BY embedding <=> @vec
   LIMIT @limit
- tenant_id は WHERE に書かない（RLS 任せ）
- @vec は Pgvector の Vector 型でバインド。@currentModel は "intfloat/multilingual-e5-base"（定数 or 設定から）
- 各行を ClassifyCandidate(id, name, score, MatchStrategy.Hybrid) に
制約: backend/CLAUDE.md に従う。Program.cs に DI 登録も。
注意: クエリ側を passage モードで埋め込まないこと（recall が静かに落ちる。embedding/CLAUDE.md）。
```

---

## Day2-3. RRF（Reciprocal Rank Fusion）結合の実装 [自分]

**目的**
BM25 と Embedding という **スケールの違う 2 つのスコア**を、スコアそのものではなく**順位**で束ねる RRF（[`05_search_classification.md:74-84`](../05_search_classification.md)）を実装する。`RRF_score(d) = Σ 1/(k + rank_i(d))`。これがハイブリッド検索の心臓で、面接の主役。`Portfolio.Search` 側に純粋関数として置く（DB 非依存 → テストしやすい）。

**自分で書く理由**
`09_task_split.md:16,25` で「RRF + match_count 重み付け式」は明示的に自分が書く領域。スコアでなく順位を使う理由（BM25 の `ts_rank` と Embedding の類似度はスケールが違い、足し算できない）を自分の言葉で説明できる必要がある。ここを AI に書かせると面接で詰む。

**前提確認**
- [ ] Day2-1 / Day2-2 で 2 系統の候補リストが取れる
- [ ] [`05_search_classification.md:74-84`](../05_search_classification.md)（RRF の式と `k=60`）を読んだ
- [ ] 「score ではなく rank（順位）を式に入れる」ことを理解した（つまづき表の典型ミス）

**手順**
1. `Portfolio.Search/ReciprocalRankFusion.cs` に純粋関数として書く（`AppDbContext` 非依存）:
   ```csharp
   namespace Portfolio.Search;

   public static class ReciprocalRankFusion
   {
       // 各ランキング（順位順に並んだ候補列）を RRF で 1 本に束ねる。
       // score は使わず順位だけ使う（BM25 と Embedding はスケールが違うため）。
       public static IReadOnlyList<ClassifyCandidate> Fuse(
           IReadOnlyList<IReadOnlyList<ClassifyCandidate>> rankings, int k = 60)
       {
           var acc = new Dictionary<Guid, (string Name, double Score)>();
           foreach (var ranking in rankings)
           {
               for (var rank = 0; rank < ranking.Count; rank++)   // rank は 0 始まり → +1 で 1 位
               {
                   var c = ranking[rank];
                   var contrib = 1.0 / (k + rank + 1);
                   if (acc.TryGetValue(c.KnowledgeEntryId, out var cur))
                       acc[c.KnowledgeEntryId] = (cur.Name, cur.Score + contrib);
                   else
                       acc[c.KnowledgeEntryId] = (c.Name, contrib);
               }
           }
           return acc
               .Select(kv => new ClassifyCandidate(kv.Key, kv.Value.Name, kv.Value.Score, MatchStrategy.Hybrid))
               .OrderByDescending(c => c.Score)
               .ToList();
       }
   }
   ```
2. 入力は「順位順に並んだ候補列」。Day2-1 / 2-2 はすでに `ORDER BY ... DESC/ASC` 済みなので、リストの index がそのまま rank になる
3. `k=60` は標準値。なぜ 60 かを 1 行コメント（外れ値の影響を薄め、上位の差を残す経験則）

**完了確認**
- [ ] 両ランキングで 1 位の文書が、片方だけ 1 位の文書より上に来る（簡単な手計算と一致）
- [ ] 片方にしか出ない文書も結合結果に含まれる（和集合）
- [ ] スコアではなく順位を使っている（BM25 のスコアを 100 倍しても結果順が変わらないことで確認）
- [ ] `Portfolio.Search` が `AppDbContext` に依存していない（純粋関数）

**詰まったら**
- 結果が BM25 とほぼ同じ → score を足してしまっている。rank（index+1）を使う
- 同点が多い → `k` が大きすぎ or 候補が少なすぎ。MVP の小データでは正常。`OrderByDescending` の安定性は気にしない

**AI 依頼テンプレ**: なし（式の中核は自分で書く。テストは Day3-4 で AI に出す）

---

## Day2-4. match_count 重み付け式と top-N 整形 [自分]

**目的**
RRF スコアに「過去によくマッチした問題ほど少し優遇する」`match_count` 重み（[`05_search_classification.md:86-93`](../05_search_classification.md)）を加える。`final_score = RRF_score + α * log(1 + match_count)`、`α=0.1`。`log` で頭打ちにする理由（match_count=1 と 100 で 100 倍にしない）を自分で握る。最後に top-3 に整形して `ClassifyResult` 手前まで作る。

**自分で書く理由**
`09_task_split.md` で重み付け式は自分の領域。`α` と `log` の選択は分類品質のチューニングポイントで、面接で「なぜ線形でなく対数か」を説明する。

**前提確認**
- [ ] Day2-3 の RRF が動く
- [ ] `KnowledgeEntry.MatchCount`（`AppDbContext` 経由で取得可能、`Data/Entities/KnowledgeEntry.cs:18`）の存在を確認した
- [ ] `ClassifyCandidate` には現状 match_count が無い → 重み加算のために候補に match_count を持たせるか、加算を別ステップで行うか判断する

**手順**
1. `match_count` を候補に渡す経路を決める。**RRF は DB 非依存に保ちたい**ので、match_count 加算は Web 側（DB を引ける層）で行う設計に倒す。Day2-1/2-2 の候補に `MatchCount` を載せるか、結合後に `KnowledgeEntryId` で引き直す。MVP は「結合後に id 群で `match_count` を 1 クエリ取得 → 加算」がシンプル
2. `Portfolio.Search` に重み式だけ純粋関数で置く（テスト容易性）:
   ```csharp
   namespace Portfolio.Search;

   public static class MatchCountWeighting
   {
       public const double DefaultAlpha = 0.1;

       // final = rrf + α * log(1 + matchCount)。log で頭打ち（1 と 100 で 100 倍にしない）。
       public static double Apply(double rrfScore, int matchCount, double alpha = DefaultAlpha)
           => rrfScore + alpha * Math.Log(1 + matchCount);
   }
   ```
3. 結合後の候補に `Apply` を適用し、`OrderByDescending(Score).Take(3)` で top-3 に整形（[`05_search_classification.md:211`](../05_search_classification.md)）
4. `α` を定数 1 箇所に。閾値同様「将来テナント別チューニング」は Sprint 2 範囲外とメモ

**完了確認**
- [ ] match_count が大きい候補がわずかに上がる（差が `α*log` の桁＝ RRF スコアを逆転しない程度）であることを手計算で確認
- [ ] match_count=0 の候補は `log(1)=0` で素の RRF スコアのまま
- [ ] top-3 に整形され、各候補に `final_score` が入る
- [ ] `α` と `log` の選択理由をコメントに残した

**詰まったら**
- match_count が候補を支配する → `α` が大きすぎる。0.1 から動かさない（RRF を覆さないのが狙い）
- `MatchCount` をどこで引くか迷う → 結合後の id 群で `db.KnowledgeEntries.Where(k => ids.Contains(k.Id)).Select(k => new {k.Id, k.MatchCount})` を 1 回。N+1 にしない

**AI 依頼テンプレ**: なし（式は自分。match_count を引く DB クエリ部分だけ AI に出すなら下記）
```
RRF 結合後の ClassifyCandidate のリスト（KnowledgeEntryId を持つ）を受け取り、
AppDbContext で対応する knowledge_entries.match_count を 1 クエリ（ids.Contains で IN 句）まとめ取得し、
Portfolio.Search.MatchCountWeighting.Apply(score, matchCount) でスコアを更新して
OrderByDescending(Score).Take(3) を返すヘルパーを Portfolio.Web 側に書いて。N+1 にしないこと。
```

---

## Day 2 終了チェックリスト

- [ ] `Bm25Search` が `ICandidateSearch` 実装として候補を返す（パラメータ化 SQL、RLS 任せ）
- [ ] `EmbeddingSearch` が `EmbedMode.Query` でベクトル化し pgvector で近傍を返す
- [ ] `ReciprocalRankFusion.Fuse` が順位ベースで 2 系統を 1 本に束ねる（DB 非依存）
- [ ] `MatchCountWeighting.Apply` で `α*log(1+match_count)` が加味され top-3 が出る
- [ ] スコアでなく順位を使っていることを「BM25 スコアを定数倍しても順位不変」で確認した
- [ ] `dotnet build Portfolio.sln --configuration Release` が warning 0

## Day 3 への引き継ぎメモ（自分宛て）

- Day3 で `ClassifyService` がこれらを順に呼ぶ: ExactMatch（即確定なら終了）→ BM25 + Embedding → RRF → match_count 重み → 閾値判定 → 必要なら LLM
- 閾値（`THRESHOLD_CONFIDENT` / `THRESHOLD_LOW`）は環境変数で固定（MVP）。`final_score` の桁感（RRF は 1/(60+1)≒0.016 オーダー）を見て初期値を決める
- LLM フォールバックは BYOK 未設定なら呼ばない。`ClassifyService` のコンストラクタで「BYOK 利用可否」をどう受けるか Day3-3 で決める
