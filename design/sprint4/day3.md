# Sprint 4 Day 3 作業指示書（2026-06-03）

> テーマ: **確認画面・起票連携・引用元ハイライト・未分類キュー・admin レビュー**
> 完了時の状態: フォーム入力 → 確認画面 → `SubmitAsync` で起票（成功/失敗 UI + `draft_fields` 退避）→ 回答画面に引用元（matched `KnowledgeEntry`）と admin リンク表示。該当なしは「新規問題として」自由入力で `unclassified_queue` に登録され、admin がレビュー画面でマスタ追加 or 破棄 + コメントできる
> 推定所要: 6〜8 時間

> 着手前に必読: [`05_search_classification.md:32-35`](../05_search_classification.md)（⑦ 新規問題 → unclassified_queue）、[`05:148-154`](../05_search_classification.md)（引用元ハイライト）、[`09_task_split.md:27`](../09_task_split.md)（未分類キュー → マスタ反映の運用フロー = 自分が握る）。

---

## Day4-9. 確認画面 `ConfirmStep` [自分（最初の1個）]

**目的**
入力したフォーム値を起票前に一覧表示し、「修正」「起票する」を選ばせる確認ステップ。暗黙シグナル（[`05:164-176`](../05_search_classification.md)）の「確認画面まで進んだ＝分類成功」「修正を押した＝入力/分類に問題」を `Inquiry` に記録する設計の起点なので、確認 → 起票/修正の遷移の型を自分で書く。

**自分で書く理由**
確認 → 起票の境界は「ここを越えたら外部システムに書き込む」点。何を確認させ、修正でどこに戻すか（フォーム or 分類）は UX 設計判断。最初の 1 個を自分で握れば、表示整形などの肉付けは AI に複製依頼できる。

**前提確認**
- [ ] Day 2 完了（フォーム値の集約モデル + サーバ検証 `FieldValidator` がある）
- [ ] [`05:164-176`](../05_search_classification.md)（暗黙シグナル表）を読んだ

**手順**
1. `Chat.razor` に `ChatStep.Confirm` を追加し、確認用の表示を自分で書く:
   ```razor
   case ChatStep.Confirm:
       <h2>入力内容の確認</h2>
       <dl>
           @foreach (var (code, value) in _form.Entries())   // Day2 の集約モデル
           {
               <dt>@LabelFor(code)</dt>
               <dd>@DisplayValue(value)</dd>   // is_multi は配列を改行 or カンマ整形
           }
       </dl>
       <button @onclick="OnSubmit">起票する</button>          // Day4-10 へ
       <button @onclick="BackToForm">修正</button>             // _step = Form。暗黙シグナル「修正」を記録
       break;
   ```
2. 「修正」を押したら `_step = ChatStep.Form` に戻す。Day3 末で `Inquiry` を保存する際、修正経由かどうかを記録できるようフラグを立てておく（新規列は足さない。[`05:176`](../05_search_classification.md)）。
3. `OnSubmit` は **サーバ側 `FieldValidator` を再実行**してから Day4-10 の起票に渡す（クライアント検証を信頼しない）。

**完了確認**
- [ ] フォーム → 確認で入力値が読みやすく出る（`is_multi` の配列も整形表示）
- [ ] 「修正」でフォームに戻り値が保持される
- [ ] 「起票する」でサーバ検証 → 起票フローへ

**詰まったら**
- 確認画面で値が空 → Day2 の集約モデルが確認ステップに渡っていない（`Chat.razor` のフィールド共有を確認）

**AI 依頼テンプレ**: なし（自分で書く範囲。表示整形の磨き込みは Day4-11 と合わせて AI 可）

---

## Day4-10. 起票連携（`SubmitAsync` 呼び出し、成功/失敗 UI、`draft_fields`）[AI]

