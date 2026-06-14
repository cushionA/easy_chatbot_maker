# TypeScript / Node.js 規約

対象: `apps/api`（Node API）/ `workers`（収集ワーカー）/ `packages/*`（共有ライブラリ）。React 固有は [react.md](react.md)。共通原則は [README.md](README.md)。

スタックの主軸。フロント〜API〜ワーカーで**型を共有**するのが TypeScript を選んだ理由（[`design/02`](../../design/02_architecture.md)）なので、「型を効かせる」ことを最優先の規約とする。

## 前提

- **Node 22 LTS / TypeScript 5.7+**。`tsconfig.base.json` を各パッケージが `extends` する。`strict` + `noUncheckedIndexedAccess` + `exactOptionalPropertyTypes` が前提（緩めない）。
- 整形は **Prettier**（2スペース・ダブルクォート・セミコロンあり・`printWidth 100`・末尾カンマ `all`）。**整形はレビューで指摘しない** — `npm run format` が直す。
- 静的チェックは **ESLint（type-aware）+ tsc**。下記ルールの多くは [`eslint.config.mjs`](../../eslint.config.mjs) が自動で fail させる。本書は「なぜそのルールか」と、ツールが見ない設計面を補う。
- ESM (`"type": "module"`)。`import`/`export` のみ。`require` は使わない。

## ファイル / ディレクトリ

- 1 ファイル 1 責務。ファイル名は `kebab-case.ts`（例 `source-adapter.ts`、`rate-limiter.ts`）。React コンポーネントだけ例外で `PascalCase.tsx`。
- テストは対象の隣に `*.test.ts`、または `__tests__/`。E2E は `apps/web/e2e/`。
- パッケージ公開面は `index.ts`（barrel）に集約し、外からは barrel 経由で import する。内部ファイルへの深い import を外部からしない。
- 1 ファイルが ~300 行を超え複数の関心が混ざったら分割を検討（厳密な行数ルールではなく目安）。

## 命名

| 対象 | 規則 | 例 |
|---|---|---|
| 変数・関数・メソッド | `camelCase` | `fetchWindow`, `termSlug` |
| 型・interface・class・enum | `PascalCase` | `SourceAdapter`, `DayStat` |
| 定数（モジュール定数） | `UPPER_SNAKE_CASE` | `MIN_POINTS`, `MAX_BODY_LENGTH` |
| 型パラメータ | 意味のある名前か `T`/`K`/`V` | `<TItem>`, `<K, V>` |
| boolean | `is`/`has`/`should`/`can` 接頭辞 | `isEmerging`, `hasEvidence` |
| 非同期関数 | 名前に `Async` は付けない（型で分かる）。副作用が主なら動詞 | `fetchWindow`, `storeOccurrences` |

- 名前は**意図**を表す。`I` プレフィクス（`IFoo`）は付けない（TS では不要）。
- 略語は広く通じるもの（`url`, `id`, `db`, `rpm`）のみ。それ以外は省略しない（`cfg`→`config`）。
- 真偽値・列挙は否定形を避ける（`isDisabled` より `isEnabled`）。

## 型の使い方（最重要）

- **`any` 禁止**（ESLint `no-explicit-any` が error）。外部入力は `unknown` で受け、**zod** などでパースして型を確定させる。境界での検証は [README.md](README.md) の原則どおり一度だけ。

  ```ts
  // bad: 検証せず any で押し込む
  function fromHit(hit: any): SpikeItem { return { ...hit }; }

  // good: 境界で unknown → スキーマで確定
  const HnHit = z.object({ objectID: z.string(), title: z.string(), points: z.number() });
  function fromHnHit(raw: unknown): SpikeItem {
    const hit = HnHit.parse(raw); // ここを越えたら型は信頼してよい
    return { externalId: hit.objectID, title: hit.title, popularity: hit.points /* … */ };
  }
  ```

- オブジェクトの形は **`interface`**、合併・交差・写像・タプルは **`type`**。迷ったら `interface`（参照実装 [`design/sprint1/refs/aggregate.ref.ts`](../../design/sprint1/refs/aggregate.ref.ts) もこの方針）。
- **公開関数・公開メソッドには返り値型を明示**する（推論に頼らない）。内部の小さな関数は推論で良い。
- ドメインの「種類」は**判別可能合併（discriminated union）**で表し、`switch` を網羅させる（ESLint `switch-exhaustiveness-check`）。

  ```ts
  type Detection =
    | { type: "emerging"; distinctSources: number }
    | { type: "rising"; zScore: number }
    | { type: "declining"; decay: number };

  function score(d: Detection): number {
    switch (d.type) {
      case "emerging": return d.distinctSources;
      case "rising": return d.zScore;
      case "declining": return d.decay;
      // default は書かない。case 追加忘れを型エラーで検出させる
    }
  }
  ```

