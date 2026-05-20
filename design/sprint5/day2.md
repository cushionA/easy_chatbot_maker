# Sprint 5 Day 2 作業指示書（2026-06-05）

> テーマ: **ウィジェット本体と分析画面**
> 完了時の状態: 利用者サイトに `<script>` 一行でチャットボットが出る（shadow DOM で利用者サイトの CSS と隔離）、テナント/Origin 単位のレートリミットが効く、admin が利用ログ分析（件数・match_strategy 分布・上位 N・未分類推移・低確信度比率）を見られる
> 推定所要: 6〜8 時間

---

## 5-2-1. 前提確認 + 集計クエリ定義のメモ化 [自分]

**目的**
Day1 の匿名 API が叩けることを実機確認したうえで、Day2 で AI に投げる前に「分析画面で何を数えるか」を SQL レベルで明文化する。`09_task_split.md:107` のステップ 2（仕様の箇条書き）に相当する、本日一番大事な下準備。

**自分で書く理由**
「低確信度とは何 score 未満か」「上位 N は何で並べるか」は**指標の定義**であり、面接で「この数字をどう定義した？」と必ず聞かれる。定義を自分で握れば、UI は AI に複製させても説明責任を負える。

**前提確認**
- [ ] Day1 完了（`/api/widget/classify` が candidates + `confidence_score` を返す）
- [ ] `design/05_search_classification.md:4-35`（`match_strategy` の値: `dropdown`/`keyword`/`hybrid`/`llm`）を読んだ
- [ ] `Data/Entities/Inquiry.cs` の列（`MatchStrategy` / `ConfidenceScore` / `MatchedKnowledgeId` / `Status` / `CreatedAt`）と `infra/db/migrations/0001_schema.sql:140-158` を確認

**手順（疎通確認）**
1. `make up` 後、curl で Day1 の API をスモーク:
   ```bash
   curl -H "X-Widget-Key: <key>" http://localhost:8080/api/widget/categories
   curl -H "X-Widget-Key: <key>" -H "Content-Type: application/json" \
        -d '{"query":"パスワード忘れた"}' http://localhost:8080/api/widget/classify
   ```
2. 数件 `inquiries` を作って分析の母数を用意（classify → inquiries POST を 5〜10 回）

**集計クエリ定義（このメモを `design/sprint5/` には残さず、PR の説明か Day2-4 の AI 依頼にそのまま使う）**

すべて `app.tenant_id` 経路（admin がログインして見る画面）。RLS が自動で当該テナントに絞る前提なので `WHERE tenant_id = ?` は書かない。

```sql
-- (A) 問い合わせ件数（日次）。週次/月次は date_trunc の単位を変えるだけ。
SELECT date_trunc('day', created_at) AS bucket, count(*) AS n
  FROM inquiries
 WHERE created_at >= now() - interval '30 days'
 GROUP BY 1 ORDER BY 1;

-- (B) match_strategy 分布
SELECT coalesce(match_strategy, 'none') AS strategy, count(*) AS n
  FROM inquiries
 GROUP BY 1 ORDER BY n DESC;

-- (C) 上位 N 問題（match_count 順 = よく確定した問題）
SELECT k.id, k.name, k.match_count
  FROM knowledge_entries k
 ORDER BY k.match_count DESC
 LIMIT 10;

-- (D) 未分類キュー件数の推移（日次、status=pending の流入）
SELECT date_trunc('day', created_at) AS bucket, count(*) AS n
  FROM unclassified_queue
 WHERE created_at >= now() - interval '30 days'
 GROUP BY 1 ORDER BY 1;

-- (E) 低確信度比率: confidence_score < THRESHOLD_LOW の inquiry が全体に占める割合
--     THRESHOLD_LOW は 05_search_classification.md:97-101 の閾値に合わせる（暫定 0.5）。
SELECT
  count(*) FILTER (WHERE confidence_score < 0.5) AS low_n,
  count(*) FILTER (WHERE confidence_score IS NOT NULL) AS scored_n,
  round(100.0 * count(*) FILTER (WHERE confidence_score < 0.5)
        / nullif(count(*) FILTER (WHERE confidence_score IS NOT NULL), 0), 1) AS low_pct
  FROM inquiries
 WHERE created_at >= now() - interval '30 days';
```

> 指標定義の判断: (C) は「`match_count` 順 = 起票確定が多い問題」とする。`0001_schema.sql:221-239` のトリガーが `status='created'` 確定時に `match_count` を +1 する仕様なので、これは「実際に役立った FAQ」を意味する。(E) の閾値は分類フローの `THRESHOLD_LOW` と同じ値を使う（二重定義しない）。

