# Sprint 4 Day 3 作業指示書（2026-06-03）

> テーマ: **確認画面・起票連携・引用元ハイライト・未分類キュー・admin レビュー**
> 完了時の状態: フォーム入力 → 確認画面 → `submitTicket` で起票（成功/失敗 UI + `draft_fields` 退避）→ 回答画面に引用元（matched `KnowledgeEntry`）と admin リンク表示。該当なしは「新規問題として」自由入力で `unclassified_queue` に登録され、admin がレビュー画面でマスタ追加 or 破棄 + コメントできる
> 推定所要: 6〜8 時間

> 着手前に必読: [`05_search_classification.md:32-35`](../05_search_classification.md)（⑦ 新規問題 → unclassified_queue）、[`05:148-154`](../05_search_classification.md)（引用元ハイライト）、[`09_task_split.md:27`](../09_task_split.md)（未分類キュー → マスタ反映の運用フロー = 自分が握る）。

---

## Day4-9. 確認画面 `ConfirmStep` [自分（最初の1個）] [FE]

**目的**
入力したフォーム値を起票前に一覧表示し、「修正」「起票する」を選ばせる確認ステップ。暗黙シグナル（[`05:164-176`](../05_search_classification.md)）の「確認画面まで進んだ＝分類成功」「修正を押した＝入力/分類に問題」を `Inquiry` に記録する設計の起点なので、確認 → 起票/修正の遷移の型を自分で書く。

**自分で書く理由**
確認 → 起票の境界は「ここを越えたら外部システムに書き込む」点。何を確認させ、修正でどこに戻すか（フォーム or 分類）は UX 設計判断。最初の 1 個を自分で握れば、表示整形などの肉付けは AI に複製依頼できる。

**前提確認**
- [ ] Day 2 完了（フォーム値の集約モデル + サーバ検証 `fieldValidator.ts` がある）
- [ ] [`05:164-176`](../05_search_classification.md)（暗黙シグナル表）を読んだ

**手順**
1. `apps/web/src/components/ConfirmStep.tsx` を新規作成し、確認用の表示を自分で書く。props 型と枠だけ示すので、表示の組み立てと整形は自分で実装する:
   ```tsx
   type Props = {
     fields: FieldDefinition[];
     values: Record<string, unknown>;
     onSubmit: () => void;
     onBack: () => void;
   };

   export function ConfirmStep({ fields, values, onSubmit, onBack }: Props) {
     // ここを自分で実装:
     // - Day2 の集約モデル（code→値）を <dl> で一覧表示する
     // - 各 code はラベル化（field.question ?? field.code）、値は表示用に整形
     //   （isMulti の配列は改行 or カンマ区切りに整える）
     return (
       <div>
         <h2>入力内容の確認</h2>
         {/* フィールド一覧表示 */}
         <button onClick={onSubmit}>起票する</button>  {/* Day4-10 へ */}
         <button onClick={onBack}>修正</button>         {/* step = 'form'。暗黙シグナル「修正」を記録 */}
       </div>
     );
   }
   ```
   表示整形のヘルパ（ラベル引き・配列整形）は `apps/web/src/utils/fieldDisplay.ts` に自分で足す。
2. 「修正」（`onBack`）を押したら `setStep('form')` に戻す。Day3 末で `Inquiry` を保存する際、修正経由かどうかを記録できるようフラグを state に立てておく（新規列は足さない。[`05:176`](../05_search_classification.md)）。
3. `onSubmit` は **Node API 側の `fieldValidator.ts` を再実行**してから Day4-10 の起票に渡す（クライアント検証を信頼しない）。検証 NG なら起票へ進ませない分岐も自分で書く。

**完了確認**
- [ ] フォーム → 確認で入力値が読みやすく出る（`isMulti` の配列も整形表示）
- [ ] 「修正」でフォームに戻り値が保持される
- [ ] 「起票する」でサーバ検証 → 起票フローへ

**詰まったら**
- 確認画面で値が空 → Day2 の集約モデルが確認ステップに渡っていない（`ChatPage.tsx` の state 共有を確認）

**AI 依頼テンプレ**: なし（自分で書く範囲。表示整形の磨き込みは Day4-11 と合わせて AI 可）

---

## Day4-10. 起票連携（`submitTicket` 呼び出し、成功/失敗 UI、`draft_fields`）[AI] [BE] [FE]

