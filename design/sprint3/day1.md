# Sprint 3 Day 1 作業指示書（2026-05-27）

> テーマ: **抽象を確定する**
> 完了時の状態: `apps/api/src/destinations/` モジュールが追加され、`ITicketDestination` と 4 つの型、`DestinationRegistry` がビルドできる。起票本文 Markdown 化（`build_description` 移植）が単体テスト付きで動く。実アダプタ実装は Day 2。
> 推定所要: 4〜6 時間

> 参照の正: [`06_destinations.md:8-45`](../06_destinations.md)（インターフェース定義）、[`09_task_split.md:79-84`](../09_task_split.md)（委譲判断）。
> 命名注意: 設計書 06 章は `src/Chatbot.Destinations/` 表記だが、本リポジトリは `apps/api/src/destinations/` 配置。**新規モジュールは `apps/api/src/destinations/`、export は `index.ts` から** に統一する（設計書は書き換えない）。

---

## Day1-1. `apps/api/src/destinations/` モジュールを作成 [自分] [BE]

**目的**
起票ロジックを `apps/api/src/` から切り出した独立モジュールに置く。ルーターや HTTP 層に依存しない純粋なドメイン層にすることで、面接で「Adapter パターンを HTTP 層から分離して、テスト容易性と差し替え可能性を確保した」と語れる。

**自分で書く理由**
モジュール構成（依存方向: ルーター/コントローラ → destinations モジュール、逆は禁止）は設計判断。ここで HTTP 依存を入れてしまうと抽象の意味がなくなる。

**前提確認**
- [ ] `pnpm build`（または `npm run build`）が現状で通る
- [ ] `apps/api/src/` に既存のルーターやサービスがある（確認済み）

**手順**
1. ディレクトリを作成し、エントリポイントを置く:
   ```bash
   mkdir -p apps/api/src/destinations
   touch apps/api/src/destinations/index.ts
   ```
2. `tsconfig.json` のパスエイリアス（`paths`）があれば `@destinations` 等を追加してもよい（無くてもよい）。
3. `apps/api/src/destinations/index.ts` は後続タスクで定義した型/クラスを re-export する入口にする。今は空ファイルでよい。
4. HTTP フレームワーク（Express / NestJS）への import をこのモジュール内に入れない（`express`/`@nestjs/common` 等の import を禁止）。

**完了確認**
- [ ] `pnpm build` が通る
- [ ] `apps/api/src/destinations/index.ts` が存在する
- [ ] ディレクトリ内に `express` / `@nestjs/common` 等の HTTP フレームワーク import が無い

**詰まったら**
- TypeScript の strict モードでエラー → `tsconfig.json` の `strict: true` に合わせ、`noImplicitAny` を意識する
- パスが通らない → `tsconfig.json` の `rootDir` / `outDir` 設定を確認

**AI 依頼テンプレ**: なし（自分で構成を決める範囲）

---

## Day1-2. `ITicketDestination` interface + 型 4 つを定義 [自分（中核）] [BE]

**目的**
このスプリント全体の **設計の中核**。起票先を抽象化する 1 枚の interface と、それが受け渡す値型を確定する。ここを握れば「Adapter パターンで起票先を抽象化した。フィールドマッピングは JSONB で柔軟に持たせ、テナント側で設定可能にした」と面接で語れる（[`06_destinations.md:198-202`](../06_destinations.md)）。

**自分で書く理由**
インターフェース定義は [`09_task_split.md:23`](../09_task_split.md) で明示的に [自分] 指定された箇所。実装（アダプタ）を AI に投げる前に、型の境界を自分で固める必要がある。「俺が握った契約に AI に実装させた」と言える状態を作る。

**前提確認**
- [ ] [`06_destinations.md:8-45`](../06_destinations.md) を読み、シグネチャを 1:1 で写す方針を確認
- [ ] Day1-1 完了

