# Sprint 2 Day 3 作業指示書（2026-05-26）

> テーマ: **閾値判定 + LLM フォールバック + `ClassifyService` 統合**
> 完了時の状態: `ClassifyService.ClassifyAsync(query, tenantId, categoryId?)` が ④〜⑥ を 1 本につなぎ、`ClassifyResult`（候補リスト + 確定/打ち切り情報）を返す。ユニットテストが green
> 推定所要: 5〜7 時間

---

## Day3-1. 閾値判定（confident / 中間 / low）ロジック [自分]

**目的**
ハイブリッド検索の top1 スコアで分岐する閾値判定（[`05_search_classification.md:95-101`](../05_search_classification.md)）を実装する。`THRESHOLD_CONFIDENT` 以上→候補提示（確定扱い）、`THRESHOLD_LOW` 未満→ LLM フォールバックへ、中間→候補 3 つ提示して確認。分類フローの「どこで止めてどこへ送るか」を決める判断ロジックで、面接で「なぜ 1 値でなく 2 閾値の 3 段か（過検出と取りこぼしのバランス）」を語る。

**自分で書く理由**
分岐の意味（confident なら自動提示、low なら人/LLM に逃がす）は分類体験そのものの設計判断。`09_task_split.md` の「設計判断系」に当たる。閾値という数字を自分で決め、根拠を持つ必要がある。

**前提確認**
- [ ] Day2 完了（top-3 と `final_score` が出る）
- [ ] [`05_search_classification.md:95-101`](../05_search_classification.md) を読んだ
- [ ] 閾値は MVP では環境変数で固定（テナント別 `app_settings` は Sprint 2 範囲外、[`sprint2_plan.md`](../sprint2_plan.md) の残タスク）

**手順**
1. 判定を `Portfolio.Search` に純粋関数で置く（DB / 設定非依存、しきい値は**引数で受ける** — ハードコードしない）。骨格だけ示す。判定本体は自分で実装する:
   ```csharp
   namespace Portfolio.Search;

   // ここを自分で定義: 3 段のバンド（confident / 中間 / low）を表す列挙
   public enum ConfidenceBand { /* ... */ }

   public static class ThresholdJudge
   {
       // top1 の final_score でバンドを決める。confident→提示, low→LLM, middle→3件確認。
       // なぜ 1 値でなく 2 閾値の 3 段か = 過検出と取りこぼしのバランス（面接で説明する）。
       public static ConfidenceBand Judge(
           IReadOnlyList<ClassifyCandidate> ranked, double confident, double low)
       {
           // ここを自分で実装:
           //   - 候補が空なら Low（落とさない）
           //   - top1 のスコアが confident 以上 → Confident
           //   - low 未満 → Low
           //   - その間 → Middle
           throw new NotImplementedException();
       }
   }
   ```
2. 初期しきい値を決める。`final_score` は RRF（1 系統 1 位で約 0.0164、両系統 1 位で約 0.0328）+ `α*log` のオーダー。MVP の初期値はこの桁感で仮置きし、環境変数 `CLASSIFY_THRESHOLD_CONFIDENT` / `CLASSIFY_THRESHOLD_LOW` で注入。「実データを見て要再調整」とコメント
3. `Confident`/`Middle` は候補を返す、`Low` は LLM 段へ、という対応を `ClassifyService`（Day3-3）でどう使うか頭出ししておく

**完了確認**
- [ ] top1 が高い候補列 → `Confident`、空 → `Low`、中間値 → `Middle`
- [ ] しきい値を引数で受ける（ハードコードしていない）
- [ ] 初期値の根拠（RRF スコアの桁感）をコメントに残した
- [ ] `Portfolio.Search` が設定/DB に依存していない

**詰まったら**
- 常に `Low` になる → しきい値が `final_score` の桁（0.0x オーダー）と桁違い。Day2 の実スコアを 1 度プリントして合わせる
- 常に `Confident` → 同上で閾値が低すぎ

**AI 依頼テンプレ**: なし（しきい値の判断は自分）

---

## Day3-2. LLM フォールバック（既存 `llm_client.py` の Gemini 構造化出力移植）[AI 一次→自分レビュー]

**目的**
全候補が `THRESHOLD_LOW` 未満のとき、Gemini に再分類させる⑥（[`05_search_classification.md:103-111`](../05_search_classification.md)）。既存 Streamlit 版 `llm_client.py` の classify プロンプト + 構造化出力（Pydantic スキーマ）を C# に移植する。JSON Schema を含む format 指定で呼び、返った Pattern ID で行を引き当てる。一次実装は AI、**プロンプト本文とスキーマ設計は自分がレビューして握る**。

