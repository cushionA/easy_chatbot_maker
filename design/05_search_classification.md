# 05. 分類フローと検索戦略

## 分類フロー全体

```
[① カテゴリ選択]
   │ ボタン式、「わからない」で全件検索にフォールバック
   ↓
[② コンボボックス]
   │ カテゴリ内の問題名を入力フィルタ可能ドロップダウン
   ↓ 選択 → 確定（match_strategy=dropdown）
   │
   │ "該当なし" or "見つからない" を選んだら ↓
   ↓
[③ 自然言語入力]
   ↓
[④ キーワード完全一致]
   │ 問題名 or キーワード列との exact match
   │ ヒット → 高信頼ショートカット → 確定（match_strategy=keyword）
   ↓ ヒット無し or 曖昧
   ↓
[⑤ ハイブリッド検索]
   │ BM25 + Embedding を RRF で結合、match_count で重み付け
   │ top1 >= 閾値 → 候補提示 → 確定（match_strategy=hybrid）
   ↓ 全候補が閾値未満
   ↓
[⑥ LLM フォールバック]（BYOK 時のみ）
   │ Gemini で再分類、構造化出力
   │ → 確定（match_strategy=llm）
   ↓ それでも該当なし
   ↓
[⑦ 新規問題として自由入力]
   │ → unclassified_queue へ
   │ → 管理画面で admin がレビュー → マスタ追加 or 破棄
```

## 各段の閾値・判定基準

### ④ キーワード完全一致

- `tsvector` の websearch_to_tsquery で完全一致部分一致を判定
- 問題名 exact match → 即確定（top1のみ）
- 部分一致は信頼しすぎず、ハイブリッド検索に流す

### ⑤ ハイブリッド検索（MVP の本体）

#### 5-1. BM25（Postgres tsvector）

```sql
SELECT id, ts_rank(search_text, query) AS bm25_score
  FROM knowledge_entries
 WHERE search_text @@ websearch_to_tsquery('simple', :query)
   AND tenant_id = :tenant_id
   AND category_id = :category_id  -- 「わからない」時は省略
 ORDER BY bm25_score DESC
 LIMIT 20;
```

#### 5-2. Embedding（pgvector）

```sql
SELECT id, 1 - (embedding <=> :query_vec) AS embedding_score
  FROM knowledge_entries
 WHERE embedding IS NOT NULL
   AND embedding_model = :current_model
   AND tenant_id = :tenant_id
   AND category_id = :category_id
 ORDER BY embedding <=> :query_vec
 LIMIT 20;
```

`<=>` は pgvector のコサイン距離演算子。

#### 5-3. RRF（Reciprocal Rank Fusion）

両方のランキングを結合：

```
RRF_score(d) = Σ 1 / (k + rank_i(d))
```

- `k` は固定パラメータ（標準は60）
- `rank_i(d)` はランキング i における d の順位
- BM25 と Embedding の rank を上記式で結合

#### 5-4. match_count 重みの加味

```
final_score = RRF_score + α * log(1 + match_count)
```

- `α = 0.1` 初期値、後でチューニング
- `log` で頭打ち（match_count=1 と 100 で 100倍にならないように）

#### 5-5. 閾値判定

- `final_score` の top1 が `THRESHOLD_CONFIDENT` 以上 → 候補提示
- top1 が `THRESHOLD_LOW` 未満 → LLM フォールバックへ
- 中間 → 「候補3つ提示、確認させる」

`THRESHOLD_CONFIDENT` / `THRESHOLD_LOW` は環境変数または `app_settings` テーブルでテナント別に保持。

### ⑥ LLM フォールバック

既存 Streamlit 版の `llm_client.py` ロジックをそのまま移植：

- `classify` プロンプト + 構造化出力（Pydantic スキーマ → C# record）
- Gemini API へ JSON Schema を含む format 指定で呼出
- Pattern ID で行を引き当て

BYOK 設定がなければこの段はスキップして即 ⑦ へ。

## 3段階エスカレーション（確定後の挙動）

`knowledge_entries.auto_resolution` / `guidance_message` の有無で分岐：

| `auto_resolution` | `guidance_message` | 挙動 |
|---|---|---|
| あり | - | **自動回答完結**：解決方法を表示、「解決した？」ボタンで `inquiries.resolved` を保存、起票しない |
| なし | あり | **ガイダンス付き起票**：ガイダンス表示 → 「それでも解決しなかった場合 → フォーム → 起票」 |
| なし | なし | **直接起票**：即フォーム表示 → 起票 |

