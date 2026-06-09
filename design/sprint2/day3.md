# Sprint 2 Day 3 作業指示書（2026-05-26）

> テーマ: **閾値判定 + LLM フォールバック + `ClassifyService` 統合**
> 完了時の状態: `classifyService.classify(query, tenantId, categoryId?)` が ④〜⑥ を 1 本につなぎ、`ClassifyResult`（候補リスト + 確定/打ち切り情報）を返す。ユニットテストが green
> 推定所要: 5〜7 時間

---

## Day3-1. 閾値判定（confident / 中間 / low）ロジック [自分] [BE]

**目的**
ハイブリッド検索の top1 スコアで分岐する閾値判定（[`05_search_classification.md:95-101`](../05_search_classification.md)）を実装する。`THRESHOLD_CONFIDENT` 以上→候補提示（確定扱い）、`THRESHOLD_LOW` 未満→ LLM フォールバックへ、中間→候補 3 つ提示して確認。分類フローの「どこで止めてどこへ送るか」を決める判断ロジックで、面接で「なぜ 1 値でなく 2 閾値の 3 段か（過検出と取りこぼしのバランス）」を語る。

**自分で書く理由**
分岐の意味（confident なら自動提示、low なら人/LLM に逃がす）は分類体験そのものの設計判断。`09_task_split.md` の「設計判断系」に当たる。閾値という数字を自分で決め、根拠を持つ必要がある。

**前提確認**
- [ ] Day2 完了（top-3 と `finalScore` が出る）
- [ ] [`05_search_classification.md:95-101`](../05_search_classification.md) を読んだ
- [ ] 閾値は MVP では環境変数で固定（テナント別チューニングは Sprint 2 範囲外、[`sprint2_plan.md`](../sprint2_plan.md) の残タスク）

**手順**
1. 判定を `apps/api/src/search/thresholdJudge.ts` に純粋関数で置く（設定/ES 非依存、しきい値は**引数で受ける** — ハードコードしない）。骨格だけ示す。判定本体は自分で実装する:
   ```typescript
   // ここを自分で定義: 3 段のバンド（confident / middle / low）を表す union
   export type ConfidenceBand = /* ... */;

   // top1 の finalScore でバンドを決める。confident→提示, low→LLM, middle→3件確認。
   // なぜ 1 値でなく 2 閾値の 3 段か = 過検出と取りこぼしのバランス（面接で説明する）。
   export function judge(
     ranked: readonly import('./types.js').ClassifyCandidate[],
     confident: number,
     low: number
   ): ConfidenceBand {
     // ここを自分で実装:
     //   - 候補が空なら 'low'（落とさない）
     //   - top1 のスコアが confident 以上 → 'confident'
     //   - low 未満 → 'low'
     //   - その間 → 'middle'
     throw new Error('NotImplemented');
   }
   ```
2. 初期しきい値を決める。`finalScore` は RRF（1 系統 1 位で約 0.0164、両系統 1 位で約 0.0328）+ `α*log` のオーダー。MVP の初期値はこの桁感で仮置きし、環境変数 `CLASSIFY_THRESHOLD_CONFIDENT` / `CLASSIFY_THRESHOLD_LOW` で注入。「実データを見て要再調整」とコメント
3. `'confident'`/`'middle'` は候補を返す、`'low'` は LLM 段へ、という対応を `ClassifyService`（Day3-3）でどう使うか頭出ししておく

**完了確認**
- [ ] top1 が高い候補列 → `'confident'`、空 → `'low'`、中間値 → `'middle'`
- [ ] しきい値を引数で受ける（ハードコードしていない）
- [ ] 初期値の根拠（RRF スコアの桁感）をコメントに残した
- [ ] `apps/api/src/search/thresholdJudge.ts` が設定/ES に依存していない

**詰まったら**
- 常に `'low'` になる → しきい値が `finalScore` の桁（0.0x オーダー）と桁違い。Day2 の実スコアをログに出して合わせる
- 常に `'confident'` → 同上で閾値が低すぎ

**AI 依頼テンプレ**: なし（しきい値の判断は自分）

---

## Day3-2. LLM フォールバック（既存 `llm_client.py` の Gemini 構造化出力移植）[AI 一次→自分レビュー] [BE] [ML]

**目的**
全候補が `THRESHOLD_LOW` 未満のとき、Gemini に再分類させる⑥（[`05_search_classification.md:103-111`](../05_search_classification.md)）。既存 Streamlit 版 `llm_client.py` の classify プロンプト + 構造化出力（Pydantic スキーマ）を TypeScript に移植する。JSON Schema を含む format 指定で呼び、返った id で候補を引き当てる。一次実装は AI、**プロンプト本文とスキーマ設計は自分がレビューして握る**。