**前提確認**
- [ ] 既存 `llm_client.py` の場所を特定した（`grep -rn "def classify" .` や [`10_existing_streamlit.md`](../10_existing_streamlit.md) 参照）
- [ ] BYOK: Gemini API キーは **テナントごとに Vault 保管**、`appsettings` から読まない（CLAUDE.md / backend/CLAUDE.md Security）
- [ ] BYOK 未設定テナントではこの段を**呼ばない**（[`05_search_classification.md:111`](../05_search_classification.md)）

**手順**
1. インターフェースを自分で定義する（`Portfolio.Search/ILlmFallback.cs`。実装は AI）:
   ```csharp
   namespace Portfolio.Search;

   public interface ILlmFallback
   {
       // 候補に挙がる KnowledgeEntry の (id, name) を選択肢として渡し、
       // Gemini に最も近い 1 件（または該当なし）を構造化出力で選ばせる。
       Task<ClassifyCandidate?> ClassifyAsync(
           string query, IReadOnlyList<(Guid Id, string Name)> choices,
           CancellationToken ct = default);
   }
   ```
2. AI に下記テンプレで `Portfolio.Web/Services/GeminiLlmFallback.cs` を一次実装させる
3. **自分のレビュー責務**:
   - プロンプト本文（classify 指示）が既存 `llm_client.py` の意図を保っているか
   - 構造化出力スキーマ: 返すのは「選んだ choice の id（または null）+ 確信度」程度の最小スキーマか
   - Gemini API キーが Vault 経由で、ログに出ていないか（backend/CLAUDE.md: JWT/secret をログに出さない）
   - 返った id が `choices` に含まれない（ハルシネーション）場合に弾いて null にしているか
4. 戻り値の `Strategy` は `MatchStrategy.Llm` に

**完了確認**
- [ ] BYOK 未設定テナントでは呼ばれない（呼び出し側のガードは Day3-3 だが、本クラスは「キーが要る」前提を満たさないとき例外でなく呼ばれない設計に）
- [ ] Gemini が `choices` 外の id を返したら null（誤分類防止）
- [ ] API キーが Vault 由来でログに出ない
- [ ] プロンプト本文を自分で読み、既存 `llm_client.py` の意図と一致を確認した

**詰まったら**
- Gemini の構造化出力が崩れる → `response_mime_type: application/json` + responseSchema（JSON Schema）を format に渡す。`System.Text.Json` でデシリアライズ（Newtonsoft 禁止）
- 既存 `llm_client.py` が Ollama 前提 → モデル呼び出し層だけ Gemini に差し替え、プロンプト/スキーマの意図は流用（[`05_search_classification.md:221-231`](../05_search_classification.md) の差分表）

**AI 依頼テンプレ**
```
backend/Portfolio.Web/Services/GeminiLlmFallback.cs を作って。Portfolio.Search.ILlmFallback を実装。
参考: 既存 Streamlit 版 llm_client.py の classify プロンプトと構造化出力（場所は grep -rn "def classify" .）。
仕様（design/05_search_classification.md の ⑥ が正）:
- 入力 query と choices（(Guid Id, string Name) のリスト）を Gemini に渡し、
  最も近い 1 件の Id（該当なしは null）と確信度を JSON で返させる
- Gemini API を System.Text.Json で。response に JSON Schema(format) を指定して構造化出力を強制
- API キーはコンストラクタ注入の per-tenant Vault プロバイダ経由（appsettings から読まない、ログに出さない）
- 返った Id が choices に含まれなければ null を返す（ハルシネーション防止）
- 戻り値は ClassifyCandidate(id, name, score=確信度, MatchStrategy.Llm) または null
制約: backend/CLAUDE.md（Newtonsoft 禁止、AddHttpClient<T> 型付き、async/Async、secret をログに出さない）。
プロンプト本文は別メソッドに切り出して、私がレビューしやすい形にして。
```

---

## Day3-3. `ClassifyService` 統合（④〜⑥を 1 メソッドに）[自分]

**目的**
[`05_search_classification.md:188-219`](../05_search_classification.md) の擬似コードを実際の `ClassifyService.ClassifyAsync` に組み上げる。ExactMatch（即確定）→ BM25 + Embedding → RRF → match_count 重み → 閾値判定 → （low かつ BYOK 可なら）LLM、の制御フロー。**Sprint 2 のゴールそのもの**。これが面接デモの本体。

**自分で書く理由**
分類フロー全体の制御は本サービスの設計の顔。各段の呼び出し順・短絡（exact で即 return）・LLM へ逃がす条件は自分が説明できないといけない。`09_task_split.md` の「既存 classifier.py の C# 再設計＝設計判断は自分」に当たる。

