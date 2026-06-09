# Sprint 5 Day 2 作業指示書（2026-06-05）

> テーマ: **ウィジェット本体と分析画面**
> 完了時の状態: 利用者サイトに `<script>` 一行でチャットボットが出る（shadow DOM で利用者サイトの CSS と隔離）、テナント/Origin 単位のレートリミットが効く、admin が利用ログ分析（件数・match_strategy 分布・上位 N・未分類推移・低確信度比率）を見られる
> 推定所要: 6〜8 時間

---

## 5-2-1. 前提確認 + 集計クエリ定義のメモ化 [自分] [設計]

**目的**
Day1 の匿名 API が叩けることを実機確認したうえで、Day2 で AI に投げる前に「分析画面で何を数えるか」を SQL レベルで明文化する。`09_task_split.md:107` のステップ 2（仕様の箇条書き）に相当する、本日一番大事な下準備。

**自分で書く理由**
「低確信度とは何 score 未満か」「上位 N は何で並べるか」は**指標の定義**であり、面接で「この数字をどう定義した？」と必ず聞かれる。定義を自分で握れば、UI は AI に複製させても説明責任を負える。

**前提確認**
- [ ] Day1 完了（`/api/widget/classify` が candidates + `confidence_score` を返す）
- [ ] `design/05_search_classification.md:4-35`（`match_strategy` の値: `dropdown`/`keyword`/`hybrid`/`llm`）を読んだ
- [ ] `apps/api/src/types/inquiry.ts` の列（`matchStrategy` / `confidenceScore` / `matchedKnowledgeId` / `status` / `createdAt`）と `infra/db/migrations/0001_schema.sql:140-158` を確認

**手順（疎通確認）**
1. `pnpm dev`（または `make up`）後、curl で Day1 の API をスモーク:
   ```bash
   curl -H "X-Widget-Key: <key>" http://localhost:8080/api/widget/categories
   curl -H "X-Widget-Key: <key>" -H "Content-Type: application/json" \
        -d '{"query":"パスワード忘れた"}' http://localhost:8080/api/widget/classify
   ```
2. 数件 `inquiries` を作って分析の母数を用意（classify → inquiries POST を 5〜10 回）

**集計クエリ定義（このメモを `design/sprint5/` には残さず、PR の説明か Day2-4 の AI 依頼にそのまま使う）**

集計は BigQuery（DWH）に寄せる（Postgres 側の負荷を下げるため）。Postgres 直接で良い軽量クエリは Node API の DB 接続経由でも可。いずれも `app.tenant_id` 経路（admin がログインして見る画面）。RLS が自動で当該テナントに絞る前提なので `WHERE tenant_id = ?` は書かない（Postgres 経路の場合）。

A〜E の 5 本を**自分で SQL/BigQuery SQL に起こす**。何を数えるか・どのテーブル/列・並び・閾値だけ示す。完成クエリはここには置かない（指標を自分の言葉と SQL で説明できることが本タスクの目的）:

| 指標 | 数えるもの | 主なテーブル / 列 | 並び・粒度・制約 |
|---|---|---|---|
| (A) 問い合わせ件数 | 日次の件数 | `inquiries` / `created_at` | `date_trunc('day', created_at)` で集計、直近 30 日。週次/月次は単位を変えるだけ |
| (B) match_strategy 分布 | 戦略ごとの件数 | `inquiries` / `match_strategy` | NULL を `'none'` に寄せて group by、件数降順 |
| (C) 上位 N 問題 | よく確定した問題 | `knowledge_entries` / `match_count` | `match_count` 降順 上位 10 |
| (D) 未分類キュー推移 | 日次の流入件数 | `unclassified_queue` / `created_at` | 日次 count、直近 30 日 |
| (E) 低確信度比率 | 全体に占める低確信の割合 | `inquiries` / `confidence_score` | `count(*) FILTER (WHERE ...)` で「低確信件数 / scored 件数」を % 化。0 除算は `nullif` で回避 |

ヒント:
- (E) の閾値 `THRESHOLD_LOW` は `05_search_classification.md:97-101` の値を流用する（暫定 0.5）。**この数値をここで定義し直さない**（5-2-4 / Day3-1 と同じ値を共有する）
- (E) は「低確信件数」と「scored 件数（`confidence_score IS NOT NULL`）」を `FILTER` で同時に数えると 1 クエリで比率が出る