**目的**
確認した値で `Ticket` を組み立て、Sprint 3 の `ITicketDestination.SubmitAsync` を呼んで起票する。成功なら `inquiries`（`ExternalTicketId` / `ExternalTicketUrl` / `Status` / `DestinationId`）を保存し `DraftFields` を NULL クリア。失敗なら `DraftFields`（JSONB）に値を退避してリトライ導線を出す（[`08:54`](../08_features.md)、[`Inquiry.cs`](../../backend/Portfolio.Web/Data/Entities/Inquiry.cs)）。Adapter 内部は触らず**呼ぶだけ**。

**前提確認**
- [ ] Day4-9 完了
- [ ] **`SubmitAsync` の引数と戻り型を実機で確認**（Sprint 3 `Portfolio.Destinations` の `ITicketDestination` / `Ticket` / `TicketSubmitResult`、[`sprint3_plan.md:29`](../sprint3_plan.md)）。無ければ Sprint 3 に戻る。テンプレを実物に合わせて書き換える
- [ ] `Inquiry.cs` の保存先列を確認（`ExternalTicketId` / `ExternalTicketUrl` / `Status` / `DraftFields` / `DestinationId` / `MatchedKnowledgeId` / `MatchStrategy` / `ConfidenceScore` / `RawQuery` / `CategoryId`）

**AI 依頼テンプレ**
```
チャットフローの起票連携を実装してほしい。Sprint 3 の ITicketDestination / SubmitAsync を呼ぶだけ（内部は触らない）。

前提（実機で確認した実物に合わせて）:
- Portfolio.Destinations の DestinationRegistry で kind から ITicketDestination を解決できる。
- SubmitAsync(Ticket, ...) は成功で external ticket id/url、失敗で失敗理由を返す（正確な型は実物確認）。

要件（design/05_search_classification.md / design/08_features.md:54 / Inquiry.cs が正）:
1. 確認済みフォーム値（code→値、is_multi は配列）から Ticket を組み立てる。
   起票本文は Sprint 3 で移植済みの build_description 相当（Markdown 化）を使う。タイトルは問題名 + 概要。
   優先度は KnowledgeEntry.TicketPriority。
2. テナントのプライマリ destination を解決して SubmitAsync を await で呼ぶ（CancellationToken 最後の引数。Task.Run 禁止）。
3. 成功:
   - Inquiry を保存/更新（Status=submitted, ExternalTicketId, ExternalTicketUrl, DestinationId,
     MatchedKnowledgeId, MatchStrategy, ConfidenceScore, RawQuery, CategoryId, DraftFields=NULL）
   - 起票完了 UI（外部チケットへのリンク表示）。暗黙シグナル「起票完了=完全成功」。
4. 失敗:
   - Inquiry.DraftFields(JSONB) に入力値を退避、Status=draft 等。
   - 画面に失敗理由 + 「リトライ」ボタン（DraftFields から復元して再 SubmitAsync）。
   - 認証エラー等の即失敗とリトライ可能エラーを区別して文言を変える（Sprint 3 の失敗分類に従う）。
5. tenant_id は HttpContext.Items["TenantId"] から取り、書き込み行に明示的に入れる（クライアント由来は信頼しない）。

制約（backend/CLAUDE.md）: Nullable enable / 警告ゼロ / ILogger でログ（secret・API キーは絶対に出さない）/
DraftFields は System.Text.Json でシリアライズ（Newtonsoft 禁止）。
```

**自分の確認ポイント**
- [ ] 成功で外部チケット URL が出て `DraftFields` が NULL
- [ ] 失敗で `DraftFields` に値が残り、リトライで復元 → 再送できる
- [ ] tenant_id を HttpContext から取り、`WITH CHECK` 違反が起きない
- [ ] secret / API キーがログに出ていない

---

## Day4-11. 引用元ハイライト（matched `KnowledgeEntry` 表示 + admin リンク）[AI]

**目的**
[`05:148-154`](../05_search_classification.md)。確定/起票した回答画面に、マッチした `KnowledgeEntry` の問題名と該当カテゴリを表示し、admin にはマスタ管理画面（`/t/{slug}/...` の knowledge 編集）への遷移リンクを出す。member には出さない。