**完了確認**
- [ ] 5 クエリ（A〜E）を psql で実行して期待どおりの形で返る
- [ ] (E) の `THRESHOLD_LOW` を分類フロー側の閾値と一致させた（マジックナンバーを別々に持たない）

**AI 依頼テンプレ**: なし（自分で定義を書く範囲。このメモを 5-2-4 / Day3-1 で再利用する）

---

## 5-2-2. `embed.js`（shadow DOM 隔離・`<script>` 一行）[AI]

**目的**
利用者サイトに `<script src=".../api/widget/embed.js?key=...">` 一行を貼るだけで、右下にチャットボタン → 開くとチャット UI が出る。利用者サイトの CSS と衝突しないよう **shadow DOM** で隔離する。中身は Day1 の匿名 API を叩くだけ。

**前提確認**
- [ ] 5-2-1 完了、`/api/widget/classify` などが叩ける
- [ ] 配信先 `wwwroot/widget/embed.js` のパスを AI に伝えられる（Day1 の引き継ぎメモ参照）

**AI 依頼テンプレ**
```
バニラ JS（ビルド不要・依存なし）で埋め込みウィジェット embed.js を backend/Portfolio.Web/wwwroot/widget/embed.js に書いてほしい。利用者サイトは <script src="https://<host>/api/widget/embed.js?key=<public-key>" defer></script> 一行を貼るだけで動く。

要件:
- 自分自身の <script> の src から ?key= を読み取り、API のベース URL（同オリジン）を決める
- document.body に <div> を 1 つ作り、attachShadow({mode:'open'}) で shadow root を張る。すべての DOM/CSS は shadow root 内に閉じる（利用者サイトの CSS と相互に漏れない）
- 右下に丸いトグルボタン → クリックでチャットパネル開閉
- チャットフロー（Day1 の API を叩く。すべて header X-Widget-Key: <key> を付ける）:
  1. 起動時 GET /api/widget/categories でカテゴリボタンを描画
  2. カテゴリ選択 or 自然言語入力 → POST /api/widget/classify で候補を表示
  3. 候補確定 → POST /api/widget/inquiries
  4. 「どれでもない / 新規問題として」→ POST /api/widget/unclassified
- fetch はすべて { mode: 'cors', credentials: 'omit' }（Cookie を送らない＝匿名）
- エラー時はパネル内に控えめなメッセージ。利用者サイトの console を汚さない
- IIFE で囲みグローバル汚染なし。'use strict'
- スタイルは shadow root 内の <style> に閉じる。!important は使わず、ホスト側に影響しない

注意:
- key はクライアントに見える前提（公開鍵）。秘密情報は載せない
- tenant id は API 側が鍵から決めるので JS からは送らない
```

**自分の確認ポイント**
- [ ] 利用者サイト想定の HTML（Bootstrap 等を読み込んだページ）に貼って、ウィジェットの見た目が崩れない / 逆にページ側も崩れない（shadow DOM 隔離が効いている）
- [ ] fetch がすべて `X-Widget-Key` ヘッダ付き・`credentials:'omit'`
- [ ] JS から `tenant_id` を送っていない

**完了確認**
- [ ] ローカルの素の HTML に `<script>` 一行 → 右下にボタン → チャットが回る
- [ ] CSS の強い別ページに貼っても双方崩れない

---

## 5-2-3. レートリミット（テナント / Origin 単位）[AI]

**目的**
公開鍵が漏れても乱用されないよう、`tenant_public_keys.rate_limit_rpm` を上限に `/api/widget/*` をレート制限する。テナント（鍵）単位 + Origin 単位。

**前提確認**
- [ ] 5-2-2 完了
- [ ] Day1 で `Items["WidgetKey"]`（`TenantPublicKey` 本体）が積まれていること

**AI 依頼テンプレ**
```
ASP.NET Core 8 の組み込みレートリミット（Microsoft.AspNetCore.RateLimiting）で、/api/widget/* に対するレートリミットを追加してほしい。

要件:
- パーティションキー: 公開鍵の KeyHash + Origin の組（テナント単位かつ Origin 単位）
- 上限: その鍵の TenantPublicKey.RateLimitRpm（HttpContext.Items["WidgetKey"] から取得）を 1 分あたりの許可数とする固定窓（FixedWindow, window=1min）
- 鍵が解決できないリクエスト（WidgetAuthMiddleware で 401 になる経路）はレートリミッタに乗せない
- 超過時は 429 + Retry-After ヘッダ
- AddRateLimiter を Program.cs に登録、app.UseRateLimiter() をミドルウェアパイプラインに入れる（WidgetAuthMiddleware の後＝鍵が解決済みの状態で評価）
- /api/widget グループに .RequireRateLimiting(...) を付ける

あわせて「同一鍵で rate_limit_rpm+1 回叩くと最後だけ 429」を確認する統合テストを書いて。
```