**前提確認**
- [ ] Day3-1（閾値）・Day3-2（LLM）・Day2 の各段がそろっている
- [ ] [`05_search_classification.md:188-219`](../05_search_classification.md) の擬似コードを読んだ
- [ ] 設計擬似コードの戻り値は `List<KnowledgeEntry>` だが、実装は Day1-3 で決めた `ClassifyResult` を返す（不一致は意図的。報告参照）

**手順**
1. `Portfolio.Web/Services/ClassifyService.cs` を作る（DB を引く各 search 実装に依存するため Web 側）。コンストラクタの依存と制御フローの骨格だけ示す。各段のつなぎ込み（呼び出し順・短絡・分岐）は自分で実装する — ここが本サービスの設計の顔:
   ```csharp
   public sealed class ClassifyService(
       ExactMatchSearch exact,
       Bm25Search bm25,
       EmbeddingSearch embedding,
       ILlmFallback? llm,                 // BYOK 未設定なら null 注入
       IOptions<ClassifyOptions> options) // 閾値・α・k・current_model を束ねる
   {
       public async Task<ClassifyResult> ClassifyAsync(
           string query, Guid tenantId, Guid? categoryId, CancellationToken ct = default)
       {
           // [`05_search_classification.md:188-219`](../05_search_classification.md) の擬似コードを、この順で組み上げる。
           // 各段は Day1〜Day2 で作った型/関数をそのまま呼ぶだけ。制御フローを自分で書く:

           // ④ keyword exact: ExactMatchSearch を呼び、Name 完全一致が居たら
           //    ここを自分で実装: top-3 を Strategy=Keyword / IsConfident=true で即 return（短絡）

           // ⑤ hybrid: bm25 と embedding をそれぞれ呼んで候補列を取り、
           //    ここを自分で実装: ReciprocalRankFusion.Fuse([b, e], options.Value.RrfK) で結合
           //    → Day2-4 の経路で match_count を引いて MatchCountWeighting.Apply → top-3 整形（weighted）

           // 閾値判定:
           //    ここを自分で実装: ThresholdJudge.Judge(weighted, ThresholdConfident, ThresholdLow) でバンド算出

           // ⑥ LLM fallback: band が Low かつ llm is not null のときだけ
           //    ここを自分で実装: weighted の (id, name) を choices に渡して llm.ClassifyAsync、
           //    非 null なら Strategy=Llm / IsConfident=false で return（choices 外は LLM 側で弾く前提）

           // 既定の戻り: weighted を Strategy=Hybrid、IsConfident は band==Confident で返す
           //    ここを自分で実装
           throw new NotImplementedException();
       }
   }
   ```
2. `ClassifyOptions`（record/POCO）に `ThresholdConfident` / `ThresholdLow` / `RrfK=60` / `Alpha=0.1` / `CurrentModel` をまとめ、環境変数からバインド（`Program.cs`）。閾値は MVP 固定
3. `tenantId` は引数で受けるが **SQL には渡さない**（RLS 任せ）。引数は将来のログ/監査用と割り切り、コメントで明示
4. BYOK 可否で `ILlmFallback` を null 注入 or 実体注入する分岐を `Program.cs` に（MVP は「キーがあれば実体」程度で可）
5. DI 登録し、Sprint 1 のデバッグ画面 or 簡単な手動エンドポイントから 1 度叩いて結果を目視

**完了確認**
- [ ] Name 完全一致クエリ → `Strategy=Keyword`, `IsConfident=true` で即返る
- [ ] 言い換えクエリ → ハイブリッドで妥当な候補が top に来る
- [ ] スコアが低いクエリ → BYOK ありなら LLM 段に入る / BYOK なしならハイブリッド候補がそのまま（`IsConfident=false`）
- [ ] `categoryId` 指定で全段がカテゴリ内に絞られる
- [ ] 別テナントのデータが候補に混ざらない（RLS）

**詰まったら**
- LLM が常に呼ばれる/呼ばれない → 閾値（Day3-1）と `final_score` の桁を合わせる。`band` をログに出して切り分け
- `ILlmFallback` の null 注入で DI が壊れる → nullable で登録するか、no-op 実装（常に null を返す `NullLlmFallback`）を用意するのが安全

**AI 依頼テンプレ**: なし（統合の制御フローは自分。テストは Day3-4）

---

## Day3-4. `ClassifyService` のユニットテスト [AI]