**目的**
確認した値で `Ticket` を組み立て、Sprint 3 の TS Adapter `submitTicket` を呼んで起票する。成功なら `inquiries`（`externalTicketId` / `externalTicketUrl` / `status` / `destinationId`）を保存し `draftFields` を NULL クリア。失敗なら `draftFields`（JSONB）に値を退避してリトライ導線を出す（[`08:54`](../08_features.md)）。Adapter 内部は触らず**呼ぶだけ**。

**前提確認**
- [ ] Day4-9 完了
- [ ] **`submitTicket` の引数と戻り型を実機で確認**（Sprint 3 `apps/api/src/destinations/` の `ITicketDestination` / `Ticket` / `TicketSubmitResult`、[`sprint3_plan.md:29`](../sprint3_plan.md)）。無ければ Sprint 3 に戻る。テンプレを実物に合わせて書き換える
- [ ] Inquiry の保存先フィールドを確認（`externalTicketId` / `externalTicketUrl` / `status` / `draftFields` / `destinationId` / `matchedKnowledgeId` / `matchStrategy` / `confidenceScore` / `rawQuery` / `categoryId`）

**AI 依頼テンプレ**
```
チャットフローの起票連携を実装してほしい。Sprint 3 の TS Adapter / submitTicket を呼ぶだけ（内部は触らない）。

前提（実機で確認した実物に合わせて）:
- apps/api/src/destinations/ の DestinationRegistry で kind から ITicketDestination を解決できる。
- submitTicket(ticket, ...) は成功で external ticket id/url、失敗で失敗理由を返す（正確な型は実物確認）。

要件（design/05_search_classification.md / design/08_features.md:54 が正）:
1. 確認済みフォーム値（code→値、isMulti は配列）から Ticket を組み立てる。
   起票本文は Sprint 3 で移植済みの buildDescription 相当（Markdown 化）を使う。タイトルは問題名 + 概要。
   優先度は KnowledgeEntry.ticketPriority。
2. テナントのプライマリ destination を解決して submitTicket を await で呼ぶ（AbortController で中断可能）。
3. 成功:
   - Inquiry を保存/更新（status=submitted, externalTicketId, externalTicketUrl, destinationId,
     matchedKnowledgeId, matchStrategy, confidenceScore, rawQuery, categoryId, draftFields=null）
   - 起票完了 UI（外部チケットへのリンク表示）。暗黙シグナル「起票完了=完全成功」。
4. 失敗:
   - Inquiry.draftFields(JSONB) に入力値を退避、status=draft 等。
   - 画面に失敗理由 + 「リトライ」ボタン（draftFields から復元して再 submitTicket）。
   - 認証エラー等の即失敗とリトライ可能エラーを区別して文言を変える（Sprint 3 の失敗分類に従う）。
5. tenant_id は Node API の AsyncLocalStorage 経由のテナント文脈から取り、書き込み行に明示的に入れる
   （クライアント由来は信頼しない）。

制約: TypeScript strict mode / 型エラーゼロ / ILogger 相当のロガーでログ（secret・API キーは絶対に出さない）/
draftFields は JSON.stringify でシリアライズ。
```

**自分の確認ポイント**
- [ ] 成功で外部チケット URL が出て `draftFields` が null
- [ ] 失敗で `draftFields` に値が残り、リトライで復元 → 再送できる
- [ ] tenant_id をテナント文脈から取り、RLS の `WITH CHECK` 違反が起きない
- [ ] secret / API キーがログに出ていない

---

## Day4-11. 引用元ハイライト（matched `KnowledgeEntry` 表示 + admin リンク）[AI] [FE]

**目的**
[`05:148-154`](../05_search_classification.md)。確定/起票した回答画面に、マッチした `KnowledgeEntry` の問題名と該当カテゴリを表示し、admin にはマスタ管理画面（`/t/:slug/...` の knowledge 編集）への遷移リンクを出す。member には出さない。

**前提確認**
- [ ] Day4-10 完了
- [ ] ロールは `admin` / `member`（[`08_features.md:8`](../08_features.md)、`UserTenant` の role）。現在ロールの取得方法を確認（JWT クレームから取る）