**前提確認**
- [ ] Day4-10 完了
- [ ] ロールは `admin` / `member`（[`08_features.md:8`](../08_features.md)、`UserTenant` の role）。現在ロールの取得方法を確認（JWT クレーム or `HttpContext.Items`）

**AI 依頼テンプレ**
```
回答/起票完了画面に引用元（matched KnowledgeEntry）表示を足してほしい。

仕様（design/05_search_classification.md:148-154）:
- 確定した KnowledgeEntry の Name と所属 Category の Name/Emoji を表示。
- admin ロールのときだけ、マスタ管理画面への遷移リンクを出す
  （/t/{Slug}/... の knowledge 編集ページ。既存ルートに合わせる。無ければカテゴリ一覧へのリンクで暫定）。
- member には admin リンクを出さない（ロール判定は現在のロール取得方法に合わせる。クライアント由来は信頼しない）。
- 「検索クエリのどの語がどのキーワード/例文にマッチしたか」のハイライトは design では「オプション」なので、
  MVP では問題名/カテゴリ表示のみ。ハイライトは TODO コメントで残す。

制約: @rendermode InteractiveServer / Nullable enable / 警告ゼロ / AsNoTracking。
```

**自分の確認ポイント**
- [ ] admin で開くとマスタへのリンクが出る／member では出ない
- [ ] 問題名・カテゴリが正しく出る
- [ ] 語ハイライトは TODO で明示（範囲外と分かる）

---

## Day4-12. 未分類キュー登録（「新規問題として」自由入力 → `unclassified_queue`）[自分]

**目的**
フロー⑦（[`05:32-35`](../05_search_classification.md)）。⑤で該当なし（or「どれでもない」）のとき「新規問題として」自由入力を受け、`unclassified_queue` に登録する。これは**「未分類キュー → マスタ反映の運用フロー」の起点**で、[`09_task_split.md:27`](../09_task_split.md) が明示的に「自分が握る」と指定した運用判断。だから自分で書く。

**自分で書く理由**
何を未分類として残し、admin がどう拾うか（このキューが後で Day4-13 のレビュー → マスタ追加につながる）は運用フローの設計判断。`unclassified_queue` に何を保存するか（`RawQuery` / `FreeformBody` / `Status='pending'` / `QueryEmbedding`）の契約を自分で決める。

**前提確認**
- [ ] Day 1 の「該当なしフラグ」分岐が `Chat.razor` にある（Day4-4 で用意）
- [ ] `UnclassifiedQueueEntry.cs` の列を確認（`RawQuery` / `FreeformBody` / `QueryEmbedding` / `Status='pending'` / `ReviewedBy` / `ReviewedAt` / `ReviewNote`）
- [ ] [`05:30-35`](../05_search_classification.md)（⑦）と [`05:162`](../05_search_classification.md)（unclassified は「分類できなかった」軸）を読んだ

**手順**
1. `Chat.razor` に該当なし時のステップ（例: `ChatStep.Unclassified`）を追加し、自分で書く:
   ```razor
   case ChatStep.Unclassified:
       <h2>新規問題として登録</h2>
       <p>該当する問題が見つかりませんでした。内容を書いていただければ担当者が確認します。</p>
       <InputTextArea @bind-Value="_freeform" />
       <button @onclick="RegisterUnclassified">送信</button>
       break;
   ```
2. 登録ロジックの骨子を自分で書く:
   ```csharp
   private async Task RegisterUnclassified()
   {
       var tenantId = (Guid)Http.HttpContext!.Items["TenantId"]!;  // クライアント由来は信頼しない
       Db.UnclassifiedQueue.Add(new UnclassifiedQueueEntry
       {
           Id = Guid.NewGuid(),
           TenantId = tenantId,
           RawQuery = _query,            // ③ で入れた自然言語入力
           FreeformBody = _freeform,     // 利用者の追記
           Status = "pending",           // admin レビュー待ち（Day4-13）
           CreatedAt = DateTimeOffset.UtcNow,
           // QueryEmbedding は ClassifyService が出していれば流用、無ければ NULL のまま
       });
       await Db.SaveChangesAsync();
       // 完了 UI へ。暗黙シグナル「どれでもない」= 候補ミスマッチを記録
   }
   ```