**手順**
1. `apps/api/src/destinations/types.ts` を作成。**設計書 06 章 [`06_destinations.md:8-45`](../06_destinations.md) のシグネチャを 1:1 で写す**。骨格だけ示し、メンバは設計書を見て埋める:
   ```typescript
   // Guid は TypeScript では string で表現する（06 章仕様どおり）
   export type TicketPriority = 'low' | 'normal' | 'high' | 'urgent';

   export interface DestinationConfig {
     // 3 つのメンバを持つ:
     //   publicConfig: URL / project_id 等の非秘匿設定（destinations.config 由来）→ Record<string, unknown>
     //   secretValue : Secret Manager から取得した API キー → string
     //   fieldMapping: 優先度変換等（destinations.field_mapping 由来）→ Record<string, unknown>
     // ここを自分で実装: interface 宣言。secretValue のすぐ上に
     //   「Secret Manager 由来・appsettings/env 禁止・ログに出さない」コメントを付ける
   }

   export interface Ticket {
     // 起票 1 件を表す型。title / bodyMarkdown / priority(TicketPriority) /
     //   tenantId(string) / knowledgeEntryId(string) を持つ。
     // ここを自分で実装: interface 宣言（06 章定義どおり。inquiry id は持たせない）。
   }

   export interface TicketSubmitResult {
     // 起票結果: success(boolean) / externalId(string | null) /
     //   externalUrl(string | null) / errorMessage(string | null)
     // ここを自分で実装: interface 宣言。
   }

   export type TestConnectionFailureReason =
     | 'none'
     | 'invalidApiKey'
     | 'unreachable'
     | 'forbidden'
     | 'unknown';

   export interface TestConnectionResult {
     // 06 章「成功 / API キー無効 / URL 到達不可 / 権限不足」を型で表現する。
     // success(boolean) / failureReason(TestConnectionFailureReason) / message(string | null)
     // ここを自分で実装: interface 宣言。
   }

   export interface ITicketDestination {
     // ここを自分で実装: 06 章のインターフェース定義を写す。
     //   - kind を返す readonly プロパティ（"redmine" / "github_issues" と一致）
     //   - 接続テスト用の非同期メソッド（config: DestinationConfig → Promise<TestConnectionResult>）
     //   - 起票用の非同期メソッド（ticket: Ticket, config: DestinationConfig → Promise<TicketSubmitResult>）
   }
   ```
2. `secretValue` のすぐ上に **「Secret Manager 由来・appsettings/env 禁止・ログに出さない」** コメントを付ける。
3. `apps/api/src/destinations/index.ts` から全型を re-export する。

**完了確認**
- [ ] `pnpm build`（または `tsc --noEmit`）が通る
- [ ] `DestinationConfig.secretValue` のすぐ上に「Secret Manager 由来・非ログ」のコメントがある
- [ ] 4 型 + 1 union type + interface が `destinations/types.ts` に揃い、`index.ts` から export される

**詰まったら**
- `unknown` vs `any` → `Record<string, unknown>` を使う。`any` は禁止（`strict` 設定に合わせる）
- 優先度を union type にすべきか迷う → MVP は 06 章どおり `'low'|'normal'|'high'|'urgent'` の union。マッピングは Day3-4 で JSONB を引く

**AI 依頼テンプレ**: なし（自分で書く範囲。型が確定したら Day1-4 / Day2 で AI に渡す）

---

## Day1-3. `DestinationRegistry`（kind → 実装解決）+ DI/ファクトリ登録 [自分] [BE]

**目的**
`destinations.kind`（`"redmine"` / `"github_issues"`）の文字列から、対応する `ITicketDestination` 実装を解決する仕組みを置く。これが Adapter パターンの「差し替え点」。

**自分で書く理由**
依存解決の戦略（ファクトリ/DI で複数実装を登録し、`kind` でルックアップ）は設計判断。新しい起票先を「実装を 1 つ足して登録するだけ」で増やせる構造を自分で設計したと語る要所（[`06_destinations.md:196`](../06_destinations.md)）。