> 指標定義の判断: (C) は「`match_count` 順 = 起票確定が多い問題」とする。`0001_schema.sql:221-239` のトリガーが `status='created'` 確定時に `match_count` を +1 する仕様なので、これは「実際に役立った FAQ」を意味する。(E) の閾値は分類フローの `THRESHOLD_LOW` と同じ値を使う（二重定義しない）。

**完了確認**
- [ ] 5 クエリ（A〜E）を psql または BigQuery コンソールで実行して期待どおりの形で返る
- [ ] (E) の `THRESHOLD_LOW` を分類フロー側の閾値と一致させた（マジックナンバーを別々に持たない）

**AI 依頼テンプレ**: なし（自分で定義を書く範囲。このメモを 5-2-4 / Day3-1 で再利用する）

---

## 5-2-2. `embed.js`（shadow DOM 隔離・`<script>` 一行）[AI] [FE]

**目的**
利用者サイトに `<script src=".../api/widget/embed.js?key=...">` 一行を貼るだけで、右下にチャットボタン → 開くとチャット UI が出る。利用者サイトの CSS と衝突しないよう **shadow DOM** で隔離する。中身は Day1 の匿名 API を叩くだけ。

**前提確認**
- [ ] 5-2-1 完了、`/api/widget/classify` などが叩ける
- [ ] 配信先 `apps/web/dist/embed.js`（TypeScript バンドル）のパスを AI に伝えられる（Day1 の引き継ぎメモ参照）
- [ ] `apps/web/` の pnpm/TypeScript ビルド設定（`vite.config.ts` 等）を確認

**AI 依頼テンプレ**
```
TypeScript（apps/web/ 配下の専用 embed パッケージ、バンドル後は単一 JS ファイル）で埋め込みウィジェット embed.ts を書いてほしい。ビルド成果物 apps/web/dist/embed.js を Node API が /api/widget/embed.js として配信する。利用者サイトは <script src="https://<host>/api/widget/embed.js?key=<public-key>" defer></script> 一行を貼るだけで動く。

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
- バンドル設定は vite.config.ts（または esbuild 設定）に embed エントリを追加する形で
```

**自分の確認ポイント**
- [ ] 利用者サイト想定の HTML（Bootstrap 等を読み込んだページ）に貼って、ウィジェットの見た目が崩れない / 逆にページ側も崩れない（shadow DOM 隔離が効いている）
- [ ] fetch がすべて `X-Widget-Key` ヘッダ付き・`credentials:'omit'`
- [ ] JS から `tenant_id` を送っていない

**完了確認**
- [ ] ローカルの素の HTML に `<script>` 一行 → 右下にボタン → チャットが回る
- [ ] CSS の強い別ページに貼っても双方崩れない

---

## 5-2-3. レートリミット（テナント / Origin 単位）[AI] [BE]

**目的**
公開鍵が漏れても乱用されないよう、`tenant_public_keys.rate_limit_rpm` を上限に `/api/widget/*` をレート制限する。テナント（鍵）単位 + Origin 単位。

**前提確認**
- [ ] 5-2-2 完了
- [ ] Day1 で `req.widgetKey`（`TenantPublicKey` 本体）が積まれていること

**AI 依頼テンプレ**
```
Node/Express（TypeScript）で、/api/widget/* に対する DB ベースの固定窓レートリミットを追加してほしい（Phase2 で Redis に置き換える想定。今は Postgres でカウント管理）。

要件:
- パーティションキー: 公開鍵の keyHash + Origin の組（テナント単位かつ Origin 単位）
- 上限: その鍵の TenantPublicKey.rateLimitRpm（req.widgetKey から取得）を 1 分あたりの許可数とする固定窓（window=1min）
- 鍵が解決できないリクエスト（widgetAuthMiddleware で 401 になる経路）はレートリミッタに乗せない
- 超過時は 429 + Retry-After ヘッダ
- ミドルウェアとして apps/api/src/middleware/widgetRateLimit.ts に実装し、widgetAuthMiddleware の後に登録する（鍵が解決済みの状態で評価）
- /api/widget ルーターに適用する

あわせて「同一鍵で rate_limit_rpm+1 回叩くと最後だけ 429」を確認する統合テストを apps/api/src/__tests__/widgetRateLimit.test.ts に書いて（Vitest or Jest）。
```

**自分の確認ポイント**
- [ ] パーティションが鍵 + Origin になっている（テナント A の枠をテナント B が食わない）
- [ ] `rateLimitRpm` を DB 値から読んでいる（ハードコードしていない）
- [ ] 429 に `Retry-After` が付く