**前提確認**
- [ ] 既存 `llm_client.py` の場所を特定した（`grep -rn "def classify" .` や [`10_existing_streamlit.md`](../10_existing_streamlit.md) 参照）
- [ ] BYOK: Gemini API キーは **テナントごとに Secret Manager 保管**、環境変数やコードに直書きしない（CLAUDE.md / Security）
- [ ] BYOK 未設定テナントではこの段を**呼ばない**（[`05_search_classification.md:111`](../05_search_classification.md)）

**手順**
1. インターフェースを自分で定義する（`apps/api/src/search/llmFallback.ts`。実装は AI）:
   ```typescript
   import type { ClassifyCandidate } from './types.js';

   export interface ILlmFallback {
     // 候補に挙がる KnowledgeEntry の (id, name) を選択肢として渡し、
     // Gemini に最も近い 1 件（または該当なし）を構造化出力で選ばせる。
     classify(
       query: string,
       choices: ReadonlyArray<{ id: string; name: string }>,
       signal?: AbortSignal
     ): Promise<ClassifyCandidate | null>;
   }
   ```
2. AI に下記テンプレで `apps/api/src/services/geminiLlmFallback.ts` を一次実装させる
3. **自分のレビュー責務**:
   - プロンプト本文（classify 指示）が既存 `llm_client.py` の意図を保っているか
   - 構造化出力スキーマ: 返すのは「選んだ choice の id（または null）+ 確信度」程度の最小スキーマか
   - Gemini API キーが Secret Manager 経由で、ログに出ていないか（secret をログに出さない）
   - 返った id が `choices` に含まれない（ハルシネーション）場合に弾いて null にしているか
   - zod 等で戻り値を検証しているか（`llm_client.py` の Pydantic 相当）
4. 戻り値の `strategy` は `'llm'` に

**完了確認**
- [ ] BYOK 未設定テナントでは呼ばれない（呼び出し側のガードは Day3-3 だが、本クラスは「キーが要る」前提を満たさないとき例外でなく呼ばれない設計に）
- [ ] Gemini が `choices` 外の id を返したら null（誤分類防止）
- [ ] API キーが Secret Manager 由来でログに出ない
- [ ] プロンプト本文を自分で読み、既存 `llm_client.py` の意図と一致を確認した

**詰まったら**
- Gemini の構造化出力が崩れる → `response_mime_type: 'application/json'` + `responseSchema`（JSON Schema）を format に渡す。zod の `safeParse` でデシリアライズと検証を同時に行う
- 既存 `llm_client.py` が Ollama 前提 → モデル呼び出し層だけ Gemini に差し替え、プロンプト/スキーマの意図は流用（[`05_search_classification.md:221-231`](../05_search_classification.md) の差分表）

**AI 依頼テンプレ**
```
apps/api/src/services/geminiLlmFallback.ts を作って。ILlmFallback を実装。
参考: 既存 Streamlit 版 llm_client.py の classify プロンプトと構造化出力（場所は grep -rn "def classify" .）。
仕様（design/05_search_classification.md の ⑥ が正）:
- 入力 query と choices（{ id: string; name: string }[]）を Gemini に渡し、
  最も近い 1 件の id（該当なしは null）と確信度を JSON で返させる
- Gemini REST API を fetch で呼ぶ。responseSchema に JSON Schema を指定して構造化出力を強制
- 戻り値を zod スキーマで safeParse して型安全に扱う
- API キーはコンストラクタ注入の per-tenant Secret Manager プロバイダ経由（直書き禁止、ログに出さない）
- 返った id が choices に含まれなければ null を返す（ハルシネーション防止）
- 戻り値は ClassifyCandidate{ id, name, score: 確信度, strategy: 'llm' } または null
制約: TypeScript strict、async/await、secret をログに出さない。
プロンプト本文は別関数に切り出して、私がレビューしやすい形にして。
```

---

## Day3-3. `ClassifyService` 統合（④〜⑥を 1 メソッドに）[自分] [BE]

**目的**
[`05_search_classification.md:188-219`](../05_search_classification.md) の擬似コードを実際の `ClassifyService.classify` に組み上げる。exactMatch（即確定）→ BM25 + Embedding → RRF → match_count 重み → 閾値判定 → （low かつ BYOK 可なら）LLM、の制御フロー。**Sprint 2 のゴールそのもの**。これが面接デモの本体。

