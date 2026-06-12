# Sprint 1 Day 1 作業指示書（2026-06-12）

> テーマ: **実データを手元に置く**（HN 30日 + Qiita 30日 → raw JSONL + 正規化スキーマ）
> 完了時の状態: `spike/out/` に 2 ソースの生データが揃い、正規化関数が通り、データ品質レポートが出る
> 推定所要: 3〜5 時間

スパイクの掟: **テストなし・雑で OK・ただし findings.md にメモを残す**。spike/ のコードは本実装に持ち込まない（設計に反映するのは「学び」だけ）。スパイク完了後は必ず TDD モードに戻る（antipattern #5）。

## Day1-1. spike 環境の起動確認 [自分] [INFRA]

**目的**
Node22 + tsx の最小環境で「TS ファイルを直接実行できる」状態を確かめる。リハビリ枠。

**前提確認**
- [x] `node --version` が v22.x
- [x] `spike/package.json` と骨格ファイル（`types.ts` / `sources/hn.ts` / `extract.ts` / `aggregate.ts` / `detect.ts` / `findings.md`）がある

**手順**
1. `cd spike && npm install`（tsx が入る）
2. `npx tsx -e "console.log('ok', process.version)"` で実行確認
3. `sources/hn.ts` の `UA` 定数の `REPLACE_ME` を自分の連絡先（メール or GitHub URL）に書き換える

**完了確認**
- [x] `npx tsx -e ...` が `ok v22.x` を出す
- [x] UA に連絡先が入った（礼儀正しいクローラの第一歩。design/06 の作法）

**詰まったら**
- `tsx: command not found` → `npx tsx` で叩く（PATH の問題）
- ESM エラー → `package.json` の `"type": "module"` を確認。`require` は使わない

---

## Day1-2. HN Algolia: 時間窓スライドで 30 日取得 [自分-B] [BE]

**目的**
取得上限（1 クエリ 1000 件天井）を**自分の手で踏んで**、時間窓スライドで乗り越える。本実装の `discover` 上限ハンドリング（design/06）の予行で、実務のページング戦略そのもの。

**自分で書く理由**
「上限のある一覧 API から期間を網羅する」は収集エンジニアの基本動作。面接で「Algolia の 1000 件天井をどう回避したか」を体験談で語れる。

**前提確認**
- [ ] [design/14_data_sources.md](../14_data_sources.md) §1（HN Algolia）を読んだ
- [ ] `spike/sources/hn.ts` の骨格（TODO コメント）を確認した

**手順**
1. `fetchWindow()` を実装（骨格のコメント通り。URLSearchParams / fetch / `data.hits`）
2. まず**1 回だけ**叩いて `hits.length` と先頭の `title` / `created_at_i` を print（形を見る）
3. `main()` の窓スライドループを実装（cursor = バッチ最小 `created_at_i`、300ms sleep、JSONL 追記）
4. `npm run hn` で 30 日分を取得（`spike/` ディレクトリで実行）

**完了確認**
- [ ] `out/hn-raw.jsonl` ができ、数千件オーダー（points>=5 の 30 日なら ~5,000〜9,000 件）
- [ ] console に件数・最古/最新日時が出て、約 30 日をカバーしている
- [ ] リクエスト数が ~10 回前後で済んだ（1000 件/窓が効いている）

**詰まったら**
- hits が毎回同じ → cursor の更新忘れ（バッチ最小 `created_at_i` を次の `<` に入れる）
- 0 件で即終了 → `numericFilters` のカンマ区切り・比較演算子を確認（[14 §1](../14_data_sources.md) の実例 URL と見比べる）
- フィルタが正しいのに 0 件 → 単位を疑う。`created_at_i` は Unix **秒**、`Date.now()` はミリ秒（1000 で割ってから窓を組む）
- 出力が巨大 → JSONL は 1 行 1 hit の `JSON.stringify`。pretty print しない

---

## Day1-3. Qiita: 30 日分の記事取得 [AI] [BE]

**目的**
JP 側の源泉。タグ付き・人気度付きの記事 30 日分を raw JSONL に保存する。

**前提確認**
- [ ] Qiita のアクセストークンを発行（`qiita.com/settings/applications`、read 権限のみ・無料）→ `spike/.env` に `QIITA_TOKEN=...`（`.gitignore` に `.env` があるか確認）
  - 無認証は 60 req/hr で 30 日分（~40 ページ）が窮屈。トークンで 1000 req/hr に

