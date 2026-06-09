# Sprint 3 Day 3 作業指示書（2026-05-29）

> テーマ: **Secret Manager と UI を結線する**
> 完了時の状態: API キーが Secret Manager に暗号化保管され、起票時にアプリ層が IAM 権限で Secret Manager から取得して `DestinationConfig.secretValue` に載る。destination の登録/編集 + 接続テストの最小 React + Node API が動く。起票実行サービスが、成功時 `inquiries.status='created'`、失敗時 `'failed'` + `draft_fields` 保持、成功時 `draft_fields` NULL クリアを行う。
> 推定所要: 6〜8 時間

> 参照の正: [`04_security_multitenant.md:121-146`](../04_security_multitenant.md)（シークレット管理）、[`06_destinations.md:146-179`](../06_destinations.md)（失敗時挙動・接続テスト・シークレット参照）。
> 横断ルール: API キーは アプリ設定禁止・Secret Manager のみ（BYOK、[`CLAUDE.md`](../../CLAUDE.md)）。クライアント由来 tenant id は信頼しない（JWT クレーム / RLS コンテキスト）。

---

## Day3-1. Secret Manager でのシークレット作成/取得手順を確立する [自分] [INFRA]

**目的**
API キーを平文で `destinations.config` に置かず、Secret Manager（AWS Secrets Manager / GCP Secret Manager）に暗号化保管する。アプリ層には IAM ロール/サービスアカウントで EXECUTE 相当の権限（`secretsmanager:GetSecretValue` 等）だけ与え、直接 DB アクセスは許さない。これがテナント越境のシークレット読出しを防ぐ最終境界（[`04_security_multitenant.md:135-142`](../04_security_multitenant.md)）。

`destinations.secret_ref`（text 型）に Secret Manager のシークレット名/ARN/リソース ID を保存し、アプリ層が起票時にその参照を使ってシークレットを取得する。

**自分で書く理由**
秘匿情報の境界は漏洩したら一発アウト。IAM ポリシーの設計（最小権限）と `secret_ref` の命名規則（テナント ID を含む等）を誤ると越境読出しになる。面接で「Secret Manager に API キーを暗号化保管、アプリ層は IAM 権限で取得のみ、DB にはシークレット名（参照）だけ持つ」と語る要所。

**前提確認**
- [ ] 使用する Secret Manager（AWS Secrets Manager / GCP Secret Manager）を決める
- [ ] [`04_security_multitenant.md:121-142`](../04_security_multitenant.md) を読んだ
- [ ] `destinations.secret_ref`（`text`）列が存在、またはマイグレーションで追加する

**手順**
1. 新規 migration `infra/db/migrations/0004_secret_ref.sql` を作成（番号は既存の最新+1 に合わせる。`ls infra/db/migrations/` で確認）。`destinations` テーブルに `secret_ref text` 列を追加（最新スキーマでは `0001_schema.sql` で定義済み。未定義環境向けの冪等な補助マイグレーション）:
   ```sql
   ALTER TABLE public.destinations
     ADD COLUMN IF NOT EXISTS secret_ref text;
   ```
2. **シークレット命名規則を決める**（越境防止の肝）。シークレット名にテナント ID + destination ID を含める例:
   ```
   {env}/tenants/{tenantId}/destinations/{destinationId}/api-key
   例: prod/tenants/abc123/destinations/def456/api-key
   ```
   - 命名規則を `apps/api/src/destinations/secretRef.ts` にコンスタントとして定義する（後続の `IDestinationSecretStore` 実装で使う）。
3. **SDK でのシークレット作成（保存）手順**（手動 or スクリプト）:
   - AWS の場合: `aws secretsmanager create-secret --name {name} --secret-string {apiKey}`
   - GCP の場合: `gcloud secrets create {name} --replication-policy=automatic && echo -n {apiKey} | gcloud secrets versions add {name} --data-file=-`
   - 上記手順をコメント付きで `infra/scripts/create-destination-secret.sh`（または `.ts`）として残す。
4. **IAM 権限の設定**: アプリの実行ロール（EC2 Instance Profile / Cloud Run Service Account 等）に最小限の権限を付与:
   - AWS: `secretsmanager:GetSecretValue` のみ。Resource を `arn:aws:secretsmanager:{region}:{account}:secret:{env}/tenants/*` に絞る。
   - GCP: `roles/secretmanager.secretAccessor` をシークレットリソースレベルで付与。
   - IAM ポリシードキュメントを `infra/iam/destinations-secret-policy.json`（または `.yaml`）に残す。