**自分で書く理由**
分類フロー全体の制御は本サービスの設計の顔。各段の呼び出し順・短絡（exact で即 return）・LLM へ逃がす条件は自分が説明できないといけない。`09_task_split.md` の「既存 classifier.py の TypeScript 再設計＝設計判断は自分」に当たる。

**前提確認**
- [ ] Day3-1（閾値）・Day3-2（LLM）・Day2 の各段がそろっている
- [ ] [`05_search_classification.md:188-219`](../05_search_classification.md) の擬似コードを読んだ
- [ ] 設計擬似コードの戻り値は `KnowledgeEntry[]` だが、実装は Day1-3 で決めた `ClassifyResult` を返す（不一致は意図的。報告参照）

**手順**
1. `apps/api/src/search/classifyService.ts` を作る（ES を引く各 search 実装に依存するため search/ 内）。コンストラクタの依存と制御フローの骨格だけ示す。各段のつなぎ込み（呼び出し順・短絡・分岐）は自分で実装する — ここが本サービスの設計の顔:
   ```typescript
   import type { ICandidateSearch, ILlmFallback } from './interfaces.js';
   import type { ClassifyOptions } from './options.js';
   import type { ClassifyResult } from './types.js';
   import { fuse } from './rrf.js';
   import { applyMatchCount } from './matchCountWeighting.js';
   import { judge } from './thresholdJudge.js';

   export class ClassifyService {
     constructor(
       private readonly exact: ICandidateSearch,
       private readonly bm25: ICandidateSearch,
       private readonly embedding: ICandidateSearch,
       private readonly llm: ILlmFallback | null,  // BYOK 未設定なら null 注入
       private readonly options: ClassifyOptions    // 閾値・α・k・currentModel を束ねる
     ) {}

     async classify(
       query: string,
       tenantId: string,
       categoryId?: string,
       signal?: AbortSignal
     ): Promise<ClassifyResult> {
       // [`05_search_classification.md:188-219`](../05_search_classification.md) の擬似コードを、この順で組み上げる。
       // 各段は Day1〜Day2 で作った型/関数をそのまま呼ぶだけ。制御フローを自分で書く:

       // ④ keyword exact: ExactMatchSearch を呼び、name 完全一致が居たら
       //    ここを自分で実装: top-3 を strategy='keyword' / isConfident=true で即 return（短絡）

       // ⑤ hybrid: bm25 と embedding をそれぞれ呼んで候補列を取り、
       //    ここを自分で実装: fuse([b, e], options.rrfK) で結合
       //    → match_count を引いて applyMatchCount → top-3 整形（weighted）

       // 閾値判定:
       //    ここを自分で実装: judge(weighted, options.thresholdConfident, options.thresholdLow) でバンド算出

       // ⑥ LLM fallback: band が 'low' かつ this.llm !== null のときだけ
       //    ここを自分で実装: weighted の { id, name } を choices に渡して llm.classify、
       //    非 null なら strategy='llm' / isConfident=false で return（choices 外は LLM 側で弾く前提）

       // 既定の戻り: weighted を strategy='hybrid'、isConfident は band==='confident' で返す
       //    ここを自分で実装
       throw new Error('NotImplemented');
     }
   }
   ```
2. `ClassifyOptions`（型）に `thresholdConfident` / `thresholdLow` / `rrfK=60` / `alpha=0.1` / `currentModel` をまとめ、環境変数からバインド（起動時）。閾値は MVP 固定
3. `tenantId` は引数で受けるが **各検索段に渡す**（ES の `filter: { term: { tenant_id } }` 必須。04_security_multitenant.md）。コメントで明示
4. BYOK 可否で `ILlmFallback` を null 注入 or 実体注入する分岐を `container.ts` に（MVP は「キーがあれば実体」程度で可）
5. DI 登録し、Sprint 1 のデバッグ画面 or 簡単なエンドポイントから 1 度叩いて結果を目視

**完了確認**
- [ ] name 完全一致クエリ → `strategy: 'keyword'`, `isConfident: true` で即返る
- [ ] 言い換えクエリ → ハイブリッドで妥当な候補が top に来る
- [ ] スコアが低いクエリ → BYOK ありなら LLM 段に入る / BYOK なしならハイブリッド候補がそのまま（`isConfident: false`）
- [ ] `categoryId` 指定で全段がカテゴリ内に絞られる
- [ ] 別テナントのデータが候補に混ざらない（ES filter）

**詰まったら**
- LLM が常に呼ばれる/呼ばれない → 閾値（Day3-1）と `finalScore` の桁を合わせる。`band` をログに出して切り分け
- `ILlmFallback` の null 注入で型エラーになる → `ILlmFallback | null` を明示的に型付けするか、常に null を返す `NullLlmFallback` を用意するのが安全