3. 「どれでもない」（候補からの離脱、[`05:170`](../05_search_classification.md)）からもこのステップに合流できる導線を Day4-9 の確認画面手前に置く。

**完了確認**
- [ ] 該当なし → 自由入力 → 送信で `unclassified_queue` に `status='pending'` の行が入る
- [ ] 自テナントの行としてのみ作られる（`WITH CHECK` で別テナントは拒否）
- [ ] `RawQuery`（元クエリ）と `FreeformBody`（追記）が両方保存される

**詰まったら**
- `WITH CHECK` 違反で 500 → tenant_id を `Items` から取れていない（Sprint 1 day3 と同じ）

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## Day4-13. admin レビュー画面（マスタ追加 or 破棄 + コメント）[AI]

**目的**
[`05:34`](../05_search_classification.md) + [`08_features.md:62-65`](../08_features.md)。admin が `unclassified_queue` の `pending` 行を一覧し、各行を「マスタ追加（Knowledge 作成へ誘導）」or「破棄」し、`ReviewNote` にコメントを残せる画面。Day4-12 で自分が決めたキューの形（`Status` / `ReviewedBy` / `ReviewedAt` / `ReviewNote`）を消費する。

**前提確認**
- [ ] Day4-12 完了（`pending` 行が作られる）
- [ ] admin ロール判定の方法（Day4-11 と同じ）

**AI 依頼テンプレ**
```
admin 向けの未分類キュー レビュー画面を作ってほしい。Sprint 1 の Categories CRUD（Components/Pages/Categories/Index.razor）
と同じ書き方・配置に合わせる。

仕様（design/05_search_classification.md:34 / design/08_features.md:62-65 / UnclassifiedQueueEntry.cs が正）:
- ルート: /t/{Slug}/admin/unclassified（admin ロールのみ。member は 403 相当の表示）
- 一覧: Status='pending' の UnclassifiedQueueEntry を CreatedAt 降順で表示（RawQuery / FreeformBody / CreatedAt）。
- 各行のアクション:
  1) マスタ追加: ReviewNote を入れて Status='accepted'、ReviewedBy=現在ユーザー、ReviewedAt=now を保存し、
     Knowledge 作成ページ（既存 /t/{Slug}/... の knowledge 新規。無ければ Categories へ暫定リンク）へ RawQuery を
     プリフィルする想定で遷移（プリフィルは TODO 可）。
  2) 破棄: ReviewNote 必須で Status='discarded'、ReviewedBy/ReviewedAt を保存。
- tenant_id でフィルタしない（RLS）。書き込みの tenant_id は HttpContext.Items から（クライアント信頼しない）。
- ReviewedBy は現在ユーザー id（取得方法は既存に合わせる）。

制約（backend/CLAUDE.md）: @rendermode InteractiveServer / [Authorize] / EditForm でコメント入力 /
AsNoTracking で一覧読み取り / Nullable enable / 警告ゼロ / System.Text.Json。
```

**自分の確認ポイント**
- [ ] admin で `pending` 一覧が出る／member ではアクセスできない
- [ ] 「マスタ追加」で `accepted` + `ReviewedBy/At` 保存、Knowledge 作成へ誘導
- [ ] 「破棄」で `discarded` + コメント保存（コメント必須）
- [ ] 他テナントの未分類行が見えない（RLS）

---

## Day 3 終了チェックリスト

- [ ] フォーム → 確認 → 起票（`SubmitAsync`）が通り、外部チケット URL が出る
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