**自分の確認ポイント**
- [ ] パーティションが鍵 + Origin になっている（テナント A の枠をテナント B が食わない）
- [ ] `RateLimitRpm` を DB 値から読んでいる（ハードコードしていない）
- [ ] 429 に `Retry-After` が付く

**完了確認**
- [ ] `rate_limit_rpm` を小さく設定したテナントで連打 → 上限超えで 429
- [ ] 別 Origin / 別鍵は独立にカウントされる

---

## 5-2-4. 利用ログ分析画面 [AI、集計クエリ定義は自分]

**目的**
5-2-1 で自分が定義した A〜E の集計を、admin 向けページ `/t/{slug}/analytics` に表示する。新しい指標は作らない、**自分の定義を UI 化するだけ**。

**前提確認**
- [ ] 5-2-1 の集計クエリ定義（A〜E）が手元にある
- [ ] admin 限定ページであること（`[Authorize(Policy="TenantAdmin")]` 相当、Sprint 1 のロール方針）

**AI 依頼テンプレ**
```
Blazor Server（@rendermode InteractiveServer）で admin 向け利用ログ分析ページ Components/Pages/Analytics/Index.razor（ルート /t/{Slug}/analytics）を書いてほしい。データは AppDbContext 経由（RLS が app.tenant_id で自動で当該テナントに絞る前提なので WHERE tenant_id は書かない）。@attribute [Authorize] を付ける。

表示する 5 ブロック（集計の SQL/LINQ 定義は以下に固定。勝手に指標を足さない）:
A) 問い合わせ件数: inquiries を date_trunc('day'|'week'|'month', created_at) で集計。期間切替（30日/12週/12か月）のトグル。簡易な棒グラフ or テーブル。
B) match_strategy 分布: coalesce(match_strategy,'none') で group by count。
C) 上位 10 問題: knowledge_entries を match_count 降順で 10 件（id/name/match_count）。
D) 未分類キュー推移: unclassified_queue を日次 count、直近 30 日。
E) 低確信度比率: confidence_score < 0.5 の件数 / confidence_score IS NOT NULL の件数（%）。閾値 0.5 は定数 ThresholdLow として 1 箇所に置く。

注意:
- すべて AsNoTracking() の読み取り専用
- 集計は LINQ で書けるものは LINQ、複雑なら FromSqlRaw（パラメータ化）
- グラフライブラリは追加せず、まずは <table> + 簡易バーで OK（依存を増やさない）
- 期間トグルは date_trunc の単位だけ変える
```

**自分の確認ポイント**
- [ ] (E) の閾値 0.5 が 1 箇所定義（`ThresholdLow`）で、分類フロー側の `THRESHOLD_LOW` と整合
- [ ] (C) が `match_count` 降順（自分の定義どおり）
- [ ] RLS 任せで `WHERE tenant_id` を書いていない（別テナントの数字が混ざらないことを目視）
- [ ] グラフライブラリ等の重い依存を勝手に足していない

**完了確認**
- [ ] `/t/{slug}/analytics` で 5 ブロックが当該テナントの数字で出る
- [ ] 別テナントでログインすると数字が変わる（RLS が効いている）
- [ ] member ロールではアクセスできない

---

## Day 2 終了チェックリスト

- [ ] 素の HTML に `<script>` 一行でウィジェットが出て、shadow DOM で双方の CSS が崩れない
- [ ] チャットが Day1 の匿名 API を叩いて回る（classify → inquiries / unclassified）
- [ ] `rate_limit_rpm` 超過で 429、鍵 + Origin 単位で独立カウント
- [ ] `/t/{slug}/analytics` に A〜E の 5 ブロックが当該テナントの数字で表示される
- [ ] 低確信度の閾値が分類フローと一箇所で共有されている

## Day 3 への引き継ぎメモ（自分宛て）

- 低確信度の閾値（`ThresholdLow`）は Day3-1 のナレッジギャップでも同じ定数を使う（二重定義しない）
- ナレッジギャップは「分類はしたが自信が低い」= `inquiries.confidence_score` が低い行。未分類キュー（分類できなかった）とは別軸（`05_search_classification.md:156-162`）
- 匿名ポリシー（`0004`）を入れたので、Day3-5 で「`app.tenant_id` の既存分離が壊れていない」E2E 回帰が必要