**完了確認**
- [ ] テスト用シークレット 1 件を作成し、アプリの実行ロールで `GetSecretValue` が成功する
- [ ] アプリの実行ロールでは Secret Manager コンソール/一覧の閲覧ができない（最小権限）
- [ ] 別テナントの `secret_ref` を直接 SDK で取得しようとすると IAM 拒否される（命名規則による越境防止を確認）

**詰まったら**
- IAM 権限エラー（AccessDeniedException / PERMISSION_DENIED）→ アプリの実行ロールにポリシーが正しくアタッチされているか、Resource ARN/パターンが一致しているか確認
- シークレット名のスラッシュが使えない環境 → `__` でエスケープする等、環境に合わせた命名規則に変更する
- ローカル開発での認証 → AWS の場合は `~/.aws/credentials` または環境変数 `AWS_ACCESS_KEY_ID`、GCP の場合は `GOOGLE_APPLICATION_CREDENTIALS` を設定

**AI 依頼テンプレ**: なし（秘匿境界の設計と IAM 設定は自分で行う範囲）

---

## Day3-2. `IDestinationSecretStore`（アプリ層から Secret Manager を呼ぶ薄いラッパ）[自分] [BE]

**目的**
Day3-1 の手順で確立した Secret Manager アクセスを TypeScript から呼ぶ薄い interface と実装を置く。アプリ側は「Secret Manager を意識せずシークレットを保存/取得」できる。起票時はここで取得して `DestinationConfig` を組む。

**自分で書く理由**
秘匿情報の取り扱い境界。SDK 呼出をどこで・どんな型で行うかは設計判断で、ここにシークレットがメモリ上で滞留するので「ログに出さない」「保持しない」を自分で担保する。

**前提確認**
- [ ] Day3-1 完了
- [ ] AWS SDK v3 (`@aws-sdk/client-secrets-manager`) または GCP `@google-cloud/secret-manager` を `package.json` に追加済み

**手順**
1. `apps/api/src/destinations/IDestinationSecretStore.ts`:
   ```typescript
   export interface IDestinationSecretStore {
     // destination の API キーを Secret Manager に保存し、secret_ref（参照名）を返す
     setSecret(destinationId: string, tenantId: string, secret: string): Promise<string>;

     // destination の API キーを Secret Manager から取得して返す（呼び出し直後だけ保持、ログ厳禁）
     getSecret(secretRef: string): Promise<string>;
   }
   ```
2. 実装 `apps/api/src/destinations/DestinationSecretStore.ts`（AWS Secrets Manager の例）:
   ```typescript
   import {
     SecretsManagerClient,
     CreateSecretCommand,
     GetSecretValueCommand,
   } from '@aws-sdk/client-secrets-manager';
   import type { IDestinationSecretStore } from './IDestinationSecretStore';
   import { buildSecretName } from './secretRef'; // Day3-1 の命名規則

   export class DestinationSecretStore implements IDestinationSecretStore {
     constructor(private readonly client: SecretsManagerClient) {}

     async setSecret(destinationId: string, tenantId: string, secret: string): Promise<string> {
       // ここを自分で実装:
       //   1. buildSecretName(tenantId, destinationId) でシークレット名を生成
       //   2. CreateSecretCommand でシークレットを作成（既存の場合は UpdateSecretCommand）
       //   3. シークレット名（secret_ref）を返す
       //   ※ secret を console.log / logger に出さない
     }

     async getSecret(secretRef: string): Promise<string> {
       // ここを自分で実装:
       //   1. GetSecretValueCommand で secretRef を指定して取得
       //   2. SecretString を返す
       //   ※ 返却値をログに出さない。例外メッセージにも含めない
     }
   }
   ```
3. DI/ファクトリ（`bootstrap.ts` またはアプリのエントリポイント）で `IDestinationSecretStore` を登録する:
   ```typescript
   const secretStore = new DestinationSecretStore(new SecretsManagerClient({ region: process.env.AWS_REGION }));
   ```
   - `AWS_REGION` 等の設定値は環境変数から取得。アプリ設定ファイルにはシークレット値を書かない。

