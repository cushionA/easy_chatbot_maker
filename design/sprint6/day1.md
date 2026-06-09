# Sprint 6 Day 1 作業指示書（2026-06-12）

> テーマ: **マスタ CRUD の本命 — KnowledgeEntry リッチ編集の型を仕上げる**
> 完了時の状態: `/t/:slug/knowledge/:id/edit` で `example_queries` / `auto_resolution` / `guidance_message` / `ticket_priority` / `required_field_codes` を含む全列を編集でき、保存時に embedding 再計算が `passage:` でトリガされる。一覧/作成/削除も回る
> 推定所要: 5〜7 時間

---

## Day1-1. Sprint 4 前提リハビリ + KnowledgeEntry 編集の現状確認 [自分] [BE]

**目的**
Sprint 2 day1 で AI が作った Knowledge CRUD は「配列列をカンマ区切り 1 行で雑に編集する」最小実装だった（[`sprint2/day1.md:21-22`](../sprint2/day1.md)）。今日はそれを「マスタ管理として実用に耐えるリッチ編集」に格上げする。まず現状の編集ページが何を編集できて何を取りこぼしているかを自分の目で確認し、今日の差分を箇条書きにする。面接では「PoC の雑な編集 UI を、3 段階エスカレーション列まで含む実用マスタ管理に育てた差分」を語れる。

**自分で書く理由**
今日の作業範囲（=どの列を編集対象に昇格させ、embedding をいつ再計算するか）は設計判断。AI に「確認して」と投げると、何を仕上げるべきかの判断ごと委譲してしまう。

**前提確認**
- [ ] Sprint 1 / 2 / 4 が完了している（[`sprint6_plan.md`](../sprint6_plan.md) の前提）
- [ ] `pnpm --filter api build` が error 0 で通る
- [ ] `apps/api/src/entities/KnowledgeEntry.ts` の列を確認した（`name` / `keywords: string[]` / `exampleQueries: string[]` / `requiredFieldCodes: string[]` / `autoResolution?: string` / `guidanceMessage?: string` / `ticketPriority`（default `"normal"`）/ `matchCount` / `embedding?: number[]` / `embeddingModel?: string` / `searchText`）
- [ ] [`08_features.md:18`](../08_features.md)（問題エントリ管理の編集対象列）と [`05_search_classification.md:113-134`](../05_search_classification.md)（3 段階エスカレーション / `required_field_codes` 結合）を読んだ

**手順**
1. 既存の `apps/web/src/pages/knowledge/Edit.tsx`（Sprint 2 day1 生成物）を開き、現状で編集できる列を列挙する
2. 今日の昇格対象を箇条書きにする（このメモが Day1-2 の設計の正）:
   - `exampleQueries`（`string[]`）→ カンマ 1 行ではなく**行追加できる配列エディタ**にする
   - `keywords` / `requiredFieldCodes`（`string[]`）→ 同じ配列エディタを再利用
   - `autoResolution` / `guidanceMessage`（`string?`）→ 複数行 `<textarea>`、両方の有無で 3 段階エスカレーションが決まることをラベルに明記
   - `ticketPriority` → 自由文字でなく `<select>`（`low` / `normal` / `high` / `urgent` を仮置き、設計に enum 定義がないので**ここで仮決めし報告**）
   - `categoryId` → Categories から引いた `<select>`
3. embedding 再計算の方針を決める: **`name` / `keywords` / `exampleQueries` のいずれかが変わったら再計算が要る**（`searchText` の生成元と揃える）。再計算は Day1-4 で実装、Day1-2 では「保存後に再計算サービスを呼ぶフック点」だけ用意する、と決める
4. `embeddingModel` 列は手で触らせない（再計算サービスが `currentModel` を埋める）方針をメモ

**完了確認**
- [ ] 「今日昇格する列」と「embedding 再計算の発火条件」を箇条書きにした
- [ ] `ticketPriority` の取りうる値を仮決めし、設計に定義が無い旨をメモした（報告対象）
- [ ] ビルドが error 0

**AI 依頼テンプレ**: なし（範囲確定は自分）

---

## Day1-2. KnowledgeEntry リッチ編集ページ（配列 / 3 段階列 / required_field_codes / embedding 再計算トリガ）[自分] [FE] [BE]

**目的**
**マスタ編集 UX の「最初の 1 個（型）」を自分の手で仕上げる**。これが Day2 の FieldDefinition / ValidationRule、そして取込後の手修正でも使う「配列エディタ + 多列フォーム」のお手本になる。`exampleQueries` を行追加で編集でき、3 段階エスカレーション（`autoResolution` / `guidanceMessage`）の意味がラベルで分かり、`requiredFieldCodes` を編集でき、保存時に embedding 再計算がトリガされる。面接では「React + react-hook-form で配列列を行追加 UI として編集し、保存契機で Node API 経由の embedding 再計算をトリガする設計」を語れる。

