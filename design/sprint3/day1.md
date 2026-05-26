# Sprint 3 Day 1 作業指示書（2026-05-27）

> テーマ: **抽象を確定する**
> 完了時の状態: `Portfolio.Destinations` クラスライブラリが `Portfolio.sln` に追加され、`ITicketDestination` と 4 つの record 型、`DestinationRegistry` がビルドできる。起票本文 Markdown 化（`build_description` 移植）が単体テスト付きで動く。実アダプタ実装は Day 2。
> 推定所要: 4〜6 時間

> 参照の正: [`06_destinations.md:8-45`](../06_destinations.md)（インターフェース定義）、[`09_task_split.md:79-84`](../09_task_split.md)（委譲判断）。
> 命名注意: 設計書 06 章は `src/Chatbot.Destinations/` 表記だが、本リポジトリは `Portfolio.*` 命名。**新規クラスライブラリは `backend/Portfolio.Destinations/`、名前空間は `Portfolio.Destinations`** に統一する（設計書は書き換えない）。

---

## Day1-1. ソリューションに `Portfolio.Destinations` クラスライブラリを追加 [自分]

**目的**
起票ロジックを `Portfolio.Web` から切り出した独立ライブラリに置く。Web に依存しない純粋なドメイン層にすることで、面接で「Adapter パターンを Web から分離して、テスト容易性と差し替え可能性を確保した」と語れる。

**自分で書く理由**
プロジェクト構成（依存方向: `Portfolio.Web` → `Portfolio.Destinations`、逆は禁止）は設計判断。ここで Web 参照を入れてしまうと抽象の意味がなくなる。

**前提確認**
- [ ] `dotnet build Portfolio.sln --configuration Release` が現状で通る
- [ ] `backend/Portfolio.sln` に `Portfolio.Web` / `Portfolio.Web.Tests` の 2 プロジェクトがある（確認済み）

**手順**
1. クラスライブラリを作成しソリューションに追加（`backend/` 配下で実行）:
   ```bash
   dotnet new classlib -n Portfolio.Destinations -o Portfolio.Destinations -f net8.0
   dotnet sln Portfolio.sln add Portfolio.Destinations/Portfolio.Destinations.csproj
   ```
2. `Portfolio.Web` から参照を追加（依存方向は Web → Destinations の一方向のみ）:
   ```bash
   dotnet add Portfolio.Web/Portfolio.Web.csproj reference Portfolio.Destinations/Portfolio.Destinations.csproj
   ```
3. `Portfolio.Destinations.csproj` を、リポジトリ標準（`Directory.Build.props` 継承）に合わせる。`Nullable=enable` / `TreatWarningsAsErrors=true` は props 側で効くはずなので、csproj 内に重複定義しない。`dotnet new` が吐いた `<Nullable>` 等は削除する。
4. 既定生成された `Class1.cs` は削除。

**完了確認**
- [ ] `dotnet build Portfolio.sln --configuration Release` が通る
- [ ] `Portfolio.Destinations` が `Microsoft.AspNetCore.*` を参照していない（Web 非依存）
- [ ] `Portfolio.Web` のビルドが `Portfolio.Destinations` を引けている

**詰まったら**
- `TreatWarningsAsErrors` で `Class1.cs` 未使用警告 → ファイルを消す
- `net8.0` 以外の TFM が入った → `global.json` の SDK と一致させ `-f net8.0` を明示

**AI 依頼テンプレ**: なし（自分で構成を決める範囲）

---

## Day1-2. `ITicketDestination` インターフェース + record 型 4 つを定義 [自分（中核）]

**目的**
このスプリント全体の **設計の中核**。起票先を抽象化する 1 枚のインターフェースと、それが受け渡す値型を確定する。ここを握れば「Adapter パターンで起票先を抽象化した。フィールドマッピングは JSONB で柔軟に持たせ、テナント側で設定可能にした」と面接で語れる（[`06_destinations.md:198-202`](../06_destinations.md)）。

**自分で書く理由**
インターフェース定義は [`09_task_split.md:23`](../09_task_split.md) で明示的に [自分] 指定された箇所。実装（アダプタ）を AI に投げる前に、型の境界を自分で固める必要がある。「俺が握った契約に AI に実装させた」と言える状態を作る。