**完了確認**
- [ ] 手動または統合テスト: 自テナントで `setSecret` → `getSecret` がラウンドトリップする
- [ ] 存在しない `secretRef` を `getSecret` に渡すと SDK のエラーが伝播する（握りつぶさない）
- [ ] シークレット値がログに出ていない（ロガーを一時的に有効化して確認）

**詰まったら**
- SDK の型エラー → `SecretString` が `string | undefined` なので Non-null assertion か Optional chaining でガードする
- `setSecret` で既存シークレットを上書きしたい → `PutSecretValueCommand`（AWS）または `addVersion`（GCP）を使う

**AI 依頼テンプレ**: なし（秘匿境界は自分。ただし統合テストは AI に依頼してよい）

---

## Day3-3. destination 登録/編集 + 接続テストボタンの最小 React + Node API [AI] [FE] [BE]

**目的**
テナント admin が起票先を登録/編集し、保存前に「接続テスト」できる最小画面を作る。Sprint 1 の Category CRUD と同じ CRUD パターンの複製。接続テスト失敗時は登録させない（[`06_destinations.md:166-172`](../06_destinations.md)）。

**前提確認**
- [ ] Day3-2 完了（シークレット保存ができる）
- [ ] Sprint 1 の Category CRUD（一覧/作成/編集）が動く（複製元）
- [ ] `Destination` エンティティの列を確認（`kind` / `name` / `config` / `secretRef` / `isPrimary` / `fieldMapping` / `sortOrder`）

**自分が先に決めること**
- [ ] API ルート: `GET/POST /api/t/:tenantId/destinations`、`GET/PUT /api/t/:tenantId/destinations/:id`、`POST /api/t/:tenantId/destinations/test-connection`
- [ ] フロント URL: `/t/{slug}/settings/destinations`（一覧）、`/new`、`/:id/edit`
- [ ] 入力フォームの項目: `name` / `kind`(redmine|github_issues のセレクト) / `config`(JSON textarea: base_url・project_id / owner・repo) / API キー(`<input type="password">`、保存時のみ Secret Manager へ) / `fieldMapping`(JSON textarea) / `isPrimary`
- [ ] API キーは **画面に既存値を再表示しない**（編集時は「変更する場合のみ入力」。空なら据え置き）

**AI 依頼テンプレ**
```
Sprint 1 の Category CRUD（Node API + React フロント）を参考に、起票先（destinations）の
登録/編集 + 接続テストの最小 UI + API を作ってほしい。認証済みユーザー（admin）のみアクセス可。

Node API エンドポイント（Express または既存フレームワークに合わせる）:
1. GET  /api/t/:tenantId/destinations
   - DB から destinations 一覧（name / kind / isPrimary）。RLS で自テナント分のみ。
2. POST /api/t/:tenantId/destinations
   - 登録。body: { name, kind, config(JSON string), apiKey, fieldMapping(JSON string), isPrimary }
   - 保存手順: ① destinations 行を INSERT（tenantId は JWT クレームから取得、クライアントから受け取らない）
              ② IDestinationSecretStore.setSecret(id, tenantId, apiKey) でシークレット保存
              ③ destinations.secret_ref を UPDATE
   - config / fieldMapping は JSON 妥当性を保存前に検証（不正 JSON はエラー）。
3. PUT  /api/t/:tenantId/destinations/:id
   - 編集。apiKey が空文字なら Secret Manager は据え置き、入力ありなら更新。
4. POST /api/t/:tenantId/destinations/test-connection
   - body: { kind, config(JSON), apiKey }
   - IDestinationRegistry.resolve(kind).testConnection を呼び、TestConnectionResult を返す。
   - apiKey は DB には保存せず、この呼出のみに使う。

React フロント（既存の Category CRUD コンポーネントに合わせる）:
1. /t/{slug}/settings/destinations — 一覧（name / kind / isPrimary / 編集リンク）
2. /t/{slug}/settings/destinations/new — 作成フォーム
   - フィールド: name(必須,max100) / kind(select: redmine|github_issues) /
     config(textarea, JSON) / apiKey(type=password) /
     fieldMapping(textarea, JSON, 任意) / isPrimary(checkbox)
   - 「接続テスト」ボタン: 入力中の config + apiKey で POST test-connection を呼ぶ。
     結果を表示（成功=緑、失敗=赤＋理由）。
   - 「保存」ボタン: 接続テスト成功でなければ保存させない（失敗/未実施なら警告）。
3. /t/{slug}/settings/destinations/:id/edit — 編集フォーム
   - 既存ロード。apiKey 欄は空表示（既存値は再取得・再表示しない）。
   - 同じ接続テストボタン。見つからなければ 404 返却。

制約（重要）:
- API キーは画面・ログ・アプリ設定に残さない。IDestinationSecretStore 経由のみ。
- tenantId はクライアントから受け取らない（JWT クレームから取得）。
- 不正 JSON の config を 400 で弾く。
```