**自分で書く理由**
配列列の行追加 UI（`useFieldArray` で `string[]` を動的管理）と、保存→embedding 再計算という副作用の発火点は、後続が全部複製する型。ここを AI に決めさせると、`exampleQueries` の編集 UX も再計算契機も「説明できないコード」になる。SKILL.md の「最初の 1 個は自分」。

**前提確認**
- [ ] Day1-1 完了（昇格列リストと再計算条件が手元にある）
- [ ] Sprint 2 day1 の `apps/web/src/pages/knowledge/Edit.tsx` が動く（複製の土台）
- [ ] `useFieldArray`（react-hook-form）で `string[]` を行単位に管理する方法を理解（[`sprint2/day1.md:31-33`](../sprint2/day1.md)）

**手順**（骨格とコメントだけ示す。実装ロジック本体は自分で埋める）
1. `apps/web/src/pages/knowledge/Edit.tsx` を改装（新規ではなく既存を昇格）
2. フォームスキーマを実列に合わせて定義する。配列列（`keywords` / `exampleQueries` / `requiredFieldCodes`）は `useFieldArray` で `{ value: string }[]` として持ち、送信時に `string[]` に変換してAPIに渡す（[`sprint2/day1.md:31-33`](../sprint2/day1.md)）。スカラー列は `name`(`required, maxLength:200`) / `categoryId`(`string`) / `autoResolution`(`string?`) / `guidanceMessage`(`string?`) / `ticketPriority`(`required`, 既定 `"normal"`):
   ```typescript
   // ここを自分で実装: KnowledgeEntry の編集対象列を Day1-1 の昇格リストに沿って宣言する。
   //   - 配列列は useFieldArray で { value: string }[] として管理（送信時に .map(f => f.value)）
   //   - バリデーションは zod スキーマで（name は required + max(200)）
   //   - ticketPriority は既定 "normal"
   type FormValues = {
     // ...
   }
   ```
3. **配列エディタを 1 つの再利用コンポーネントとして書く**（`exampleQueries` 用に書き、`keywords` / `requiredFieldCodes` でも使い回す）。構造は「各行 = `<input>`（要素への双方向バインド）+ 行削除ボタン」「末尾に + 行追加ボタン」。注意点は **詰まったら** 節（`key` の安定化）を先に読むこと:
   ```tsx
   {/* ExampleQueries editor — 配列列の編集 UX のお手本。Day2 / 取込後修正でも流用する */}
   {/* ここを自分で実装:
        - useFieldArray の fields を map して各要素に register で input をバインドする
        - 各行に「行削除」(remove(index)) ボタン、末尾に「+ 行追加」(append({ value: "" })) ボタン
        - key には field.id を使う（インデックスではなく安定 ID） */}
   ```
4. 3 段階エスカレーション列はラベルで意味を明示する（[`05_search_classification.md:117-121`](../05_search_classification.md) の表）:
   - `autoResolution`: 「入力すると自動回答完結（起票しない）」
   - `guidanceMessage`: 「auto_resolution が空でこれが有ると、ガイダンス → フォーム」
   - 両方空 → 直接フォーム、を注記
5. `ticketPriority` は `<select>`（Day1-1 で仮決めした値の選択肢を並べる）
6. `onSubmit` で実列を更新する Node API（`PUT /api/knowledge/:id`）を呼び、**保存後に embedding 再計算をトリガするフック点だけ置く**（実体は Day1-4 の `knowledgeEmbeddingUpdater`）。「再計算が要るか」は検索元（`name` / `keywords` / `exampleQueries`）が変わったかで判定する:
   ```typescript
   // embedding は文書なので passage: で計算する（CLAUDE.md 横断ルール）。
   // 実体は Day1-4 の knowledgeEmbeddingUpdater。ここでは「再計算が要るか」を判定して呼ぶだけ。
   // ここを自分で実装:
   //   1. 旧エンティティ値と formValues の name/keywords/exampleQueries を比較する判定を書く
   //   2. 変化があったときだけ await triggerEmbeddingRecompute(id) を呼ぶ
   //   3. guidanceMessage だけ変更のケースでは呼ばれないことを完了確認で担保する
   ```
7. エラーハンドリングは Sprint 1 day3 の `Edit.tsx` と同じ扱いに揃える（[`sprint1/day3.md:209-214`](../sprint1/day3.md)）
8. `tenantId` は API リクエストの JWT クレームから取る（クライアント送信値は信用しない）