**完了確認**
- [ ] `rate_limit_rpm` を小さく設定したテナントで連打 → 上限超えで 429
- [ ] 別 Origin / 別鍵は独立にカウントされる

---

## 5-2-4. 利用ログ分析画面 [AI、集計クエリ定義は自分] [FE] [BE]

**目的**
5-2-1 で自分が定義した A〜E の集計を、admin 向けページ `/t/{slug}/analytics` に表示する。新しい指標は作らない、**自分の定義を UI 化するだけ**。

**前提確認**
- [ ] 5-2-1 の集計クエリ定義（A〜E）が手元にある（BigQuery SQL または Postgres SQL）
- [ ] admin 限定ページであること（JWT ロール `tenant_admin` チェック、Sprint 1 のロール方針）

**AI 依頼テンプレ**
```
React（TypeScript、apps/web/）で admin 向け利用ログ分析ページ apps/web/src/pages/Analytics.tsx（ルート /t/:slug/analytics）を書いてほしい。データは Node API（apps/api/）の GET /api/analytics/:slug/* エンドポイント経由で取得する。Node API 側は BigQuery クライアントで集計クエリを発行し、JWT の tenant_id で絞る（BigQuery クエリパラメータ化）。JWT を持たないアクセスは 401 を返す。

表示する 5 ブロック（集計クエリの定義は以下に固定。勝手に指標を足さない）:
A) 問い合わせ件数: inquiries を DATE_TRUNC('day'|'week'|'month', created_at) で集計。期間切替（30日/12週/12か月）のトグル。簡易な棒グラフ or テーブル。
B) match_strategy 分布: COALESCE(match_strategy,'none') で group by count。
C) 上位 10 問題: knowledge_entries を match_count 降順で 10 件（id/name/match_count）。
D) 未分類キュー推移: unclassified_queue を日次 count、直近 30 日。
E) 低確信度比率: confidence_score < 0.5 の件数 / confidence_score IS NOT NULL の件数（%）。閾値 0.5 は定数 THRESHOLD_LOW として 1 箇所に置く。

注意:
- すべて読み取り専用（INSERT/UPDATE は行わない）
- グラフライブラリは追加せず、まずは <table> + 簡易インラインバーで OK（依存を増やさない）
- 期間トグルは DATE_TRUNC の単位だけ変える
- BigQuery SA の認証情報は Secret Manager / 環境変数（GOOGLE_APPLICATION_CREDENTIALS）から取る
```

**自分の確認ポイント**
- [ ] (E) の閾値 0.5 が 1 箇所定義（`THRESHOLD_LOW`）で、分類フロー側の `THRESHOLD_LOW` と整合
- [ ] (C) が `match_count` 降順（自分の定義どおり）
- [ ] BigQuery クエリに `tenant_id` パラメータが渡っており別テナントの数字が混ざらない
- [ ] グラフライブラリ等の重い依存を勝手に足していない

**完了確認**
- [ ] `/t/{slug}/analytics` で 5 ブロックが当該テナントの数字で出る
- [ ] 別テナントでログインすると数字が変わる（テナントフィルタが効いている）
- [ ] member ロールではアクセスできない

---

## Day 2 終了チェックリスト

- [ ] 素の HTML に `<script>` 一行でウィジェットが出て、shadow DOM で双方の CSS が崩れない
- [ ] チャットが Day1 の匿名 API を叩いて回る（classify → inquiries / unclassified）
- [ ] `rate_limit_rpm` 超過で 429、鍵 + Origin 単位で独立カウント
- [ ] `/t/{slug}/analytics` に A〜E の 5 ブロックが当該テナントの数字で表示される（BigQuery 集計）
- [ ] 低確信度の閾値が分類フローと一箇所で共有されている

## Day 3 への引き継ぎメモ（自分宛て）

- 低確信度の閾値（`THRESHOLD_LOW`）は Day3-1 のナレッジギャップでも同じ定数を使う（二重定義しない）
- ナレッジギャップは「分類はしたが自信が低い」= `inquiries.confidence_score` が低い行。未分類キュー（分類できなかった）とは別軸（`05_search_classification.md:156-162`）
- 匿名ポリシー（`0004`）を入れたので、Day3-5 で「`app.tenant_id` の既存分離が壊れていない」E2E 回帰が必要