**前提確認**
- [ ] [`06_destinations.md:8-45`](../06_destinations.md) を読み、シグネチャを 1:1 で写す方針を確認
- [ ] Day1-1 完了

**手順**
1. `Portfolio.Destinations/ITicketDestination.cs` を作成。**設計書 06 章 [`06_destinations.md:8-45`](../06_destinations.md) のシグネチャを 1:1 で写す**。自分で確定させるのは「どんなメンバを持つ契約か」なので、骨格だけ示し、メンバは設計書を見て埋める:
   ```csharp
   using System.Text.Json;

   namespace Portfolio.Destinations;

   public interface ITicketDestination
   {
       // ここを自分で実装: 06 章のインターフェース定義を写す。
       //   - kind を返す read-only プロパティ（"redmine" / "github_issues" と一致）
       //   - 接続テスト用の非同期メソッド（DestinationConfig + CancellationToken → TestConnectionResult）
       //   - 起票用の非同期メソッド（Ticket + DestinationConfig + CancellationToken → TicketSubmitResult）
       // 戻り値型は手順 2 で定義する record 型。
   }
   ```
2. `Portfolio.Destinations/Models/` に値型を 4 つ + enum を置く。**06 章 [`06_destinations.md:8-45`](../06_destinations.md)（型定義）と [`06_destinations.md:166-172`](../06_destinations.md)（接続テスト結果のテキスト）を型化する**。各 record の「何を持つか」だけ示すので、メンバ（プロパティ名・型・順序）は設計書を見て自分で確定する:
   ```csharp
   // Models/DestinationConfig.cs
   // 3 つのメンバを持つ record:
   //   PublicConfig: URL / project_id 等の非秘匿設定（destinations.config 由来）→ JsonElement
   //   SecretValue : Vault から復号した API キー → string
   //   FieldMapping: 優先度変換等（destinations.field_mapping 由来）→ JsonElement
   // ここを自分で実装: record 宣言。SecretValue のすぐ上に
   //   「Vault 由来・appsettings 禁止・ToString() でログに出さない」コメントを付ける
   //   （backend/CLAUDE.md の secret 非ログ規約）。

   // Models/Ticket.cs
   // 起票 1 件を表す record。Title / BodyMarkdown / TicketPriority(string: low/normal/high/urgent) /
   //   TenantId(Guid) / KnowledgeEntryId(Guid) を持つ。
   // ここを自分で実装: record 宣言（06 章定義どおり。inquiry id は持たせない）。

   // Models/TicketSubmitResult.cs
   // 起票結果の record: Success(bool) / ExternalId(string?) / ExternalUrl(string?) / ErrorMessage(string?)。
   // ここを自分で実装: record 宣言。

   // Models/TestConnectionResult.cs
   // 06 章「成功 / API キー無効 / URL 到達不可 / 権限不足」を型で表現する。
   // 失敗理由を enum にして UI 表示・再試行判断で分岐できるようにする。
   // ここを自分で実装:
   //   - enum TestConnectionFailureReason（None / InvalidApiKey / Unreachable / Forbidden / Unknown）
   //   - record TestConnectionResult（Success(bool) / FailureReason(enum) / Message(string?)）
   ```
3. `record` は `09_task_split.md` / `backend/CLAUDE.md`（DTO は record）に従う。`SecretValue` は **`ToString()` でログに出さない**こと（`backend/CLAUDE.md` の secret 非ログ規約）をコメントに明記。

**完了確認**
- [ ] `dotnet build` が通る
- [ ] `DestinationConfig.SecretValue` のすぐ上に「Vault 由来・appsettings 禁止・非ログ」のコメントがある
- [ ] 4 record + 1 enum + interface が `Portfolio.Destinations` 名前空間に揃う

**詰まったら**
- `JsonElement` の using が無くてビルド失敗 → `System.Text.Json`（Newtonsoft は禁止、`backend/CLAUDE.md`）
- 優先度を enum にすべきか迷う → MVP は 06 章どおり `string`（"low"/"normal"/"high"/"urgent"）のまま。マッピングは Day3-4 で JSONB を引く

**AI 依頼テンプレ**: なし（自分で書く範囲。型が確定したら Day1-4 / Day2 で AI に渡す）