**自分の確認ポイント**
- [ ] 接続テスト成功 → 保存可、失敗 → 保存ブロック
- [ ] API キーが編集画面で平文再表示されない、ログに出ない
- [ ] 不正 JSON の Config を弾く
- [ ] 別テナントの destination id を踏むと 404（RLS で見えない）
- [ ] `isPrimary` を 2 つ true にすると DB の部分ユニークインデックス（`0001_schema.sql:134`）で弾かれる → エラーが画面に出る

**詰まったら**
- 接続テストで `secretValue` をどう渡す? → 保存前は画面入力のキーを直接 `DestinationConfig.secretValue` に。保存後（編集の再テスト）は `IDestinationSecretStore.getSecret(destination.secretRef)`
- React フォームの状態管理 → Sprint 1 の Category フォームと同じライブラリ/パターン（react-hook-form 等）に合わせる

---

## Day3-4. 起票実行サービス（`draft_fields` 保持/クリア + フィールドマッピング優先度変換）[自分 が骨子 → AI が肉付け] [BE]

**目的**
「`Ticket` を組んで → Secret Manager から取得 → `DestinationConfig` を作って → `resolve(kind).submit` → 結果で `inquiries` を更新」の 1 本のサービスを置く。起票失敗時に `draft_fields` を短期保持、成功時に NULL クリアする（[`06_destinations.md:160-164`](../06_destinations.md)、プライバシー観点）。Sprint 4 の起票画面はこのサービスを呼ぶだけになる。

**自分で書く理由**
`draft_fields` の保持/クリアと `inquiries.status` 遷移は、プライバシー方針（失敗時のみ保持）と業務状態機械の中核。優先度変換をどこで効かせるか（アダプタが `fieldMapping` を読む設計なので、ここでは `Ticket.priority` を正しく載せるだけ）を握る。骨子（インターフェースと状態遷移）を自分で書き、DB アクセス詳細は AI に肉付けさせる。

**前提確認**
- [ ] Day3-2 / Day3-3 完了
- [ ] [`06_destinations.md:146-164`](../06_destinations.md)（フロー図）を読んだ
- [ ] `Inquiry` エンティティの列を確認（`status` / `draftFields` / `destinationId` / `externalTicketId` / `externalTicketUrl` / `matchedKnowledgeId`）
- [ ] `inquiries.status` は NOT NULL。`'created'` 遷移で `match_count` トリガーが走る（`0001_schema.sql:224-238`）

**手順（自分が骨子を書く）**
1. `apps/api/src/services/ITicketSubmissionService.ts`:
   ```typescript
   export interface SubmissionRequest {
     inquiryId: string;
     destinationId: string;
     title: string;
     bodyMarkdown: string;
     ticketPriority: 'low' | 'normal' | 'high' | 'urgent';
     knowledgeEntryId: string;
     draftFieldsJson: string; // 失敗時に保持するフォーム入力（jsonb）
   }

   export interface ITicketSubmissionService {
     submit(req: SubmissionRequest): Promise<TicketSubmitResult>;
   }
   ```
