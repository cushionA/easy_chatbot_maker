# React / TypeScript 規約

対象: `apps/web`（React フロント）。**TypeScript 全般は [typescript.md](typescript.md) が前提**で、本書はその差分（コンポーネント・hooks・状態・JSX）だけを書く。共通原則は [README.md](README.md)。

UI は作り込まない方針（[`design/13`](../../design/13_testing_strategy.md)）。トレンド可視化・ドリルダウン・収集ヘルス・用語辞書管理（[`design/02`](../../design/02_architecture.md)）を、壊れにくく素直に作ることを優先する。

## 前提

- **React 18+ + 関数コンポーネント + hooks のみ**。class コンポーネントは書かない。
- 新 JSX transform 前提（`import React` は不要。ESLint で `react/react-in-jsx-scope` は off）。
- 型は props を含め厳密に（[typescript.md](typescript.md)）。`prop-types` は使わない（型で代替、ESLint で off）。
- `apps/web/tsconfig.json` は `tsconfig.base.json` を継承し、`lib` に `DOM`/`DOM.Iterable`、`jsx: "react-jsx"`、`moduleResolution: "Bundler"` を上書きする。

## ファイル / ディレクトリ

- コンポーネントファイルは `PascalCase.tsx`（`TrendChart.tsx`）。hooks は `useXxx.ts`（`useWatchlist.ts`）。それ以外のユーティリティは `kebab-case.ts`。
- 1 ファイル 1 公開コンポーネント（+ そのファイル専用の小さな子は同居可）。
- 機能（feature）単位でまとめる: `features/trends/`, `features/watchlist/`, `features/collection-health/`。横断 UI は `components/`、API クライアントは `lib/api/`。
- ページ/ルートは `routes/` or フレームワーク規約に従う。URL 形式は `/t/{slug}/...`（[`design/02`](../../design/02_architecture.md)）。

## コンポーネント設計

- **小さく・単一責務**。「データ取得 + 整形 + 表示」を 1 コンポーネントに詰めない。取得は hooks、表示は presentational に寄せる。
- props は **`interface` で定義し、destructure で受ける**。`React.FC` は使わない（children を暗黙に持つため）。

  ```tsx
  interface TrendChartProps {
    termSlug: string;
    locale: Locale;
    onSelectDay?: (day: string) => void;
  }

  export function TrendChart({ termSlug, locale, onSelectDay }: TrendChartProps) {
    // …
  }
  ```

- props は**必要なものだけ**。「念のため」の props を増やさない。boolean が増えたら variant ユニオン（`variant: "compact" | "full"`）にまとめる。
- children を受けるなら `children: React.ReactNode`。コールバック props は `onXxx`、ハンドラ実装は `handleXxx`。
- 条件分岐は早期 return で平らに。JSX 内の三項ネストを深くしない。リストは安定した `key`（index を key にしない）。

## 定義順（コンポーネントファイル内）

1. `import`（[typescript.md](typescript.md) の順、`simple-import-sort` が整列）
2. props の `interface`
3. **公開コンポーネント**（ファイルの主役。default でなく named export）
4. コンポーネント内: ① hooks（`useState`/`useReducer`→ 外部データ hooks → `useMemo`/`useCallback`→ `useEffect`）② 派生値・ハンドラ ③ 早期 return（loading / error / empty）④ メイン JSX を return
5. ファイル下部に、このファイル専用の小コンポーネント / 純ヘルパー

```tsx
export function WatchlistPanel({ tenantSlug }: WatchlistPanelProps) {
  const { data, status } = useWatchlist(tenantSlug); // hooks を先頭に集める
  const sorted = useMemo(() => sortByAddedAt(data ?? []), [data]);

  if (status === "loading") return <Spinner />;
  if (status === "error") return <ErrorNote />;
  if (sorted.length === 0) return <EmptyState />;

  return <ul>{sorted.map((w) => <WatchRow key={w.id} item={w} />)}</ul>;
}

function WatchRow({ item }: { item: WatchItem }) {
  return <li>{item.termSlug}</li>;
}
```

## hooks