---

## Day1-3. `DestinationRegistry`（kind → 実装解決）+ DI 登録 [自分]

**目的**
`destinations.kind`（`"redmine"` / `"github_issues"`）の文字列から、対応する `ITicketDestination` 実装を解決する仕組みを置く。これが Adapter パターンの「差し替え点」。

**自分で書く理由**
依存解決の戦略（DI で複数実装を登録し、`Kind` でルックアップ）は設計判断。新しい起票先を「実装を 1 つ足して登録するだけ」で増やせる構造を自分で設計したと語る要所（[`06_destinations.md:196`](../06_destinations.md)）。

**前提確認**
- [ ] Day1-2 完了
- [ ] `infra/db/migrations/0001_schema.sql:123` の `kind IN ('redmine','github_issues')` 制約を確認（`Kind` 文字列はこれと一致させる）

**手順**
1. `Portfolio.Destinations/DestinationRegistry.cs` — 解決インターフェースと実装の骨格。**ルックアップの中身（kind → 実装の辞書化と Resolve）は自分で書く**:
   ```csharp
   namespace Portfolio.Destinations;

   public interface IDestinationRegistry
   {
       // kind 不一致や未登録なら例外（呼び出し側が握りつぶさないよう明示失敗）
       ITicketDestination Resolve(string kind);
   }

   // DI が注入する全 ITicketDestination 実装を kind で引けるようにするのが役割。
   public sealed class DestinationRegistry(IEnumerable<ITicketDestination> destinations)
       : IDestinationRegistry
   {
       // ここを自分で実装:
       //   - 注入された destinations を d.Kind をキーに辞書化する（IReadOnlyDictionary に保持）。
       //     kind は DB の CHECK 制約で小文字固定 → StringComparer.Ordinal で十分。
       //   - Resolve(kind): 辞書に有れば返す。無ければ NotSupportedException を投げて明示失敗にする
       //     （未登録 kind を握りつぶさない）。
   }
   ```
2. DI 登録用の拡張メソッド `Portfolio.Destinations/ServiceCollectionExtensions.cs` を置く（実装の登録は Day 2 で各アダプタを足すが、枠だけ先に作る）:
   ```csharp
   using Microsoft.Extensions.DependencyInjection;

   namespace Portfolio.Destinations;

   public static class ServiceCollectionExtensions
   {
       public static IServiceCollection AddTicketDestinations(this IServiceCollection services)
       {
           // ここを自分で実装:
           //   - IDestinationRegistry → DestinationRegistry を Singleton 登録。
           //   - 各アダプタは Day2 でここに AddSingleton<ITicketDestination, XxxDestination>() を足す（今は枠だけ）。
           //   - 末尾で services を返す（拡張メソッドの作法）。
           return services;
       }
   }
   ```
   - `Microsoft.Extensions.DependencyInjection.Abstractions` パッケージ参照が必要なら追加（`dotnet add Portfolio.Destinations/Portfolio.Destinations.csproj package Microsoft.Extensions.DependencyInjection.Abstractions`）。
3. `Portfolio.Web/Program.cs` の `builder.Services` 群（`AddHealthChecks()` の手前あたり）に `builder.Services.AddTicketDestinations();` を 1 行追加。

**完了確認**
- [ ] `dotnet build Portfolio.sln` が通る
- [ ] `Program.cs` に `AddTicketDestinations()` がある
- [ ] `Resolve("nope")` が `NotSupportedException`（軽い単体テストで確認してもよい）

**詰まったら**
- `IEnumerable<ITicketDestination>` が空で DI 解決時にエラーにならないか不安 → MVP は空でも可（Resolve 時に初めて失敗）。Day 2 で実装登録後に Resolve が通るのを確認する
- `StringComparer.Ordinal` か `OrdinalIgnoreCase` か → `kind` は DB の CHECK 制約で小文字固定なので `Ordinal` で十分

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## Day1-4. 起票本文 Markdown 化（既存 Streamlit `build_description` の C# 移植）[AI]

**目的**
動的フォームで集めた値を起票本文（Markdown）に組み立てる純関数を作る。既存 Streamlit 版 `build_description` のロジックをそのまま移植する（[`10_existing_streamlit.md:104`](../10_existing_streamlit.md) で「そのまま流用」と決定済み）。出力例は [`06_destinations.md:115-128`](../06_destinations.md)。