2. 実装の状態遷移の骨子（自分で固定し、DB アクセス詳細以外を握る）:
   ```
   submit:
     1. destinations を id で取得（RLS で自テナント分のみ。kind / config / fieldMapping / secretRef を読む）
     2. secret = await IDestinationSecretStore.getSecret(destination.secretRef)  ← Secret Manager 取得
     3. cfg = { publicConfig: JSON.parse(destination.config),
                secretValue: secret,
                fieldMapping: JSON.parse(destination.fieldMapping ?? '{}') }
        ※ 優先度変換はアダプタが fieldMapping から行う。ここでは priority をそのまま載せる
     4. ticket = { title, bodyMarkdown, priority, tenantId, knowledgeEntryId }
     5. result = await registry.resolve(destination.kind).submit(ticket, cfg)
     6. inquiry を id で取得し:
        成功 → status='created', externalTicketId/Url=result, draftFields=null, destinationId 設定
        失敗 → status='failed', draftFields=req.draftFieldsJson（短期保持）
        DB 更新（status 更新でトリガーが match_count を回す）
     7. return result
   ```
   - **成功時に `draftFields=null` クリアは必須**（[`06_destinations.md:164`](../06_destinations.md)）。失敗時のみ保持。
   - secret はこのメソッドのローカル変数に留め、`inquiries` 等どこにも書かない・ログに出さない。
3. DB アクセスの細部（ORM/クエリビルダの書き方、エラーメッセージ整形、`status` 文字列定数化）は AI に肉付けさせる（下記テンプレ）。
4. DI/ファクトリでサービスを登録する。

**AI 依頼テンプレ（骨子を渡したあと肉付けを依頼）**
```
ITicketSubmissionService の実装 TicketSubmissionService を肉付けしてほしい。骨子（状態遷移）は
ITicketSubmissionService.ts のコメント通り。DB クライアント / IDestinationRegistry /
IDestinationSecretStore をコンストラクタ注入。

要件:
- destinations.config(string jsonb) / fieldMapping(string?) を JSON.parse して DestinationConfig へ
- 成功: inquiries.status="created", externalTicketId/Url 設定, destinationId 設定, draftFields=null
- 失敗: inquiries.status="failed", draftFields=req.draftFieldsJson（成功時は必ず null クリア）
- status 文字列は const で定義（"created"/"failed"）
- secret はローカル変数のみ・ログ厳禁・例外メッセージに含めない
- 単体テスト（Vitest または Jest）:
  - 成功時 draftFields が null になる
  - 失敗時 draftFields が保持され status="failed"
  - getSecret が 1 回だけ呼ばれる
  ※ IDestinationRegistry / IDestinationSecretStore はモック、DB は Jest インメモリか Testcontainers
```

**自分の確認ポイント**
- [ ] 成功 → `draftFields` が null、`status='created'`、外部 ID/URL が入る
- [ ] 失敗 → `draftFields` 保持、`status='failed'`
- [ ] 優先度が Redmine では priority_id、GitHub では labels に変換される（Day 2 のマッピング経由）
- [ ] シークレットがどこにも永続化・ログ出力されていない
- [ ] テスト green

**詰まったら**
- `'created'` にしてもトリガーが回らない → `matchedKnowledgeId` が null だとトリガー条件に合わない（`0001_schema.sql:225`）。`matchedKnowledgeId` が入っているか確認。回らなくても起票自体は成功扱いでよい
- `draftFields` が成功後も残る → 成功分岐で明示的に `inquiry.draftFields = null` を入れる（最重要・プライバシー）

---

## Day 3 終了チェックリスト

- [ ] `0004_secret_ref.sql` が動き、`destinations.secret_ref` に Secret Manager のシークレット名が保存できる
- [ ] 別テナントのシークレット名を IAM 権限で取得しようとすると拒否される（越境拒否を確認）
- [ ] destination 登録/編集 UI で接続テスト → 成功時のみ保存、API キーは Secret Manager 保管・画面/ログに残らない
- [ ] 起票実行サービスが 成功=`created`+draftFields クリア / 失敗=`failed`+draftFields 保持 を満たす
- [ ] 優先度変換が Redmine=priority_id / GitHub=labels で効く
- [ ] `pnpm build` / `pnpm test` が green、`make secrets`（gitleaks）に引っかかる平文キーが無い

## Sprint 3 完走後の状態

- 起票の「配管」が全部つながった: `submit` を呼べば、テナント設定の起票先へ、Secret Manager から取得した API キーで、優先度変換とリトライ付きで起票できる
- 残り（Sprint 4 以降）:
  - **起票画面の本結線**（分類確定 → 動的フォーム → `SubmissionRequest` 組立 → `ITicketSubmissionService`）
  - **再試行 / destination 切替提案の UX**（失敗時 `draftFields` から復元）
  - **fan-out / Jira 等の追加アダプタ** — Phase 2 の拡張点（[`06_destinations.md:54-61,68`](../06_destinations.md)）