- `as`（型アサーション）は最後の手段。使うなら「なぜ安全か」を同じ行にコメント。`as any` / `as unknown as T` は原則禁止。
- `null` と `undefined` を混在させない。「値が無い」は基本 `undefined`、DB 由来の明示的空は `null`。`?:` と `| undefined` を `exactOptionalPropertyTypes` 下で正しく使い分ける。
- `enum` より**ユニオンリテラル**（`type Locale = "global" | "jp"`）を優先。バンドルサイズ・相互運用で有利。
- import は値と型を分け、型は **inline `type`**（ESLint が自動修正）。

  ```ts
  import { fetchWindow, type FetchOptions } from "./fetch";
  ```

## 定義順（ファイル内の並び）

「上から読めば分かる」順（newspaper order）。呼ぶ側を上、呼ばれる補助を下に置く。

1. ファイル先頭コメント（WHY が要るときだけ）
2. `import`（`simple-import-sort` が自動整列。順: 副作用 import → Node 標準 → 外部 → 内部エイリアス → 相対）
3. 公開する型・interface
4. モジュール定数（`UPPER_SNAKE_CASE`）
5. **公開 API**（export する関数 / class）— ファイルの主役を先に
6. 非公開ヘルパー（下に置き、上から参照する。関数宣言は巻き上げされるので前方参照可）

```ts
// 収集ワーカーのレート制御。design/06 のトークンバケットを実装する。
import { setTimeout as sleep } from "node:timers/promises";

export interface RateLimiter {
  acquire(host: string): Promise<void>;
}

const DEFAULT_RPM = 60;

export function createRateLimiter(rpm = DEFAULT_RPM): RateLimiter {
  const buckets = new Map<string, Bucket>();
  return { acquire: (host) => take(buckets, host, rpm) };
}

// --- helpers ---
interface Bucket { tokens: number; updatedAt: number; }
async function take(buckets: Map<string, Bucket>, host: string, rpm: number): Promise<void> {
  // …
}
```

- class 内の順: `static` フィールド → インスタンスフィールド → コンストラクタ → 公開メソッド → 非公開メソッド。
- 関連する関数は近くに置く。アルファベット順より**関心のまとまり**を優先。

## コメント / ドキュメンテーション

- **WHY を書く。WHAT は書かない。** コードが語る内容を繰り返さない。
- 書くべきは: 制約（外部仕様・レート上限）、回避策とその理由、微妙な不変条件、なぜ自明な実装にしなかったか。参照実装のこのコメントが手本:

  ```ts
  if (!e.docs.has(o.docId)) {
    // 同一文書の重複 occurrence を防ぐ（extract 側で潰していても防御的に）
    e.mentions += 1;
  }
  ```

- 外部仕様・設計に紐づくものは出典を書く（`// design/14 §1: 1 クエリ 1000 件天井`）。
- 公開ライブラリ関数には TSDoc（`/** */`）を付けてよい。ただし型で自明なことを言葉で繰り返さない。`@param`/`@returns` は型が説明しきれない含意があるときだけ。
- `TODO(name): …` / `FIXME:` は担当か Issue 番号を添える。放置 TODO を量産しない。
- コメントアウトされた死にコードはコミットしない（git が履歴を持つ）。

## エラーハンドリング

- **握れないエラーは伝播させる。** `try/catch` で握るのは「ここでしか復旧できない」ときだけ。握ったら必ず WHY をコメントし、ログするか型で表す。
- `catch (e)` の `e` は `unknown`。`instanceof` で絞ってから使う。
- 例外を投げるのは「プログラマのミス／継続不能」な不変条件違反。**期待される失敗**（外部 4xx、バリデーション NG、見つからない）は例外でなく**戻り値の型**で表す。

  ```ts
  // 期待される失敗は Result 型で。呼び出し側に分岐を強制する
  type FetchResult =
    | { ok: true; body: string; etag: string | null }
    | { ok: false; reason: "not_modified" | "rate_limited" | "blocked_by_robots" };
  ```

- **floating promise 禁止**（ESLint `no-floating-promises`）。await するか、意図的に投げっぱなしなら `void promise` と書く。
- async 関数のエラーは握り潰さない。`Promise.all` は一つの失敗で全体が reject される点に注意。部分失敗を許容するなら `Promise.allSettled`。
- プロセス境界（ワーカージョブ・HTTP ハンドラ）に**最後の砦の catch** を一つ置き、未捕捉を構造化ログに残してから 5xx / ジョブ失敗にする。

## 非同期・並行（Node / ワーカー）

