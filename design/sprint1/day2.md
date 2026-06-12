# Sprint 1 Day 2 作業指示書（2026-06-13）

> テーマ: **抽出・正規化・集計**（seed 辞書 → 2 層抽出 → term×day×locale 集計）
> 完了時の状態: `out/stats.json`（daily_term_stats 相当）が出て、抽出ノイズ率の実測メモがある
> 推定所要: 4〜6 時間

## Day2-1. seed 辞書の候補生成 [AI] [ML]

**目的**
F9 用語辞書の初期ブートストラップ（design/11 Q4 の (a) 案）。キュレート済みタグから候補を機械生成し、人手キュレーションの叩き台にする。

**前提確認**
- [ ] Day1 の `out/qiita-raw.jsonl` と `out/verify.md`（タグ頻度トップ）がある

**AI 依頼テンプレ**
```
spike/dict/build-seed.ts を書いて。仕様:
- out/qiita-raw.jsonl の全記事から tags[].name を集計し、出現 3 回以上のタグを候補にする
- 正規化: NFKC + lowercase + trim を slug 候補に、元表記を display に
- 出力: spike/dict/seed-candidates.json（[{ slug, display, count }] を count 降順）
- 実行: npm run seed-dict。候補数を print
```

**完了確認**
- [ ] `dict/seed-candidates.json` に数百件の候補が出ている

---

## Day2-2. 辞書のキュレーション [自分] [ML] [設計]

**目的**
候補から **terms / aliases / excluded / ambiguous** を自分の目で選別する。F9（用語辞書・正規化）の中身そのもので、**ここの判断の質がトレンドの質を決める**。

**自分で書く理由**
「`go` は曖昧」「`rails` と `ruby-on-rails` は同一」みたいな判断は技術の土地勘そのもの。委譲すると後で説明できない。

**前提確認**
- [ ] `dict/seed-candidates.json` がある
- [ ] [design/05](../05_search_classification.md) §正規化（F9 連動）を読んだ

**手順**
1. `spike/dict/terms.json` を作る。形式は `extract.ts` の `DictEntry`（`slug` / `display` / `aliases[]` / `ambiguous?`）。候補から **150〜300 語**選ぶ（一般語・サイト固有語は捨てる）
2. 表記揺れを aliases に畳む（最低限: `k8s`→kubernetes, `js`→javascript, `ts`→typescript, `golang`→go, `postgres`→postgresql, `rails`→ruby-on-rails 等。HN 側で出る英語表記も意識）
3. `spike/dict/excluded.json`（一般語: app, data, web, server, code, ai ← ai は判断が分かれる。迷ったら入れて findings にメモ）
4. `spike/dict/ambiguous.json`（`{ "go": ["golang","goroutine","module","gopher"], "rust": ["cargo","crate","rustc","memory"], "swift": ["ios","xcode","apple"] , ...}` 形式の共起ホワイトリスト）。terms.json で `ambiguous: true` を付けた slug ごとに必ずここにも共起語を書く（フラグだけだとタイトル層で一切ヒットしなくなり、リストだけだと参照されない — ペアで保守）

**完了確認**
- [ ] terms.json 150 語以上、aliases に揺れ吸収が 20 組以上
- [ ] ambiguous 語が 5 個以上リストアップされている

**詰まったら**
- 選別に時間がかかりすぎる → トップ 150 をまず通し、残りは Day2-5 の未知語候補レビューで育てる（完璧を狙わない）

---

## Day2-3. 2 層抽出器 [自分-B] [ML]

**目的**
design/05 の抽出 2 層（(a) タグ→直接 / (b) タイトル→辞書マッチ + 曖昧性解消）を実装し、**実テキストでの誤爆**を体験する。

**自分で書く理由**
抽出はこのプロダクトの ML の核。単語境界・大文字小文字・曖昧語の扱いを自分の手で書かないと、本実装の設計判断（RE2 採用や NER 拡張）ができない。

**前提確認**
- [ ] `spike/extract.ts` の骨格と `dict/*.json` 3 ファイルがある

