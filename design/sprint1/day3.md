# Sprint 1 Day 3 作業指示書（2026-06-14）

> テーマ: **検知と評価、設計への反映**（スパイクの答え合わせ）
> 完了時の状態: 新出/急上昇の検知リストが出て、目視評価とパラメータ感度が findings.md にまとまり、design への反映案と Sprint 2 ゴールが書けている
> 推定所要: 4〜6 時間

## Day3-1. 検知ロジック（emerging / rising） [自分-B] [ML]

**目的**
スパイクの本丸。「**実データで信号が立つか**」を確かめる。F2 の判定式（design/05）を単純統計版で書く。

**自分で書く理由**
検知式は TrendScope の心臓で、面接で一番突っ込まれる場所。z-score の分母が暴れる感覚・低カウントの怖さは自分の手で踏むしかない。

**前提確認**
- [ ] `out/stats.json`（Day2-5）がある
- [ ] `spike/detect.ts` の骨格と `PARAMS` を確認した（**spike は N_MIN=2**。理由は骨格コメント）

**手順**
1. `detect()` を実装（骨格コメント通り。emerging 優先 → rising）
2. 窓関数（baseline 30〜8 日前 / 直近 7 日）は day 文字列の比較でよい（全部 UTC の "YYYY-MM-DD" なので辞書順比較が成立する）
3. `evidence` に baseline 合計・直近合計・distinctSources・z の素材を入れる（Day3-3 の目視評価で使う）

**完了確認**
- [ ] emerging / rising がそれぞれ 1 件以上出る（0 件なら PARAMS を緩めて出るまで下げ、その値を記録）
- [ ] σ=0 や mentions 不足のスキップで例外が出ない

**詰まったら**
- 全部 emerging になる → baseline 窓のフィルタが効いていない（day 範囲の比較を確認）
- z が NaN → σ=0 ガードの位置

---

## Day3-2. 検知レポート出力 [AI] [BE]

**AI 依頼テンプレ**
```
spike/report.ts を書いて。仕様:
- out/stats.json を読み、spike/detect.ts の detect() を呼ぶ
- console に 2 つの表: 「新出（emerging）」「急上昇（rising）」。
  列: term / locale / score / 直近7日 mentions / distinctSources / baseline 合計
- out/detections.json に evidence 込みで保存
- ついでに mentions 合計トップ 20 の「定番」表も出す（検知と対比して眺める用）
- 実行: npm run report
```

**完了確認**
- [ ] 表が出て、定番（react 等）が emerging/rising に**混ざっていない**ことが一目で分かる

---

## Day3-3. 目視評価とパラメータ感度 [自分] [ML] [TEST]

**目的**
検知リストの**本物/ノイズを自分で判定**し、precision の肌感とパラメータ感度を得る。ここの数字が design/11 Q1〜Q3 の暫定値を置き換える。

**自分で書く理由**
「何が本物のトレンドか」の判定はドメイン判断そのもの。この評価体験が本実装の golden データセット（13 の D1〜D9）の設計に直結する。

**手順**
1. emerging / rising の各検知を 1 件ずつ目視（evidence と、必要なら HN/Qiita を検索）→ 本物 / ノイズを判定
2. ノイズの型を分類（辞書ノイズ？ 単発バズ？ 抽出誤爆？）
3. `PARAMS` を振って再実行: N_MIN を 1（裏取り無し）にするとどれだけ汚れるか / M_MIN 3↔10 / Z_TH 2↔3
4. 結果を findings.md §4 に記録（検知数と本物率の変化）

**完了確認**
- [ ] findings.md §4 に「emerging _件中 本物_」「rising _件中 本物_」と感度メモが埋まった
- [ ] 「N_MIN=1 vs 2 で何が変わったか」を一言で言える（クロスソース裏取りの効果測定）

---

## Day3-4. （任意）GitHub Trending を 3 本目の源泉に [AI] [BE]

**目的**
クロール 1 本を混ぜて distinctSources の上限を 3 にする。新出裏取りの質が上がるか見る。時間が無ければスキップ可。

**AI 依頼テンプレ**
```
spike/sources/trending.ts を書いて。仕様:
- design/14_data_sources.md §6 が正。https://github.com/trending?since=daily を fetch（連絡先入り UA、1 回だけ）
- article.Box-row 相当の行から owner/repo と説明文を抽出（cheerio は入れず正規表現で雑に。
  href="/owner/repo" を持つ h2 ブロックを拾う。壊れたら諦めてログを出す = parser_broken の予行）
- SpikeItem に正規化: source=github_trending, externalId=`owner/repo`, title=`owner/repo 説明文`,
  publishedAt=取得時刻（UTC）, tags=[], locale=global
- out/trending-raw.jsonl に追記。実行: npm run trending
```

**完了確認**
- [ ] ~17 件取れて run.ts に混ざる（occurrences の source が 3 種になる）
- [ ] 取れなかった場合も「セレクタがどう壊れたか」を findings にメモ（それ自体が F8 の学び）

---

## Day3-5. findings 完成 → 設計反映案 → Sprint 2 ゴール [自分] [設計]

**目的**
スパイクの学びを設計に還元して**スパイクを閉じる**。design は直接書き換えず、反映案を findings に書いてから確認して反映する（sprint-plan の掟）。

**手順**
1. `spike/findings.md` の §1〜§4 を読み返し、§5「設計への反映案」を書く:
   - 03: CollectedItem / documents / occurrences のフィールド過不足
   - 05: 抽出の区切り文字・曖昧語の実際・検知式の手応え
   - 06: 窓スライドの実装知見・Trending セレクタの壊れ方
   - 11: Q1〜Q3 のパラメータ暫定値を実測ベースに更新
2. §6 に Sprint 2 のスコープ調整案（このスパイクで「先に作るべき」が変わったものはあるか）
3. AI に「findings.md §5 を design へ反映して」と依頼 → diff をレビュー
4. Sprint 2 のゴールを 5 行で書く（次回 `sprint-plan` 実行の入力）

**完了確認**
- [ ] findings.md が全節埋まっている
- [ ] design 03/05/06/11 に反映 PR 相当の変更が入った（レビュー済み）
- [ ] Sprint 2 ゴール 5 行が書けた

---

## Day 3 終了チェックリスト

- [ ] 検知（emerging / rising）が実データで動き、目視評価の数字がある
- [ ] **スパイクの問い「実データで意味ある信号が立つか」に Yes/No で答えられる**
- [ ] design への反映が済み、findings.md が閉じている
- [ ] Sprint 2 ゴールが確定し、次回 sprint-plan に渡せる
- [ ] **TDD モードに戻る宣言**: spike/ のコードはここで凍結。本実装はテストファーストで書き直す（antipattern #5）

## Sprint 2 への引き継ぎメモ

- spike/ は throwaway。本実装に import しない（参照して書き直すのは可）
- N_MIN の本番較正は源泉 5+ が揃う Sprint 3 以降に再実施
- 検知の golden データセット（13 の D1〜D9）は、今回の stats.json から「本物だった検知」を含む断面を切り出して作ると楽