- I/O は常に `async/await`。`.then()` チェーンを混在させない。
- 収集は**部分失敗前提**（[`design/02`](../../design/02_architecture.md)）。1 件の失敗で全体を落とさない。リトライは**指数バックオフ + ジッタ**、上限で打ち切り（[`design/13`](../../design/13_testing_strategy.md) の収集テスト）。
- 並行度は明示的に絞る（ホスト別レート、同時フェッチ上限）。無制限の `Promise.all(urls.map(fetch))` は禁止。
- 外部 HTTP は `undici`/`fetch`。タイムアウトと `AbortSignal` を必ず付ける。リトライ・条件付き GET（ETag）はワーカー共通層に集約。
- 時刻・乱数に直接依存しない（テストで固定できるよう注入可能にする）。`Date.now()` 直書きを避け、`clock` を渡す。

## ログ / 観測性

- `console.log` は使わない（ESLint `no-console`、`warn`/`error` のみ許可）。構造化ロガー（pino 等）を DI する。
- ログは**構造化**（`logger.info({ host, status }, "fetch done")`）。文字列連結でフィールドを埋め込まない。
- **秘密を出さない**: JWT・BYOK キー・`Authorization` ヘッダ・バインド済み SQL の値をログに残さない（[`design/04`](../../design/04_security_multitenant.md)）。

## セキュリティ境界

- 検証は信頼境界で。HTTP 入力・外部 API 応答・キュー投入データを `unknown`→zod で確定。内側は信頼。
- **SQL は常にパラメータ化**。文字列連結禁止。テナント分離は `SET LOCAL app.tenant_id`（[sql.md](sql.md) / [`design/04`](../../design/04_security_multitenant.md)）。クライアント由来の tenant id を信頼しない（JWT クレームから取る）。
- **SSRF 防御**（収集の最重要）: 取得先 URL はプライベート IP・メタデータ（`169.254.169.254`）・非 http(s)・内部ホストへのリダイレクトを `FetchContext` で拒否（[`design/13`](../../design/13_testing_strategy.md)）。
- 入力長に上限（ReDoS / DoS 防御）。用語抽出の正規表現は破滅的バックトラックを避ける。
- 秘密は環境変数 / Secret Manager から。コード・`.env.example` に実値を置かない。

## テスト

- Vitest（単体・結合）/ supertest（API）/ Testcontainers（Postgres・ES）/ Playwright（E2E）/ zod（契約）。方針の正は [`design/13`](../../design/13_testing_strategy.md)。
- テストファイルも ESLint で守る: `*.test.ts`/`*.spec.ts` は `eslint-plugin-vitest`、`e2e/**` は `eslint-plugin-playwright`（`no-focused-tests` / `missing-playwright-await` 等の取りこぼし防止）。
- 純ロジック（正規化・F2 判定式・レート・スニペット）は単体で分岐網羅。**非決定出力（LLM・embedding 数値）は値を assert しない**。構造・順序・分岐を見る。
- 1 本の test は 1 つの振る舞いを見る。assert は「ステータス → 形 → 値」の順。
- 外部依存はモック/フィクスチャで決定的に。実通信はスモーク 1 本まで。
- RLS 越境・F2 検知回帰は CI 必須通過（[`design/13`](../../design/13_testing_strategy.md) の越境マトリクス・golden データセット）。

## 禁止 / アンチパターン

- `any`、`as any`、`@ts-ignore`（やむを得ず止めるなら `@ts-expect-error` + 理由コメント）。
- floating promise、`Promise.all` での暗黙の全件失敗、無制限並行。
- `console.log` をライブラリコードに残す。
- 例外でフロー制御（期待される失敗を throw/catch でやり取り）。
- バレル経由でなく他パッケージの内部ファイルへ深く import。
- `enum`（ユニオンリテラルで足りる場合）、`namespace`、`I`プレフィクス。
- default export の濫用（基本 named export。ツール・フレームワークが要求する所だけ default）。
- 時刻・乱数・環境のハードコード依存（テスト不能になる）。

## レビューチェックリスト

- [ ] 外部入力が境界で `unknown`→スキーマ検証され、内側に `any` が無い
- [ ] 公開関数に返り値型が明示され、ドメインの種類は判別可能合併 + 網羅 `switch`
- [ ] 定義順が「公開 API が上、ヘルパーが下」になっている
- [ ] コメントが WHY を説明している（WHAT の言い換えになっていない）
- [ ] 握ったエラーに理由があり、期待される失敗は型で表現されている（例外でない）
- [ ] await 漏れ（floating promise）が無い／並行度に上限がある
- [ ] SQL パラメータ化・tenant id は JWT 由来・収集先 URL の SSRF 防御
- [ ] ログ・エラーに秘密が出ていない
- [ ] 追加ロジックに単体テスト、API 追加に結合テスト（正常 + テナント越境）
- [ ] `npm run lint && npm run typecheck && npm run format:check` が緑