**AI 依頼テンプレ**
```
spike/sources/qiita.ts を書いて。仕様:
- design/14_data_sources.md §3 が正。GET https://qiita.com/api/v2/items?per_page=100&page=N
- ヘッダ: Authorization: Bearer ${process.env.QIITA_TOKEN}（未設定なら付けない）、連絡先入り User-Agent
- 冒頭で process.loadEnvFile("./.env") を try/catch で呼ぶ（Node 22 標準。.env が無ければ無認証のまま続行）
- 各レスポンスの Rate-Remaining ヘッダを console に出し、10 を切ったら Rate-Reset まで待つ
- 各記事の created_at（+09:00）が 30 日前より古くなったら停止
- 1 行 1 記事の JSONL で spike/out/qiita-raw.jsonl に追記。リクエスト間 500ms sleep
- 実行: npm run qiita。完了時に件数・ページ数・日付範囲を print
```

**完了確認**
- [ ] `out/qiita-raw.jsonl` に 30 日分（数千件）
- [ ] 403/429 にならず完走（Rate-Remaining の推移を findings.md §1 にメモ）

**詰まったら**
- 401 → `Bearer ` プレフィクスと `.env` の読み込み（tsx は `node --env-file` 相当が無いので `process.loadEnvFile?.()` か手動パース）
- page=100 超え → 30 日分なら通常届かない。届いたら `query=created:>=YYYY-MM-DD` で絞る（[14 §3](../14_data_sources.md)）

---

## Day1-4. 正規化スキーマと normalizer [自分-B] [設計] [BE]

**目的**
design/06 の `CollectedItem` を**実データに当てて**過不足を見つける。スキーマ検証こそがこのスパイクの主目的。

**自分で書く理由**
「実データを見てスキーマを直す」判断は委譲できない。ここの気づきが design/03・06 の改訂になる。

**前提確認**
- [ ] `out/hn-raw.jsonl` / `out/qiita-raw.jsonl` がある
- [ ] `spike/types.ts` の骨格を確認した

**手順**
1. `types.ts` の `fromHnHit()` / `fromQiitaItem()` を実装（骨格のヒント通り。**UTC 正規化**と **`${source}:${externalId}`** が要点）
2. 使い捨てスクリプトで各 raw の先頭 100 件を normalizer に通し、5 件 print して目視
3. 「入らなかった情報・無駄なフィールド・型で詰まった点」を `findings.md` §2 に書く

**完了確認**
- [ ] 2 ソースとも normalizer が例外なく通る（url null・タグ空も含む）
- [ ] `publishedAt` が両ソースとも UTC ISO で揃っている（Qiita の +09:00 が消えている）
- [ ] findings.md §2 に 1 行以上メモがある

**詰まったら**
- Qiita の日付がズレる → `new Date("...+09:00").toISOString()` で UTC 化してから `slice(0, 10)`（先に slice すると JST 日付になる）
- JSONL の読み方 → `readFileSync` で全読み → `split("\n")` → `filter(Boolean)` → 1 行ずつ `JSON.parse`（このサイズなら全読みで足りる）

---

## Day1-5. データ品質レポート [AI] [TEST]

**目的**
明日の辞書づくり・抽出の材料になる「データの素性」を数字で見る。

**AI 依頼テンプレ**
```
spike/verify.ts を書いて。out/hn-raw.jsonl と out/qiita-raw.jsonl を読み、
spike/types.ts の normalizer を通した上で以下をレポート:
- ソース別: 件数 / 日付範囲 / 日別件数ヒストグラム（テキストで可）
- HN: url null 率。Qiita: タグ 0 件率・タグ総種類数・頻度トップ 30
- externalId の重複件数（dedup の必要性確認）
- popularity の分布（中央値・p90）
実行: npm run verify。結果は console と out/verify.md の両方に出す
```

**完了確認**
- [ ] `out/verify.md` が出て、Qiita タグ頻度トップ 30 が見える（明日の seed 辞書の種）
- [ ] 重複 externalId が 0 か僅少（多ければ Day2 で dedup を足す判断）

---

## Day 1 終了チェックリスト

- [ ] 2 ソースの raw JSONL（計 ~10k 件オーダー）が `out/` にある
- [ ] normalizer が両ソースで通り、UTC 正規化を確認した
- [ ] `out/verify.md` でデータの素性（タグ頻度・分布）が見えている
- [ ] findings.md §1（データ量）・§2（スキーマ）に実測メモが入った

## Day 2 への引き継ぎメモ

- Qiita タグ頻度トップ（verify.md）が seed 辞書の最初の材料
- HN はタグ無し＝タイトル辞書マッチ（b 層）が主役になる前提で Day2 の抽出を組む
