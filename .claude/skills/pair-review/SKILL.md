---
name: pair-review
description: commit / PR の前に、変更差分を docs/conventions の規約と ~/.claude/rules/review.md の Adversarial 2 観点（A=正しさ / B=セキュリティ）でレビューする。変更ファイルを言語別に仕分け → 該当する docs/conventions/<lang>.md のレビューチェックリスト + 共通 8 原則を観点にロード → 正しさとセキュリティの 2 視点で見て、substantive な指摘だけを「違反した規約項目名つき」で報告する。規約はリンク参照のみ（コピーしない）。トリガー: 「レビューして」「コミット前に見て」「この差分どう？」「/pair-review」など。
---

# pair-review — 規約準拠の差分レビュー

このスキルは、commit / PR の前に**変更差分**をレビューする。pair-start でペアプロした成果をそのまま投げ込めるよう設計してある（pair-start の Step 6「PR を出すなら /review でレビューしてから」の受け皿）。

**正の情報源**:
- 規約・観点 = [`docs/conventions/`](../../../docs/conventions/README.md)（**この内容をこのファイルに複製しない**。リンクで参照する。規約が直れば自動で追従するため）
- Adversarial 手順 = `~/.claude/rules/review.md`（個人グローバル。A=Correctness / B=Security）
- 設計の正 = [`design/`](../../../design/README.md)

**何をしないか**: 整形（インデント・引用符・import 順）は指摘しない。Prettier / ESLint `--fix` / ruff が機械的に直す領域なので、人のレビューは設計・正しさ・安全に集中する（[`docs/conventions/README.md`](../../../docs/conventions/README.md) §ツールと規約の対応）。

## 進行プロトコル

### Step 1. 差分の取得とスコープ確定

1. 対象を決める（指定が無ければ既定はこの順で探す）:
   - staged 差分（`git diff --cached`）があればそれ
   - 無ければ作業ブランチと main の差分（`git diff main...HEAD` + 未コミット `git diff`）
2. 変更ファイルを**言語別に仕分け**して、レビューで開く規約ファイルを決める:

   | 拡張子 / 場所 | 規約ファイル |
   |---|---|
   | `*.ts`（`apps/api` / `workers` / `packages` / `spike`） | [`typescript.md`](../../../docs/conventions/typescript.md) |
   | `*.tsx`（`apps/web`） | [`react.md`](../../../docs/conventions/react.md) + typescript.md |
   | `*.sql`（`infra/db/migrations`） | [`sql.md`](../../../docs/conventions/sql.md) |
   | `*.py`（`services/embedding` / ML） | [`python.md`](../../../docs/conventions/python.md) |

3. **スパイク（`spike/`）は基準を緩める**。throwaway 前提なので「テスト・型の厳密さ」は問わない。代わりに「findings.md に学びが残っているか」「本実装に持ち込む危険な前提が無いか」を見る（[`design/sprint1_plan.md`](../../../design/sprint1_plan.md) スパイクの掟）。

### Step 2. 観点のロード（参照のみ・コピー禁止）

レビュー前に、以下を**読んで**観点にする。SKILL.md に書き写さない:

1. [`docs/conventions/README.md`](../../../docs/conventions/README.md) の「全スタック共通の原則」8 項目（言語非依存の品質観点 = 命名・定義順・WHY コメント・エラー伝播・早すぎる抽象化・境界検証・秘密・テスト）
2. Step 1 で仕分けた各言語ファイルの **末尾「レビューチェックリスト」節**（これがそのまま観点）

### Step 3. Adversarial レビュー（2 視点）

`~/.claude/rules/review.md` に従い、**2 つの独立した視点**で差分を通す:

- **Reviewer A — Correctness**: バグ・エッジケース・型安全性・境界値・エラーハンドリングの漏れ・非同期の取りこぼし（floating promise / 部分失敗）。「この入力でどう壊れるか」を能動的に探す。
- **Reviewer B — Security（OWASP Top 10）**: インジェクション（SQL は必ずパラメータ化されているか）・SSRF（収集先 URL 検証）・認証/テナント境界（tenant id は JWT 由来か、RLS 越境はないか）・秘密のハードコード・**prompt injection**（LLM を含むパイプラインの場合）。

各視点で「規約のどの項目に反するか」を必ず特定する（例: 「typescript.md『any 禁止』に反する」「README 原則 7『秘密はコード・ログに出さない』に反する」）。

### Step 4. 報告

- **substantive な指摘のみ**報告する（実際の修正につながるもの）。スタイル・好みは出さない。
- 各指摘の形式: **`file:line` — 何が問題か — どの規約項目に反するか — 直し方の方向**（コードは丸ごと書かず方針まで）。
- 重要度順に並べる（壊れる / 危険 → 設計の歪み → 軽微）。
- 指摘ゼロなら「規約・2 観点で substantive な問題なし」と明言する（無理に粗探ししない）。

### Step 5. 仕上げ

1. セキュリティが絡む差分なら `make scan`（prompt injection 検査・staged diff）と `make secrets`（gitleaks）の実行を案内する。
2. 修正は**本人 or 合意の上**で行う。pair-start から来た [自分] タスクなら、修正コードを先回りで書かず指摘に留める。
3. PR 前なら、指摘対応後にもう一度差分を見るかを確認する。

## やってはいけないこと

- **規約の中身を SKILL.md に複製する** — リンク参照のみ。二重管理は腐る（Single Source of Truth = `docs/conventions/`）。
- **整形・スタイルを指摘する** — ツールが直す領域。人のレビューを設計・正しさ・安全に使う。
- **non-substantive な指摘で埋める** — 「実際の修正につながる指摘のみ」（[`docs/conventions/README.md`](../../../docs/conventions/README.md) §使い方）。
- **規約項目名を添えずに指摘する** — 「どの基準に照らして問題か」が無い指摘は主観に見える。
- **スパイクに本実装の基準を当てる** — `spike/` は throwaway。緩める線引きは Step 1.3。