- **hooks ルールを守る**（ESLint `react-hooks/rules-of-hooks` が error）。トップレベルでのみ呼ぶ。条件・ループ・early return の後に呼ばない。
- `useEffect` の依存配列は正直に（`react-hooks/exhaustive-deps`）。lint 警告を握り潰さない。依存が多すぎる effect は責務過多のサイン。
- **`useEffect` を「データ取得の既定手段」にしない**。サーバ状態は専用ライブラリ（TanStack Query 等）でキャッシュ・再取得・エラーを管理する。`useEffect` は「外部システムとの同期」(購読・DOM 計測)に限る。
- カスタム hooks に**ロジックを抽出**する。コンポーネントは「hooks を組み合わせて JSX を返す」に徹する。hooks は `use` で始め、単一の関心を持つ。
- `useMemo`/`useCallback` は**計測して必要なときだけ**。先回り最適化で配列を埋めない（依存管理コストの方が高くつくことが多い）。

## 状態管理

- **状態は必要最小限**。サーバから来るものは「サーバ状態」、UI 都合は「クライアント状態」と分けて考える。
- サーバ状態（トレンド・検知・エビデンス・ウォッチリスト）は**サーバキャッシュライブラリ**で持つ。`useState` に詰めて手で同期しない。
- 派生できる値は state にしない（`useMemo` か描画時計算）。state の二重管理は不整合の温床。
- グローバル UI 状態（テーマ・選択中テナント）が要るときだけ Context。Context を「何でも入れ」にしない（再描画が広がる）。
- フォームは制御コンポーネント。入力検証は送信境界で（[typescript.md](typescript.md) の境界検証）。

## データ取得と API 境界

- API クライアントは `lib/api/` に集約し、**レスポンスを zod で検証**してから UI に渡す（バックエンドと型が揃っていても、境界で確定させる）。
- 取得は loading / error / empty / success の**4 状態を必ず扱う**。empty を success と混同しない。
- 認証 JWT・テナント文脈はクライアント側に信頼境界を作らない。**認可の一次防御はサーバ 403**（[`design/13`](../../design/13_testing_strategy.md) E10）。UI の出し分けは副次。

## コメント / スタイル

- WHY コメントは [typescript.md](typescript.md) と同じ。JSX 内コメントは `{/* … */}`、UX 上の非自明な制約（「空でも領域を確保してレイアウトシフトを防ぐ」等）を書く。
- インラインスタイルでロジックを作らない。クラス / デザイントークンに寄せる。マジックナンバー（ブレークポイント等）は定数化。
- アクセシビリティの最低限: 画像に `alt`、操作要素はネイティブ要素（`button`/`a`）、フォーカス可能、色だけで情報を伝えない（`eslint-plugin-jsx-a11y` recommended で機械強制。理由のある例外だけ行コメントで無効化）。

## テスト

- 主要フローは **Playwright E2E**（[`design/13`](../../design/13_testing_strategy.md) E1–E10）。ゴールデンパス E1→E2→E4 と E3/E5 は CI 必須通過。
- コンポーネント単体が要るときは Testing Library で**ユーザー視点**（role / text で取得）。実装詳細（state 名・クラス名）に依存しない。
- ピクセル単位のビジュアル回帰は追わない（主要画面のスナップショットに留める）。
- セレクタは `data-testid` でなくアクセシブルな role/label を優先（テストが a11y を兼ねる）。

## 禁止 / アンチパターン

- class コンポーネント、`React.FC`、`prop-types`。
- `useEffect` でのデータ取得を既定にする / 依存配列の握り潰し（`// eslint-disable exhaustive-deps`）。
- 派生可能な値を `useState` で二重管理する。
- `key={index}`、巨大な三項ネスト JSX、1 コンポーネントへの責務詰め込み。
- 先回りの `useMemo`/`useCallback` 乱用。
- Context に何でも入れて全体再描画を誘発する。
- インラインスタイルやマジックナンバーの散在。

## レビューチェックリスト

- [ ] コンポーネントが単一責務（取得=hooks / 表示=presentational に分離）
- [ ] props は `interface` + destructure、`React.FC` 不使用、不要 props が無い
- [ ] hooks がトップレベルのみ・`exhaustive-deps` を満たす
- [ ] サーバ状態をキャッシュライブラリで管理（`useEffect` 取得や手動同期でない）
- [ ] loading / error / empty / success の 4 状態を扱う
- [ ] API レスポンスを境界で zod 検証している
- [ ] 認可をサーバ 403 に依存（UI 非表示だけに頼っていない）
- [ ] 定義順（props 型 → 公開コンポーネント → 子/ヘルパー）が守られている
- [ ] リスト key が安定、a11y の最低限（role / alt / フォーカス）を満たす
- [ ] 主要フローに Playwright E2E（[`design/13`](../../design/13_testing_strategy.md)）