**前提確認**
- [ ] Day1-2 完了
- [ ] `infra/db/migrations/0001_schema.sql:123` の `kind IN ('redmine','github_issues')` 制約を確認（`kind` 文字列はこれと一致させる）

**手順**
1. `apps/api/src/destinations/registry.ts` — 解決インターフェースと実装の骨格。**ルックアップの中身（kind → 実装の Map 化と resolve）は自分で書く**:
   ```typescript
   import type { ITicketDestination } from './types';

   export interface IDestinationRegistry {
     // kind 不一致や未登録なら例外（呼び出し側が握りつぶさないよう明示失敗）
     resolve(kind: string): ITicketDestination;
   }

   export class DestinationRegistry implements IDestinationRegistry {
     private readonly _map: Map<string, ITicketDestination>;

     constructor(destinations: ITicketDestination[]) {
       // ここを自分で実装:
       //   - 注入された destinations を d.kind をキーに Map 化する。
       //     kind は DB の CHECK 制約で小文字固定。
       //   - resolve(kind): Map に有れば返す。無ければ Error を throw して明示失敗にする
       //     （未登録 kind を握りつぶさない）。
     }

     resolve(kind: string): ITicketDestination {
       // ここを自分で実装
       throw new Error('not implemented');
     }
   }
   ```
2. DI/ファクトリ登録用の関数 `apps/api/src/destinations/bootstrap.ts` を置く（実装の登録は Day 2 で各アダプタを足すが、枠だけ先に作る）:
   ```typescript
   import { DestinationRegistry } from './registry';
   import type { ITicketDestination } from './types';

   export function createDestinationRegistry(
     destinations: ITicketDestination[]
   ): DestinationRegistry {
     // ここを自分で実装:
     //   - 渡された destinations で DestinationRegistry を生成して返す。
     //   - 各アダプタは Day 2 でここの destinations 配列に追加する（今は空配列でよい）。
     return new DestinationRegistry(destinations);
   }
   ```
3. アプリのエントリポイント（`apps/api/src/app.ts` 等）で `createDestinationRegistry([])` を呼び、DI コンテナ（NestJS なら Module、Express なら手動 DI）に登録する（枠だけ、実アダプタは Day2 で追加）。
4. `apps/api/src/destinations/index.ts` から `IDestinationRegistry` / `DestinationRegistry` / `createDestinationRegistry` を re-export する。

**完了確認**
- [ ] `pnpm build` が通る
- [ ] アプリ起動時に `createDestinationRegistry` が呼ばれる
- [ ] `registry.resolve('nope')` が `Error` を throw する（簡単な単体テストで確認してもよい）

**詰まったら**
- `Map` のキー大文字小文字が不安 → `kind` は DB の CHECK 制約で小文字固定なので、`Map<string, ...>` で `.get(kind)` そのままで十分
- NestJS の場合、Provider をどう定義するか → `useFactory` で `createDestinationRegistry(adapters)` を返す形にする

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## Day1-4. 起票本文 Markdown 化（既存 Streamlit `build_description` の TypeScript 移植）[AI] [BE]

**目的**
動的フォームで集めた値を起票本文（Markdown）に組み立てる純関数を作る。既存 Streamlit 版 `build_description` のロジックをそのまま移植する（[`10_existing_streamlit.md:104`](../10_existing_streamlit.md) で「そのまま流用」と決定済み）。出力例は [`06_destinations.md:115-128`](../06_destinations.md)。

**前提確認**
- [ ] Day1-2 完了（`Ticket` の `bodyMarkdown` にこの出力を入れる）
- [ ] [`06_destinations.md:109-130`](../06_destinations.md) の本文フォーマット例を AI に見せられる
- [ ] 既存 `redmine_client.py` の `build_description` 実物（PoC リポジトリ）を参照できるなら添付する。無ければ 06 章の例を仕様とする