**前提確認**
- [ ] Day1-2 完了（`Ticket` の `BodyMarkdown` にこの出力を入れる）
- [ ] [`06_destinations.md:109-130`](../06_destinations.md) の本文フォーマット例を AI に見せられる
- [ ] 既存 `redmine_client.py` の `build_description` 実物（PoC リポジトリ）を参照できるなら添付する。無ければ 06 章の例を仕様とする

**自分が先に決めること**
- [ ] フッターに含める内部 ID: `問題ID = knowledge_entry id`、`問い合わせID = inquiry id`（06 章の例に準拠）。外部チケットから内部 ID を遡及できるようにするのが目的（[`06_destinations.md:130`](../06_destinations.md)）
- [ ] 入力は「ラベル → 値」の順序付きペア列（`IReadOnlyList<(string Label, string Value)>` 想定）。Day 4 のフォームから来る形に寄せる

**AI 依頼テンプレ**
```
Portfolio.Destinations クラスライブラリに、起票本文を Markdown 化する純粋なクラス
TicketBodyBuilder を書いてほしい。Web 非依存（System.Text のみ）。

仕様（design/06_destinations.md の本文フォーマット例に準拠）:
- public static string Build(string sectionTitle,
      IReadOnlyList<(string Label, string Value)> fields,
      Guid knowledgeEntryId, Guid inquiryId)
- 出力は:
  ## {sectionTitle}

  **{Label}:** {Value}
  （fields の各要素を 1 行ずつ。Value 内の改行は維持）

  ---
  *このチケットは社内チャットボットから自動起票されました*
  *問題ID: {knowledgeEntryId}*
  *問い合わせID: {inquiryId}*
- fields が空なら本文セクションは見出しのみ＋区切り線＋フッター
- Value に Markdown 特殊文字が含まれてもエスケープは不要（社内利用前提・PoC 仕様踏襲）

テストも Portfolio.Web.Tests に TicketBodyBuilderTests として:
- fields 2 件のときの完全一致テスト（期待文字列をベタ書き）
- fields 0 件のとき見出し＋フッターのみ
- フッターに knowledgeEntryId / inquiryId が両方含まれる
を書いてほしい。System.Text.Json のみ、Newtonsoft 禁止。
```

**自分の確認ポイント**
- [ ] 出力が 06 章の例とフォーマット一致（見出し `##`、`**ラベル:**`、区切り `---`、フッター 3 行）
- [ ] `knowledgeEntryId` と `inquiryId` が両方フッターに出る（遡及性の根幹）
- [ ] Web 非依存（`using Microsoft.AspNetCore` が無い）
- [ ] テストが green

**詰まったら**
- AI が `inquiry id` を Ticket に持たせようとする → `Ticket` record には inquiry id は無い（06 章定義）。`Build` の引数で別途渡す設計に留める
- フォーマットが微妙にずれる → 期待文字列をベタ書きしたテストを正とし、実装をそれに合わせさせる

---

## Day 1 終了チェックリスト

- [ ] `Portfolio.Destinations` が `Portfolio.sln` にあり、Web から一方向参照されている
- [ ] `ITicketDestination` + `DestinationConfig` / `Ticket` / `TicketSubmitResult` / `TestConnectionResult`（+ 失敗理由 enum）が定義済み
- [ ] `DestinationRegistry` と `AddTicketDestinations()` があり、`Program.cs` で登録済み
- [ ] `TicketBodyBuilder` が 06 章の本文フォーマットを再現し、テストが green
- [ ] `dotnet build Portfolio.sln --configuration Release` と `dotnet test` が通る

## Day 2 への引き継ぎメモ（自分宛て）

- アダプタの `Kind` は DB の CHECK 制約（`'redmine'` / `'github_issues'`）と完全一致させる
- アダプタは `AddTicketDestinations()` 内に `AddSingleton<ITicketDestination, ...>()` で足す
- `SecretValue` は Vault 由来。Day 2 のアダプタは「config に既に復号済みキーが入っている」前提で書く（Vault 復号は Day 3）。テストではダミー文字列を渡す