**目的**
各段のフェイク実装を差し込んで `ClassifyService` の制御フロー（短絡・閾値分岐・LLM 条件）を検証する。SQL を本物で叩く統合テストは別途（`[Trait("Category","DB")]`、Testcontainers が入ったら）。ここは**ロジック分岐のユニットテスト**で、AI にケースを書かせる。

**前提確認**
- [ ] Day3-3 完了
- [ ] テストプロジェクトは `backend/Portfolio.Web.Tests/`（xUnit）
- [ ] `ICandidateSearch` / `ILlmFallback` がインターフェースなのでフェイクを差せる（Day1-3 / Day3-2 の設計が効く）

**手順**
1. 自分でテストケース（漏れたら困る分岐）を列挙する — ここが自分の責務:
   - exact で Name 完全一致 → 即 `Keyword` 確定、BM25/Embedding が呼ばれない
   - hybrid top1 ≥ confident → `IsConfident=true`、LLM 呼ばれない
   - hybrid top1 < low かつ BYOK あり → LLM が呼ばれ、その結果が返る
   - hybrid top1 < low かつ BYOK なし（`llm=null`）→ ハイブリッド候補をそのまま返す
   - 候補 0 件 → `Low` 扱いで落ちない
   - RRF: 両系統 1 位の文書が片系統のみ 1 位より上（`ReciprocalRankFusion.Fuse` 単体）
   - match_count: 重みが RRF 順位を覆さない範囲（`MatchCountWeighting.Apply` 単体）
2. AI に下記テンプレで `ClassifyServiceTests.cs` と純粋関数のテストを書かせる
3. green を確認し、**一度わざと閾値分岐を壊して red になる**ことを確認（テストが効いている証拠）

**完了確認**
- [ ] 上記ケースが全て green
- [ ] `ReciprocalRankFusion` / `MatchCountWeighting` / `ThresholdJudge` の純粋関数テストがある
- [ ] `dotnet test Portfolio.sln --configuration Release` が green
- [ ] わざと壊すと red になることを 1 度確認した

**AI 依頼テンプレ**
```
backend/Portfolio.Web.Tests/ClassifyServiceTests.cs を xUnit で書いて。
ClassifyService の各段（ExactMatchSearch / Bm25Search / EmbeddingSearch / ILlmFallback）を
フェイク（テスト用のスタブ実装）に差し替えて、以下の分岐を検証:
1. exact で Name 完全一致 → Strategy=Keyword, IsConfident=true、bm25/embedding のフェイクが呼ばれない
2. hybrid top1 >= confident → IsConfident=true、llm 呼ばれない
3. hybrid top1 < low かつ llm あり → llm が呼ばれその結果が返る（Strategy=Llm）
4. hybrid top1 < low かつ llm=null → ハイブリッド候補がそのまま（IsConfident=false）
5. 候補 0 件で例外を投げない
さらに純粋関数の単体テスト:
- ReciprocalRankFusion.Fuse: 両ランキング 1 位の文書が片方のみ 1 位より上に来る
- MatchCountWeighting.Apply: match_count=0 で素のスコア、大でも RRF 順位を覆さない
- ThresholdJudge.Judge: confident/middle/low/空 の 4 分岐
制約: backend/CLAUDE.md（1 production class = 1 test class、async/Async、WebApplicationFactory は不要、純粋なロジックテスト）。
DB を叩くテストは書かない（それは [Trait("Category","DB")] で別途）。
```

---

## Day 3 終了チェックリスト

- [ ] `ThresholdJudge.Judge` が confident/middle/low を返す（しきい値は引数）
- [ ] `GeminiLlmFallback` が構造化出力で 1 件選び、choices 外は null（BYOK なしは呼ばれない）
- [ ] `ClassifyService.ClassifyAsync(query, tenantId, categoryId?)` が ④〜⑥ をつなぎ `ClassifyResult` を返す
- [ ] ユニットテストが green、わざと壊すと red を確認した
- [ ] `dotnet build` warning 0 / `dotnet test` green
- [ ] **Sprint 2 ゴール達成**: 自然文 + tenantId + categoryId? で候補リストが返る

## Sprint 3 への引き継ぎメモ（自分宛て）

- `ClassifyService` は候補を返すところまで。確定後の 3 段階エスカレーション（auto_resolution / guidance_message / 直接起票）と動的フォーム・起票は Sprint 3（[`06_destinations.md`](../06_destinations.md)）
- 閾値・α は環境変数で固定中。実データで要チューニング → テナント別 `app_settings` 化は後続
- LLM フォールバックの Vault 連携（per-tenant Gemini キー）が Sprint 1 で未完なら、Sprint 3 着手前に詰める
- `match_strategy` は `inquiries` 保存時の列に対応（Sprint 3 で起票ログに記録）