**自分が先に決めること**
- [ ] フッターに含める内部 ID: `問題ID = knowledge_entry id`、`問い合わせID = inquiry id`（06 章の例に準拠）。外部チケットから内部 ID を遡及できるようにするのが目的（[`06_destinations.md:130`](../06_destinations.md)）
- [ ] 入力は「ラベル → 値」の順序付きペア列（`Array<{ label: string; value: string }>` 想定）。Day 4 のフォームから来る形に寄せる

**AI 依頼テンプレ**
```
apps/api/src/destinations/ モジュールに、起票本文を Markdown 化する純粋な関数
buildTicketBody を書いてほしい。Node.js / ブラウザ非依存（標準 TypeScript のみ）。

仕様（design/06_destinations.md の本文フォーマット例に準拠）:
- export function buildTicketBody(
      sectionTitle: string,
      fields: Array<{ label: string; value: string }>,
      knowledgeEntryId: string,
      inquiryId: string
  ): string
- 出力は:
  ## {sectionTitle}

  **{label}:** {value}
  （fields の各要素を 1 行ずつ。value 内の改行は維持）

  ---
  *このチケットは社内チャットボットから自動起票されました*
  *問題ID: {knowledgeEntryId}*
  *問い合わせID: {inquiryId}*
- fields が空なら本文セクションは見出しのみ＋区切り線＋フッター
- value に Markdown 特殊文字が含まれてもエスケープは不要（社内利用前提・PoC 仕様踏襲）

テストも apps/api/src/destinations/__tests__/buildTicketBody.test.ts として Vitest（または Jest）で:
- fields 2 件のときの完全一致テスト（期待文字列をベタ書き）
- fields 0 件のとき見出し＋フッターのみ
- フッターに knowledgeEntryId / inquiryId が両方含まれる
を書いてほしい。外部ライブラリなし（Node.js 組み込みのみ）。
```

**自分の確認ポイント**
- [ ] 出力が 06 章の例とフォーマット一致（見出し `##`、`**ラベル:**`、区切り `---`、フッター 3 行）
- [ ] `knowledgeEntryId` と `inquiryId` が両方フッターに出る（遡及性の根幹）
- [ ] HTTP フレームワーク依存が無い（`import express` / `import { Injectable }` 等が無い）
- [ ] テストが green

**詰まったら**
- AI が `inquiryId` を Ticket に持たせようとする → `Ticket` 型には inquiry id は無い（06 章定義）。`buildTicketBody` の引数で別途渡す設計に留める
- フォーマットが微妙にずれる → 期待文字列をベタ書きしたテストを正とし、実装をそれに合わせさせる

---

## Day 1 終了チェックリスト

- [ ] `apps/api/src/destinations/` が存在し、HTTP 層から一方向参照される構造になっている
- [ ] `ITicketDestination` + `DestinationConfig` / `Ticket` / `TicketSubmitResult` / `TestConnectionResult`（+ `TestConnectionFailureReason` union）が定義済み
- [ ] `DestinationRegistry` と `createDestinationRegistry()` があり、アプリ起動時に登録済み
- [ ] `buildTicketBody` が 06 章の本文フォーマットを再現し、テストが green
- [ ] `pnpm build` と `pnpm test` が通る

## Day 2 への引き継ぎメモ（自分宛て）

- アダプタの `kind` は DB の CHECK 制約（`'redmine'` / `'github_issues'`）と完全一致させる
- アダプタは `createDestinationRegistry([new RedmineDestination(...), new GitHubIssuesDestination(...)])` の形で Day 2 で差し込む
- `secretValue` は Secret Manager 由来。Day 2 のアダプタは「config に既に取得済みキーが入っている」前提で書く（Secret Manager 連携は Day 3）。テストではダミー文字列を渡す