**手順**
1. `extract()` を実装。(a) 層: タグを正規化して alias と完全一致。(b) 層: タイトルに対し alias の単語境界マッチ（`\b` は `-`/`.` を含む技術語で効かないことがある — 区切り文字クラスを自分で決めて findings にメモ）
2. ambiguous は共起ホワイトリストが同一タイトル内にある時だけ採用
3. `unknownCandidates()` を実装（CamelCase / `xxx.js` / `@scope/pkg` / 全大文字頭字語。1 タイトル 500 文字打ち切り）
4. 適当な 20 タイトルで動かして print 目視

**完了確認**
- [ ] 1 文書 × 1 term が 1 occurrence になっている（タグとタイトル両ヒットでも 1）
- [ ] `go` 単独のタイトル（例: "Let's go to..."）が**ヒットしない**こと、`goroutine` 併記でヒットすることを確認

**詰まったら**
- 部分一致誤爆（`java` が `javascript` に当たる）→ 単語境界の区切り文字クラスを見直す。先に長い alias からマッチして除去する手もある
- 正規表現が落ちる / 当たらない → alias 内の特殊文字（`+` や `.`）はエスケープしてから埋め込む（c++ / node.js / .net が定番の罠）

---

## Day2-4. 集計（daily_term_stats 相当） [自分-A] [BE]

**目的**
Occurrence[] → term×day×locale の `mentions` / `distinctSources` / `share`。BigQuery でやる集計をメモリで予行する。

**自分で書く理由（A: 応用）**
Map での group-by は Day1-2/2-3 で書いた JS の応用。ヒントだけで書けるはず。

**手順**
1. `spike/aggregate.ts` のヒントコメント通りに実装（2 パス: 集計 → share）
2. **書き終えてから** [design/sprint1/refs/aggregate.ref.ts](refs/aggregate.ref.ts) と見比べて答え合わせ

**完了確認**
- [ ] share の day×locale 合計が ≈1.0 になる（検算）
- [ ] ref と比べて本質差がない（差があったら理由を説明できる）

---

## Day2-5. パイプライン結線 + 品質ダンプ [AI] [BE] [TEST]

**目的**
raw → normalize → extract → aggregate を 1 コマンドにし、抽出品質を目視できる材料を出す。

**AI 依頼テンプレ**
```
spike/run.ts を書いて。仕様:
- out/hn-raw.jsonl + out/qiita-raw.jsonl を読み、types.ts の normalizer → extract.ts の extract/unknownCandidates → aggregate.ts の aggregate を通す
- 出力: out/occurrences.json / out/stats.json / out/unknown-candidates.json（count 降順トップ 200）
- 加えて品質ダンプ out/quality-sample.md: ランダム 50 タイトルについて「タイトル / 抽出された term / 層(tag|title)」の表。
  目視で ○× を付けられる Markdown チェックボックス付き
- 実行: npm run run。各出力の件数サマリを print
```

**完了確認**
- [ ] `out/stats.json` が出て、上位 term（例: javascript, python, react…）が直感に合う
- [ ] `out/quality-sample.md` の 50 件に自分で ○× を付け、**ノイズ率を findings.md §3 に記録**（ここが今日の成果物）
- [ ] unknown-candidates のトップ 50 を眺めて、辞書に昇格させる語があれば terms.json に足して再実行

---

## Day 2 終了チェックリスト

- [ ] `dict/`（terms / excluded / ambiguous）が揃い、150 語以上
- [ ] `npm run run` で raw → stats まで一気に通る
- [ ] 50 件目視のノイズ率が findings.md §3 にある（数字で）
- [ ] 未知語候補から辞書へのフィードバックを 1 周回した

## Day 3 への引き継ぎメモ

- stats.json が検知（Day3-1）の入力。30 日 × 150 語のシリーズができている
- ノイズ率が高かった層（たぶん (b) タイトル層）はどの誤爆型かを findings に書いておく → 検知ノイズの解釈に使う