**完了確認**
- [ ] `exampleQueries` を行追加・行削除・編集して保存でき、再読込で反映される
- [ ] `keywords` / `requiredFieldCodes` も同じ配列エディタで編集できる
- [ ] `autoResolution` / `guidanceMessage` / `ticketPriority` / `categoryId` が編集・保存できる
- [ ] `name` または `keywords`/`exampleQueries` を変えて保存すると embedding 再計算フックが呼ばれる（Day1-4 未実装ならログ or no-op で発火だけ確認）
- [ ] それ以外（例: `guidanceMessage` だけ変更）では再計算が呼ばれない
- [ ] 別テナントの id を踏むと 404（API の RLS で `null` 返却）
- [ ] `pnpm --filter web build` が error 0

**詰まったら**
- `useFieldArray` の `input` に `register` を使うと再描画でフォーカスが飛ぶ → `key={field.id}` を付けているか確認。それでも不安定なら各行を独立コンポーネントに切り出して `defaultValue` で初期化する
- 配列列の保存で空文字が混ざる → `submit` 前に `.filter(v => v.trim() !== "")` でフィルタ

**AI 依頼テンプレ**: なし（編集 UX の型は自分で書く）

---

## Day1-3. KnowledgeEntry 一覧/作成/削除ページ [AI] [FE] [BE]

**目的**
Day1-2 で固めたリッチ編集ページを土台に、一覧（リッチ列のサマリ表示）・作成（編集と同じフォーム）・削除を AI に複製させる。同パターン複製なので委譲。

**前提確認**
- [ ] Day1-2 完了（`Edit.tsx` が動く＝複製元になる）

**AI 依頼テンプレ**
```
apps/web/src/pages/knowledge/Edit.tsx を土台に、Knowledge の
一覧 Index.tsx / 作成 Create.tsx / 削除を整備して。

制約:
- ルート: 一覧 /t/:slug/knowledge、作成 /t/:slug/knowledge/new
- Create.tsx は Edit.tsx と同じフォームスキーマ・同じ配列エディタコンポーネントを使う（フォーム部分は共通化して重複を避ける。
  apps/web/src/components/knowledge/ に小コンポーネントとして切り出してよい）
- Index.tsx: GET /api/knowledge をテナントスコープで呼び Category 名で結合表示。
  列は name / category / ticketPriority / autoResolution の有無(○/-) / guidanceMessage の有無 / exampleQueries 件数 / updatedAt。
  各行に Edit リンクと Delete ボタン
- 削除は確認ダイアログ後に DELETE /api/knowledge/:id を呼ぶ。削除後は一覧へ
- 作成時 embedding 再計算は Day1-4 の triggerEmbeddingRecompute を呼ぶ（Edit.tsx と同じ発火条件、新規は常に再計算）
- tenantId は JWT クレームから API 側で取る（クライアントから送らない）
- エラーハンドリングは既存 Category の Edit と同じ扱い
変更は apps/web/src/pages/knowledge/ と apps/web/src/components/knowledge/ に閉じる。
エンティティ定義・Node API のルーティングは変えない。
```

**自分の確認ポイント**
- [ ] 一覧 → 作成 → 編集 → 削除の一周が回る
- [ ] 作成時に embedding が `passage:` で入る（Day1-4 と接続後）
- [ ] 配列エディタコンポーネントが Create / Edit で共通化され重複していない
- [ ] 別テナントの Knowledge が一覧に出ない（API の RLS 目視）

---

## Day1-4. embedding 再計算トリガの passage: 計算実装 [AI 一次→自分レビュー] [BE] [ML]

**目的**
Day1-2 で置いたフック点 `triggerEmbeddingRecompute` の実体を Node API に作る。`name` + `keywords` + `exampleQueries` を 1 本の文書文字列に組み、**`passage:` モード**で FastAPI `/embed` を呼んで embedding を計算し、Elasticsearch のドキュメント（`dense_vector`）と Postgres メタ（`embeddingModel`）を更新する。`query:`/`passage:` を間違えると検索 recall が静かに落ちる（[`embedding/CLAUDE.md`](../../embedding/CLAUDE.md)）ので、**mode が `passage` であることだけは自分がレビューで握る**。

**前提確認**
- [ ] Day1-2 完了（フック点がある）
- [ ] `apps/api/src/services/embeddingClient.ts` の現状シグネチャを確認した
  - **注意**: 現状の `embedText(text: string, ct?: AbortSignal)` は `mode` 引数を持たない（Sprint 2 day1-5 で計画した `EmbedMode` 型追加が実コードに入っていない）。`passage:` を確実に通すため、`EmbedMode = "query" | "passage"` を追加して `passage` を明示できる状態にしてから使う（報告対象）