これにより：
- 単純な FAQ は自動回答完結（ヘルプデスク負荷削減）
- セルフ解決誘導を挟める（起票数削減）
- 必須起票案件は直接フォーム

「**3段階エスカレーション設計**」として面接で訴求。

## 動的フォーム生成

確定後、`knowledge_entries.required_field_codes` + 該当カテゴリの `categories.required_field_codes` を結合（順序保持・重複除去）。

各フィールドの定義は `field_definitions` から引き当て。

### 複数項目フラグ（is_multi）

`field_definitions.is_multi = true` のフィールドは UI で「行追加」ボタンを表示、値を配列として送信。

例：「添付ファイル」を3つ入力 → `[file1, file2, file3]`

### バリデーション

`field_definitions.validation_rule_id` 経由で `validation_rules` を参照、UI 入力時とサーバ送信時の両方で検証。

詳細：既存 Streamlit 版 `forms.py` の `validate_field` ロジックを C# に移植。

## 引用元ハイライト

確定した `knowledge_entries.id` を回答画面で表示：

- 問題名と該当カテゴリを表示
- マスタ管理画面への遷移リンク（admin のみ）
- 検索クエリのどの語がどのキーワード/例文にマッチしたかを反映（オプション）

## ナレッジギャップ検出

`inquiries.confidence_score` を集計：

- 閾値以下のクエリを集計 → 「**自信なく回答した問い合わせ**」リスト
- 管理画面で可視化、admin が確認 → マスタ追加候補
- `unclassified_queue` とは別軸：あちらは「分類できなかった」、こちらは「分類はしたが自信低い」

## 暗黙シグナルからのフィードバック

明示的な 👍/👎 は採用しないが、暗黙シグナルから質を計測：

| 暗黙シグナル | 解釈 |
|---|---|
| 「どれでもない」クリック | 候補が全てミスマッチ |
| 候補から1つ選んで確認画面まで進んだ | 分類成功 |
| 確認画面で「修正」を押した | 入力フォーム or 分類に問題 |
| 起票完了 | 完全成功 |
| 自動回答後の「解決した？」が「いいえ」 | `auto_resolution` の内容が不十分 |

これらすべて `inquiries` の各列に既に乗っている。新規列追加なし。

## モデル変更時のフロー

`knowledge_entries.embedding_model` で混在許容：

1. 新モデル決定 → アプリの `current_model` を切替
2. 検索時、新モデルと一致する embedding だけ Embedding 検索対象
3. 古いモデルの行は BM25 のみで検索
4. バックグラウンドで段階的に再 embedding
5. 全件移行完了したら旧モデル破棄

## 全文：ハイブリッド検索の擬似コード

```csharp
async Task<List<KnowledgeEntry>> Classify(string query, Guid tenantId, Guid? categoryId)
{
    // 1. キーワード完全一致
    var exact = await ExactMatch(query, tenantId, categoryId);
    if (exact.IsConfident) return exact.Results;

    // 2. BM25
    var bm25 = await Bm25Search(query, tenantId, categoryId, limit: 20);

    // 3. Embedding
    var queryVec = await embeddingService.EncodeAsync(query);
    var emb = await EmbeddingSearch(queryVec, tenantId, categoryId, limit: 20);

    // 4. RRF 結合
    var rrf = ReciprocalRankFusion(bm25, emb, k: 60);

    // 5. match_count 重み
    foreach (var r in rrf)
        r.Score += alpha * Math.Log(1 + r.MatchCount);

    var top = rrf.OrderByDescending(r => r.Score).Take(3).ToList();

    // 6. 閾値判定
    if (top[0].Score < THRESHOLD_LOW && byokAvailable)
        return await LlmFallback(query, tenantId, categoryId);

    return top;
}
```

## 既存 Streamlit 版からの主要差分

| 既存 | 新設計 |
|---|---|
| Embedding 単独（multilingual-e5） | BM25 + Embedding ハイブリッド (RRF) |
| なし | match_count 重み |
| LLM フォールバック（Ollama qwen3:8b） | LLM フォールバック（Gemini, BYOK） |
| Solution の有無で2分岐 | auto_resolution / guidance_message で3分岐 |
| カテゴリ→自然言語 の2段 | カテゴリ→コンボボックス→自然言語 の3段 |
| 「該当なし」 | 「新規問題として自由入力 → 未分類キュー」 |