**AI 依頼テンプレ**: なし（統合の制御フローは自分。テストは Day3-4）

---

## Day3-4. `ClassifyService` のユニットテスト [AI] [TEST]

**目的**
各段のフェイク実装を差し込んで `ClassifyService` の制御フロー（短絡・閾値分岐・LLM 条件）を検証する。ES を本物で叩く統合テストは別途。ここは**ロジック分岐のユニットテスト**で、AI にケースを書かせる。

**前提確認**
- [ ] Day3-3 完了
- [ ] テストフレームワークは `Vitest`（または `Jest`）。`apps/api/` の既存テスト設定に揃える
- [ ] `ICandidateSearch` / `ILlmFallback` がインターフェースなのでフェイクを差せる（Day1-3 / Day3-2 の設計が効く）

**手順**
1. 自分でテストケース（漏れたら困る分岐）を列挙する — ここが自分の責務:
   - exact で name 完全一致 → 即 `'keyword'` 確定、BM25/Embedding が呼ばれない
   - hybrid top1 ≥ confident → `isConfident: true`、LLM 呼ばれない
   - hybrid top1 < low かつ BYOK あり → LLM が呼ばれ、その結果が返る
   - hybrid top1 < low かつ BYOK なし（`llm=null`）→ ハイブリッド候補をそのまま返す
   - 候補 0 件 → `'low'` 扱いで例外を投げない
   - RRF: 両系統 1 位の文書が片系統のみ 1 位より上（`fuse` 単体）
   - match_count: 重みが RRF 順位を覆さない範囲（`applyMatchCount` 単体）
2. AI に下記テンプレで `apps/api/src/search/__tests__/classifyService.test.ts` と純粋関数のテストを書かせる
3. green を確認し、**一度わざと閾値分岐を壊して red になる**ことを確認（テストが効いている証拠）

**完了確認**
- [ ] 上記ケースが全て green
- [ ] `fuse` / `applyMatchCount` / `judge` の純粋関数テストがある
- [ ] `pnpm test` が green
- [ ] わざと壊すと red になることを 1 度確認した

**AI 依頼テンプレ**
```
apps/api/src/search/__tests__/classifyService.test.ts を Vitest で書いて。
ClassifyService の各段（ICandidateSearch x3 / ILlmFallback）を
フェイク（テスト用のスタブ実装）に差し替えて、以下の分岐を検証:
1. exact で name 完全一致 → strategy: 'keyword', isConfident: true、bm25/embedding のフェイクが呼ばれない
2. hybrid top1 >= confident → isConfident: true、llm 呼ばれない
3. hybrid top1 < low かつ llm あり → llm が呼ばれその結果が返る（strategy: 'llm'）
4. hybrid top1 < low かつ llm=null → ハイブリッド候補がそのまま（isConfident: false）
5. 候補 0 件で例外を投げない
さらに純粋関数の単体テスト:
- fuse: 両ランキング 1 位の文書が片方のみ 1 位より上に来る
- applyMatchCount: match_count=0 で素のスコア、大でも RRF 順位を覆さない
- judge: 'confident'/'middle'/'low'/空 の 4 分岐
制約: TypeScript strict、async/await、ES クライアントは使わない（純粋なロジックテスト）。
```

---

## Day 3 終了チェックリスト

- [ ] `judge` が 'confident'/'middle'/'low' を返す（しきい値は引数）
- [ ] `GeminiLlmFallback` が構造化出力で 1 件選び、choices 外は null（BYOK なしは呼ばれない）
- [ ] `classifyService.classify(query, tenantId, categoryId?)` が ④〜⑥ をつなぎ `ClassifyResult` を返す
- [ ] ユニットテストが green、わざと壊すと red を確認した
- [ ] `pnpm build` 型エラー 0 / `pnpm test` green
- [ ] **Sprint 2 ゴール達成**: 自然文 + tenantId + categoryId? で候補リストが返る

## Sprint 3 への引き継ぎメモ（自分宛て）

- `ClassifyService` は候補を返すところまで。確定後の 3 段階エスカレーション（auto_resolution / guidance_message / 直接起票）と動的フォーム・起票は Sprint 3（[`06_destinations.md`](../06_destinations.md)）
- 閾値・α は環境変数で固定中。実データで要チューニング → テナント別チューニングは後続
- LLM フォールバックの Secret Manager 連携（per-tenant Gemini キー）が Sprint 1 で未完なら、Sprint 3 着手前に詰める
- `matchStrategy` は inquiries 保存時のフィールドに対応（Sprint 3 で起票ログに記録）