- [ ] [`embedding/CLAUDE.md`](../../embedding/CLAUDE.md) の「prefix `query: ` for queries, `passage: ` for documents」を読んだ

**手順（自分が握る部分）**
1. インターフェースを自分で定義する（`apps/api/src/services/knowledgeEmbeddingUpdater.ts`、実装は AI）:
   ```typescript
   // KnowledgeEntry の検索元テキストを passage: で再 embedding し
   // Elasticsearch dense_vector と Postgres embeddingModel を更新する。
   export interface KnowledgeEmbeddingUpdater {
     recompute(knowledgeEntryId: string, signal?: AbortSignal): Promise<void>;
   }
   ```
2. embedding の元テキストの組み方を決める（`searchText` 生成列と揃える＝`name` + `keywords` + `exampleQueries` を空白連結）。この 1 行を自分でコメントに残す
3. **`embeddingClient` の `passage` 対応がまだなら、まず型追加を AI に依頼**（下記テンプレの前半）

**AI 依頼テンプレ**
```
2 つ作って。

(1) embeddingClient に passage 対応を入れる:
- apps/api/src/services/embeddingClient.ts に EmbedMode = "query" | "passage" 型を追加し、
  embedText(text: string, mode: EmbedMode, signal?: AbortSignal) に変更
- EmbeddingClient の実装を mode から FastAPI /embed の mode 文字列("query"/"passage")を導く実装に直す
  （プレフィクスはサーバ側 embedding service が付ける。Node 側で query:/passage: を文字列付与しない＝二重付与防止）
- 既存 embedText 呼び出し元（grep -rn embedText apps/api/）を新シグネチャに合わせる（既存は "query" 相当）

(2) KnowledgeEmbeddingUpdater の実装:
- apps/api/src/services/knowledgeEmbeddingUpdater.ts を作り KnowledgeEmbeddingUpdater を実装
- recompute(id):
  1. Postgres から KnowledgeEntry を取得（tenantId は JWT クレームから。SELECT WHERE で書かない＝RLS 任せ）
  2. 元テキスト = [name, ...keywords, ...exampleQueries].join(" ")
  3. await embeddingClient.embedText(text, "passage", signal)  ← passage 必須
  4. Elasticsearch の対象ドキュメント(dense_vector)を update
  5. Postgres の embeddingModel を currentModel で更新
- DI 登録（apps/api/src/container.ts）。既存の embeddingClient 登録に合わせる
制約: apps/api の TypeScript strict モード・ILogger 相当は pino を使う・async/await・
SQL はパラメータ化クエリ（文字列結合禁止）・secret/SQL をログに出さない。
currentModel の供給元は既存の設定（classifyOptions 等）に合わせる。
```

**自分のレビュー責務（ここが本タスクの肝）**
- [ ] **`mode: "passage"` で呼んでいる**（`"query"` になっていない）
- [ ] Node 側で `passage:` の文字列を手付けしていない（サーバ側が付ける。二重付与で `passage: passage:` にならない）
- [ ] `embeddingModel` に `currentModel` が入る
- [ ] embedding 計算失敗時に保存全体を巻き込んで壊さない（再計算は best-effort でもログを残す）

**完了確認**
- [ ] Day1-2/1-3 から作成・編集すると Elasticsearch の `dense_vector` が更新され、`embeddingModel` が埋まる
- [ ] `name` だけ変更 → embedding が変わる / `guidanceMessage` だけ変更 → 再計算されない
- [ ] `"query"` と `"passage"` で FastAPI `/embed` のベクトルが異なることを 1 度実機確認した
- [ ] `pnpm --filter api build` が error 0

---

## Day 1 終了チェックリスト

- [ ] `/t/:slug/knowledge` の一覧/作成/編集/削除が回る
- [ ] 編集ページで `exampleQueries`（行追加）/ `keywords` / `requiredFieldCodes` / `autoResolution` / `guidanceMessage` / `ticketPriority` / `categoryId` が編集できる
- [ ] 保存時に検索元（name/keywords/exampleQueries）が変わったときだけ embedding が `passage:` で再計算される
- [ ] 別テナントのデータが見えない（API の RLS）
- [ ] `pnpm --filter api build` および `pnpm --filter web build` が error 0

## Day 2 への引き継ぎメモ（自分宛て）

- 配列エディタコンポーネント（`apps/web/src/components/knowledge/`）は Day2 の FieldDefinition `choices` 編集でも流用する
- `knowledgeEmbeddingUpdater` は Day2 の一括取込でも 1 件ずつ呼ぶ（取込も `passage:`）
- `ticketPriority` の取りうる値は仮決め。設計に enum 定義が無いので報告に残す