**AI 依頼テンプレ**
```
回答/起票完了画面に引用元（matched KnowledgeEntry）表示を足してほしい。

仕様（design/05_search_classification.md:148-154）:
- 確定した KnowledgeEntry の name と所属 Category の name/emoji を表示。
- admin ロールのときだけ、マスタ管理画面への遷移リンクを出す
  （/t/:slug/... の knowledge 編集ページ。既存ルートに合わせる。無ければカテゴリ一覧へのリンクで暫定）。
- member には admin リンクを出さない（ロール判定は JWT クレームから取得。クライアント由来は信頼しない）。
- 「検索クエリのどの語がどのキーワード/例文にマッチしたか」のハイライトは design では「オプション」なので、
  MVP では問題名/カテゴリ表示のみ。ハイライトは TODO コメントで残す。

制約: TypeScript strict mode / 型エラーゼロ。
```

**自分の確認ポイント**
- [ ] admin で開くとマスタへのリンクが出る／member では出ない
- [ ] 問題名・カテゴリが正しく出る
- [ ] 語ハイライトは TODO で明示（範囲外と分かる）

---

## Day4-12. 未分類キュー登録（「新規問題として」自由入力 → `unclassified_queue`）[自分] [FE] [BE]

**目的**
フロー⑦（[`05:32-35`](../05_search_classification.md)）。⑤で該当なし（or「どれでもない」）のとき「新規問題として」自由入力を受け、`unclassified_queue` に登録する。これは**「未分類キュー → マスタ反映の運用フロー」の起点**で、[`09_task_split.md:27`](../09_task_split.md) が明示的に「自分が握る」と指定した運用判断。だから自分で書く。

**自分で書く理由**
何を未分類として残し、admin がどう拾うか（このキューが後で Day4-13 のレビュー → マスタ追加につながる）は運用フローの設計判断。`unclassified_queue` に何を保存するか（`rawQuery` / `freeformBody` / `status='pending'` / `queryEmbedding`）の契約を自分で決める。

**前提確認**
- [ ] Day 1 の「該当なしフラグ」分岐が `ChatPage.tsx` にある（Day4-4 で用意）
- [ ] `apps/api/src/models/UnclassifiedQueueEntry.ts` の型定義を確認（`rawQuery` / `freeformBody` / `queryEmbedding` / `status='pending'` / `reviewedBy` / `reviewedAt` / `reviewNote`）
- [ ] [`05:30-35`](../05_search_classification.md)（⑦）と [`05:162`](../05_search_classification.md)（unclassified は「分類できなかった」軸）を読んだ

**手順**
1. `ChatPage.tsx` に該当なし時のステップ（`'unclassified'`）を追加し、自分で書く。JSX の枠だけ示す:
   ```tsx
   {step === 'unclassified' && (
     <div>
       <h2>新規問題として登録</h2>
       <p>該当する問題が見つかりませんでした。内容を書いていただければ担当者が確認します。</p>
       {/* ここを自分で実装:
           - <textarea> を freeform state にバインド
           - 「送信」ボタンで registerUnclassified を呼ぶ */}
     </div>
   )}
   ```
2. 登録ロジックの骨子を自分で書く。**このキューに何を保存するか（`unclassified_queue` の契約）が運用フローの設計判断**なので、フィールドの埋め方は自分で決める。呼び出しの作法だけ示す:
   ```ts
   async function registerUnclassified() {
     // tenant_id は Node API の AsyncLocalStorage 経由のテナント文脈から取る（クライアント由来は信頼しない）
     // POST /api/unclassified-queue に以下を渡す（前提確認の型定義から自分で選ぶ）:
     //   - rawQuery   : ③ で入れた自然言語入力（query state）
     //   - freeformBody: 利用者の追記（freeform state）
     //   - status     : admin レビュー待ちを表す値（Day4-13 が拾う）
     //   - queryEmbedding: 分類エンドポイントが出していれば流用、無ければ null
     // 保存後は完了 UI へ。暗黙シグナル「どれでもない」= 候補ミスマッチを記録する
   }
   ```
   ヒント: フィールドの正は前提確認の `UnclassifiedQueueEntry.ts` 型定義。`status` の初期値は Day4-13 のレビューが `pending` を前提にしている点と整合させる。
3. 「どれでもない」（候補からの離脱、[`05:170`](../05_search_classification.md)）からもこのステップに合流できる導線を Day4-9 の確認画面手前に置く。

**完了確認**
- [ ] 該当なし → 自由入力 → 送信で `unclassified_queue` に `status='pending'` の行が入る
- [ ] 自テナントの行としてのみ作られる（RLS の `WITH CHECK` で別テナントは拒否）
- [ ] `rawQuery`（元クエリ）と `freeformBody`（追記）が両方保存される

**詰まったら**
- RLS の `WITH CHECK` 違反で 500 → テナント文脈が `AsyncLocalStorage` から取れていない（Sprint 1 day3 と同じ）
- CORS エラー → Node API の cors ミドルウェア設定を確認（許可 origin に Web dev サーバを追加）

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## Day4-13. admin レビュー画面（マスタ追加 or 破棄 + コメント）[AI] [FE] [BE]

**目的**
[`05:34`](../05_search_classification.md) + [`08_features.md:62-65`](../08_features.md)。admin が `unclassified_queue` の `pending` 行を一覧し、各行を「マスタ追加（Knowledge 作成へ誘導）」or「破棄」し、`reviewNote` にコメントを残せる画面。Day4-12 で自分が決めたキューの形（`status` / `reviewedBy` / `reviewedAt` / `reviewNote`）を消費する。

**前提確認**
- [ ] Day4-12 完了（`pending` 行が作られる）
- [ ] admin ロール判定の方法（Day4-11 と同じ）

**AI 依頼テンプレ**
```
admin 向けの未分類キュー レビュー画面を作ってほしい。Sprint 1 の Categories CRUD
（apps/web/src/pages/categories/index.tsx）と同じ書き方・配置に合わせる。

仕様（design/05_search_classification.md:34 / design/08_features.md:62-65 / UnclassifiedQueueEntry.ts が正）:
- ルート: /t/:slug/admin/unclassified（admin ロールのみ。member は 403 相当の表示）
- 一覧: status='pending' の UnclassifiedQueueEntry を createdAt 降順で表示（rawQuery / freeformBody / createdAt）。
  GET /api/unclassified-queue?status=pending で取得（RLS が tenant を絞る）。
- 各行のアクション:
  1) マスタ追加: reviewNote を入れて status='accepted'、reviewedBy=現在ユーザー id、reviewedAt=now を保存し、
     Knowledge 作成ページ（既存 /t/:slug/... の knowledge 新規。無ければ Categories へ暫定リンク）へ rawQuery を
     プリフィルする想定で遷移（プリフィルは TODO 可）。
  2) 破棄: reviewNote 必須で status='discarded'、reviewedBy/reviewedAt を保存。
- tenant_id でフィルタしない（RLS）。書き込みの tenant_id は AsyncLocalStorage のテナント文脈から（クライアント信頼しない）。
- reviewedBy は現在ユーザー id（JWT クレームから取得）。

制約: TypeScript strict mode / 型エラーゼロ / react-hook-form でコメント入力 / secret をログに出さない。
```

**自分の確認ポイント**
- [ ] admin で `pending` 一覧が出る／member ではアクセスできない
- [ ] 「マスタ追加」で `accepted` + `reviewedBy/At` 保存、Knowledge 作成へ誘導
- [ ] 「破棄」で `discarded` + コメント保存（コメント必須）
- [ ] 他テナントの未分類行が見えない（RLS）

---

## Day 3 終了チェックリスト

- [ ] フォーム → 確認 → 起票（`submitTicket`）が通り、外部チケット URL が出る
- [ ] 起票失敗で `draft_fields` が残り、リトライで再送できる
- [ ] 回答画面に引用元（問題名・カテゴリ）+ admin リンクが出る
- [ ] 該当なし → 「新規問題として」自由入力 → `unclassified_queue` に `pending` 登録
- [ ] admin が未分類キューをレビュー（accepted / discarded + コメント）できる
- [ ] `inquiries` に `match_strategy` / `confidence_score` / `resolved` 等の暗黙シグナルが乗っている（可視化は別 Sprint）

## Sprint 4 完走後に残るタスク（[`sprint4_plan.md:87-92`](../sprint4_plan.md)）
- LLM フォールバック（⑥, BYOK 時のみ）の UI 結線 — 本 Sprint は ⑤→⑦ 直結
- 埋め込みウィジェット（`embed.js` / Shadow DOM / 匿名 RLS）— 別 Sprint
- ナレッジギャップ検出ダッシュボード（`inquiries.confidence_score` 集計）— 別 Sprint
- 暗黙シグナルの集計・可視化 — 値は本 Sprint で乗るので可視化のみ残る
