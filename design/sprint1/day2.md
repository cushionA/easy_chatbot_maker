# Sprint 1 Day 2 作業指示書（2026-05-18）

> テーマ: **アプリ ↔ DB の認証/テナント導管**
> 完了時の状態: 全テーブルに RLS が当たり、JWT 検証 → テナント解決 → `SET LOCAL` の流れがリクエスト毎に動く。Testcontainers の漏洩テストが green
> 推定所要: 6〜8 時間

---

## Day2-1. RLS ポリシーを残テーブルに展開 [AI 委譲] [INFRA]

**目的**
Day1-4 で `knowledge_entries` に書いたお手本パターンを、残り 9 テーブルに横展開する。**型は自分が握ったので、複製は AI で十分**。

**前提確認**
- [ ] Day 1 完了
- [ ] `infra/db/migrations/0003_rls_policies.sql` の現状を AI に見せられる

**AI 依頼テンプレ**
```
infra/db/migrations/0003_rls_policies.sql に knowledge_entries の RLS ポリシーが既にある。
同じパターン（ENABLE + FORCE + tenant_isolation ポリシー）を以下のテーブルにも追加してほしい:

- categories
- field_definitions
- validation_rules
- destinations
- inquiries
- unclassified_queue
- tenant_public_keys

ただし以下の 2 テーブルは特殊なので別パターンで:

- user_tenants: USING / WITH CHECK は user_id = current_setting('app.user_id', true)::uuid
  （自分のレコードのみ可視）
- tenants: SELECT 専用ポリシー。
  USING (id IN (SELECT tenant_id FROM user_tenants WHERE user_id = current_setting('app.user_id', true)::uuid))
  INSERT/UPDATE/DELETE はアプリから直接行わないので明示的に拒否する別ポリシーは不要、GRANT で絞る方針

ポリシー名は tenant_isolation で統一。user_tenants と tenants は user_isolation / tenant_visibility にして。

完成後、SQL を流して \d <table> の出力で各テーブルに RLS enabled マークが付くことを確認してほしい。
```

**自分の確認ポイント（コードを見るとき）**
- [x] 全テーブルに `FORCE ROW LEVEL SECURITY` が入っている
- [x] `user_tenants` のポリシーが `tenant_id` ではなく `user_id` 基準になっている
- [x] `tenants` のポリシーが `user_tenants` をサブクエリで参照している
- [x] AI が勝手にポリシー名を変えていない

**完了確認**
```powershell
psql "$env:DATABASE_URL_APP" -c "BEGIN; SET LOCAL app.tenant_id = '00000000-0000-0000-0000-000000000001'; SELECT count(*) FROM categories; SELECT count(*) FROM destinations; ROLLBACK;"
```
- 各テーブルが当該テナントの件数のみ返る（事前に検証データを 2 テナント分入れておく）

---

## Day2-2. JWKS 検証ミドルウェアを組み込む [BE]

**目的**
OIDC プロバイダが発行した JWT を `Authorization: Bearer ...` ヘッダから受け取り、JWKS で署名検証してクレームを抽出できる状態にする。

**自分で書く理由**
認証パイプラインの中核。後から「なんとなく動いている」になりやすい部分で、ここで詰まると Day2-3 以降が全部空回りする。

**前提確認**
- [x] `apps/api` に `jose`（または `jwks-rsa`）が入っている（参照済み）
- [ ] `design/04_security_multitenant.md:82-105` を読んだ

**手順**
1. OIDC 設定は環境変数（`.env.local` / Secret Manager）から読む。`appsettings.*` のような設定ファイルにシークレットを置かない:
   ```
   OIDC_ISSUER=https://issuer.example.com/
   OIDC_JWKS_URL=https://issuer.example.com/.well-known/jwks.json
   OIDC_AUDIENCE=easy-chatbot-maker
   ```
2. `apps/api/src/middleware/auth.ts` に JWKS 検証ミドルウェアを実装（`jose` の `createRemoteJWKSet` + `jwtVerify` を使用）:
   ```ts
   import { createRemoteJWKSet, jwtVerify } from "jose";

   const jwks = createRemoteJWKSet(new URL(process.env.OIDC_JWKS_URL!));

   export async function authMiddleware(req, res, next) {
     const header = req.headers.authorization ?? "";
     const token = header.startsWith("Bearer ") ? header.slice(7) : null;
     if (!token) return res.status(401).end();
     try {
       const { payload } = await jwtVerify(token, jwks, {
         issuer: process.env.OIDC_ISSUER,
         audience: process.env.OIDC_AUDIENCE,
         clockTolerance: 30, // exp/nbf の許容秒数
       });
       req.auth = { sub: payload.sub };
       next();
     } catch {
       res.status(401).end();
     }
   }
   ```
   - `jwtVerify` は `iss` / `aud` / `exp`（署名含む）を検証する。`clockTolerance` でクロックスキューを 30 秒許容
3. `apps/api/src/main.ts`（エントリポイント）でルーティングの手前にミドルウェアを挿入する。`/healthz` など公開エンドポイントは除外する

**完了確認**
1. `npm run build`（型チェック含む）が通る
2. ローカル起動して以下を試す:
   - OIDC プロバイダ側で 1 ユーザー作成し、JWT を発行
   - `curl -H "Authorization: Bearer <正規 JWT>" http://localhost:8080/healthz` → 200
   - `curl -H "Authorization: Bearer invalid" http://localhost:8080/healthz` → 200 のまま（`/healthz` は認証不要）
   - 認証必須エンドポイントを 1 個足し、改ざんトークンで 401 を確認

**詰まったら**
- 401 にならない → ミドルウェアを認証必須ルートに掛け忘れている、または挿入順序が後ろすぎる
- JWT の `iss` が一致しない → `OIDC_ISSUER` の末尾スラッシュ有無を含めてプロバイダ discovery と突き合わせる。検証無効化は最終手段
- JWKS 検証失敗 → `OIDC_JWKS_URL` が正しいか、ネットワーク到達性とキャッシュ（`kid` 不一致）を確認

**AI 依頼テンプレ**（雛形だけ AI に書かせる場合）
```
Node + TypeScript（Express/NestJS）で、OIDC プロバイダ発行の JWT を Authorization Bearer ヘッダから受け取って JWKS 検証するミドルウェアを書いてほしい。
- OIDC_JWKS_URL, OIDC_ISSUER, OIDC_AUDIENCE は環境変数から読む
- jose の createRemoteJWKSet + jwtVerify を使い、iss/aud/exp/署名を検証
- clockTolerance は 30 秒
- 検証成功で req.auth.sub にクレームを載せ、失敗で 401
コードのみ。
```

---

## Day2-3. テナント解決ミドルウェア [BE]

**目的**
URL `/t/{slug}/...` の `slug` を読み取り、JWT の `sub`（OIDC subject）から解決した user_id と `user_tenants` を突き合わせて、当該リクエストの `tenant_id` を確定する。確定値はリクエストコンテキスト（`req.tenantId` / `req.userId`）に格納し、Day2-4 のデータ層が拾う。

**自分で書く理由**
認可ロジックの中核。誤ると別テナントに侵入される。

**前提確認**
- [x] Day2-2 完了
- [x] `design/04_security_multitenant.md:82-105` を再読

**手順**
1. 新規ファイル `apps/api/src/middleware/tenant.ts`:
   ```ts
   export async function tenantMiddleware(req, res, next) {
     // /t/{slug}/... 以外はスキップ
     const segs = req.path.split("/").filter(Boolean);
     if (segs.length < 2 || segs[0] !== "t") return next();

     // 認証必須（Day2-2 の authMiddleware が req.auth を入れている）
     const sub = req.auth?.sub;
     if (!sub) return res.status(401).end();

     const slug = segs[1];

     // OIDC sub から内部 user_id を JIT 解決（users.oidc_sub で UPSERT 済み前提）
     // slug -> tenant_id, かつ user_tenants で所属確認
     // ここはミドルウェアなので SET LOCAL 前。owner 接続で引く（後述）
     const { rows } = await ownerPool.query(
       `SELECT ut.tenant_id, u.id AS user_id
          FROM users u
          JOIN user_tenants ut ON ut.user_id = u.id
          JOIN tenants t       ON t.id = ut.tenant_id
         WHERE u.oidc_sub = $1 AND t.slug = $2`,
       [sub, slug],
     );

     if (rows.length === 0) return res.status(403).end();

     req.tenantId = rows[0].tenant_id;
     req.userId   = rows[0].user_id;
     next();
   }
   ```
   - SQL は必ずパラメータ化する（`$1` / `$2`）。`sub` / `slug` は外部入力なので文字列連結しない
2. `apps/api/src/main.ts` で登録（authMiddleware の後、ルートハンドラの前）:
   ```ts
   app.use(authMiddleware);
   app.use(tenantMiddleware);
   ```
3. ミドルウェアが DB を引く都合上、`SET LOCAL` 未発行で `user_tenants` を引くことになる。`user_tenants` のポリシーは `user_id = current_setting('app.user_id', true)::uuid` だが、ミドルウェア時点では `app.user_id` 未設定 → 空集合になってしまう。
   **対処**: ミドルウェアの DB アクセスだけは `portfolio_owner` 接続（`DATABASE_URL_OWNER`）の `pg` プール（`ownerPool`）を使う、もしくは `user_tenants` のポリシーを「未設定時は自分の JWT クレームを使う」形にする。
   **MVP 推奨**: ミドルウェア専用に `ownerPool` を別途用意し、こちらで解決する（接続 URL は `DATABASE_URL_OWNER`）。

**完了確認** — 単体テストで以下 4 ケース:
- [ ] 認証なしで `/t/foo/...` → 401
- [ ] 認証あり、存在しない slug → 403
- [ ] 認証あり、他テナントの slug（自分が所属していない）→ 403
- [ ] 認証あり、自分が所属する slug → 通過、`req.tenantId` に値が入る

**詰まったら**
- `req.auth.sub` が undefined → Day2-2 のミドルウェアが先に走っていない（`app.use` の順序）。または OIDC プロバイダが `sub` 以外のクレーム名を使っていないか確認
- `users` に該当行がない → JIT プロビジョニング（`oidc_sub` で UPSERT）が走る前。初回ログインフローで users へ INSERT されているか確認

**AI 依頼テンプレ**: ミドルウェア本体は自分。**テスト**は AI に依頼する:
```
tenantMiddleware の単体テストを Vitest/Jest で書いてほしい。
モック対象: ownerPool.query をフェイク（user_tenants/tenants の解決結果を差し替え）
ケース: 1) 認証なし→401  2) 存在しない slug→403  3) 他テナント slug→403  4) 自分が所属する slug→次の next() 呼び出し かつ req.tenantId が期待値
```

---

## Day2-4. データ層でリクエスト単位の `SET LOCAL` 発行 [BE]

**目的**
リクエスト単位で `pg` プールから接続を borrow し、`BEGIN` → `SET LOCAL app.tenant_id = '...'; SET LOCAL app.user_id = '...';` → クエリ → `COMMIT` の流れで実行する。**これが RLS の有効/無効を分ける単一のポイント**。`SET LOCAL` はクエリと必ず同一トランザクション内で発行する。

**自分で書く理由**
ここを誤ると、全 RLS が機能しない or 別テナントの値が混入する。

**前提確認**
- [ ] Day2-3 完了
- [ ] `design/04_security_multitenant.md:107-114`（`SET LOCAL` の発行ポイント）を読んだ

**手順**
1. 新規ファイル `apps/api/src/db/withTenant.ts`:
   ```ts
   import { Pool } from "pg";

   const appPool = new Pool({ connectionString: process.env.DATABASE_URL_APP });

   // リクエスト単位で接続を borrow → BEGIN → SET LOCAL → 本処理 → COMMIT
   export async function withTenant<T>(
     tenantId: string,
     userId: string,
     fn: (client) => Promise<T>,
   ): Promise<T> {
     const client = await appPool.connect();
     try {
       await client.query("BEGIN");
       // SET LOCAL はトランザクション内でのみ有効。値は set_config でパラメータ化し SQL injection を避ける
       await client.query("SELECT set_config('app.tenant_id', $1, true)", [tenantId]);
       await client.query("SELECT set_config('app.user_id', $1, true)", [userId]);
       const result = await fn(client);
       await client.query("COMMIT");
       return result;
     } catch (e) {
       await client.query("ROLLBACK");
       throw e;
     } finally {
       client.release();
     }
   }
   ```
   - `set_config(..., true)` の第三引数 `true` は `SET LOCAL` 相当（トランザクションスコープ）。値はパラメータ化できるので文字列連結しない
2. ルートハンドラからはこの `withTenant` 経由でのみ DB を触る:
   ```ts
   const cats = await withTenant(req.tenantId, req.userId, (client) =>
     client.query("SELECT * FROM categories ORDER BY display_order"),
   );
   ```
3. `.env.local` の `DATABASE_URL_APP` を `portfolio_app` の接続文字列にする（Day1-3 で作成済み）
4. ミドルウェアでの所属解決用に `ownerPool`（`DATABASE_URL_OWNER`）を別途用意（Day2-3 で使う）

**完了確認**
- [ ] ログイン後にカテゴリ一覧を引くと、自テナントのものしか返らない（手で別テナント slug を試して 403 ではなく、ちゃんと所属テナントの URL でアクセス）
- [ ] managed Postgres のログに `set_config('app.tenant_id', ...)` を含むトランザクションが毎リクエスト出ている

**詰まったら**
- `SET LOCAL` がトランザクション外で発行され効果なし → `BEGIN` の前や、別の borrow した接続で `set_config` していないか。**必ず同一 client・同一トランザクション内**で `set_config` → クエリ → `COMMIT`
- それでも漏れる → プールから別接続が割り当てられている。`appPool.connect()` で取得した同じ `client` だけを `fn` に渡しているか確認

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## Day2-5. RLS 漏洩テスト [AI 一次実装 → 自分レビュー] [TEST]

**目的**
RLS が **実 Postgres で本当に効いているか** を E2E 寄りのテストで証明する。InMemory プロバイダでは検証できない。

**前提確認**
- [ ] Day2-4 完了
- [ ] Docker Desktop が動いている（Testcontainers が必要）

**自分の責務（先に書く）**
ケースリストを以下に固定:
1. テナント A のユーザーで接続 → A のレコードのみ SELECT で見える
2. テナント A のユーザーで B の `tenant_id` を持つレコード INSERT → 失敗（`WITH CHECK` 違反）
3. テナント A のユーザーで B のレコードを UPDATE → 0 行影響（`USING` で見えない）
4. テナント A のユーザーで B のレコードを DELETE → 0 行影響
5. 上記 1-4 を A↔B 反転で再実行
6. セッション変数未設定で接続 → 全テーブル 0 行（フェイルセーフ）

**AI 依頼テンプレ**
```
Node + TypeScript + Vitest（または Jest）+ @testcontainers/postgresql で RLS 漏洩テストを書いてほしい。

要件:
- @testcontainers/postgresql で Postgres 16 を起動（公式 postgres:16 イメージ）
- infra/db/init.sql, migrations/0001_schema.sql, 0002_rls_roles.sql, 0003_rls_policies.sql をこの順に流す
- テナント A / B と所属ユーザー a-user / b-user を作成（users.oidc_sub も埋める）
- knowledge_entries にそれぞれのテナントのレコードを 1 件ずつ INSERT
- 以下 6 ケースを it.each または個別 it で実装（pg クライアントで BEGIN → set_config(app.tenant_id/user_id) → クエリの形）:
  1. a-user セッションで SELECT → A の 1 件のみ
  2. a-user セッションで B の tenant_id の INSERT → 例外
  3. a-user セッションで B のレコード UPDATE → 0 行影響
  4. a-user セッションで B のレコード DELETE → 0 行影響
  5. 1-4 を b-user で反転
  6. セッション変数未設定で SELECT → 0 行（フェイルセーフ）

ファイル: apps/api/test/rls-isolation.test.ts
RLS 用の test タグ/プロジェクト分けを付ける（CI で別ジョブにする予定）
```

**自分の確認ポイント**
- [ ] テストが green であることを確認したあと、**わざと `0003_rls_policies.sql` の `FORCE` 行をコメントアウトして再実行 → 一部ケースが red になる** ことを確認。green が偶然でない証拠を取る

**完了確認**
- [ ] 6 ケース全部 green
- [ ] 「ポリシー外すと red」を一度経験済み
- [ ] CI の workflow にこのテストを実行するステップを追加（または別ジョブとして分離）

---

## Day2-6. CI/CD パイプラインを新スタックで整備 [AI 一次実装 → 自分レビュー] [INFRA] [TEST]

**目的**
既存リポジトリの CI（`.github/workflows/ci.yml` / `codeql.yml` / `.pre-commit-config.yaml`）は旧 .NET スタック構成のまま。新スタック（Node/TS + Python FastAPI）へ置換し、**Day2-5 の RLS E2E を必須ゲート**にして「漏洩を物理的に止める」ことを CI でも担保する。面接で「RLS 越境テストを CI の必須ゲートに組み込み、落ちたら merge できない運用にした」と語れる。

**自分で書く理由（一部）**
YAML 一次実装は AI で良いが、**何を必須ゲートにするか**（RLS E2E は必須、secrets はベタ書き禁止）と**ジョブ分割の方針**は自分が握る。CI は品質の最後の砦。

**前提確認**
- [ ] 新スタックの monorepo 雛形（`apps/api` / `apps/web` / `services/embedding`）が存在する（Sprint 0 の再整備）
- [ ] 既存 `ci.yml`（dotnet/embedding/docker-build/pr-security）・`codeql.yml`（C#/Python）・`.pre-commit-config.yaml`（dotnet-format 等）を確認した
- [ ] Day2-5 の RLS テスト（`apps/api/test/rls-isolation.test.ts`）が green

**手順**
1. `ci.yml` の **backend(dotnet) ジョブ → Node ジョブ**に置換：`pnpm install --frozen-lockfile` → `eslint` → `tsc --noEmit`（typecheck）→ `vitest run`（単体・結合）→ `pnpm build`。
2. **E2E ジョブを分離**：Playwright を service containers（`postgres:16` / OpenSearch / embedding コンテナ）付きで起動。`@testcontainers/postgresql` を使う RLS テストは Node ジョブ内 or 専用ジョブで。
3. **embedding(Python) ジョブは維持**（`ruff` / `mypy` / `pytest`）。
4. **docker-build** を `apps/api` / `apps/web` / `services/embedding` の 3 イメージに。buildx + レイヤキャッシュ。
5. **pr-security** ジョブ（gitleaks / `pr-validate`）は維持。
6. `codeql.yml` のマトリクスを **`javascript-typescript` / `python`** に。
7. `.pre-commit-config.yaml` の **`dotnet-format` → `prettier` + `eslint`**。`ruff` / `gitleaks` / `detect-private-key` / `pr-validate` は維持。
8. **必須ゲート**：ブランチ保護で Node テスト・embedding・**RLS E2E** を required に。secrets（DB 接続 / OIDC / Secret Manager）はすべて `secrets.*` 経由。
9. **CD（デプロイ）骨子**：イメージを GHCR / レジストリへ push → Cloud Run / ECS デプロイ。MVP は手動（`workflow_dispatch`）で可、本格 CD は Phase 2。

**完了確認**
- [ ] PR を上げると Node（lint/typecheck/test/build）・embedding（ruff/mypy/pytest）・docker-build が回る
- [ ] **RLS E2E が required ジョブ**で、落ちると merge できない
- [ ] `codeql` が js-ts / python で回る
- [ ] `pre-commit run -a` が prettier/eslint/ruff/gitleaks で通る
- [ ] secrets はすべて GitHub Secrets 経由（YAML 本文にベタ書きなし）

**詰まったら**
- E2E が CI で不安定 → service containers の `--health-cmd` で起動待ち、Playwright の `trace: on-first-retry`
- docker build が遅い → `docker/build-push-action` + `cache-from/to: gha`
- OpenSearch コンテナが OOM → ランナーのメモリ上限。E2E は最小データで

**AI 依頼テンプレ**
```
.github/workflows/ci.yml を新スタック構成へ書き換えてほしい。ジョブ:
1) node: pnpm install --frozen-lockfile → eslint → tsc --noEmit → vitest run → pnpm build（apps/api, apps/web）
2) e2e: Playwright。service containers に postgres:16 / opensearch / embedding を起動し health 待ち
3) embedding: services/embedding を ruff / mypy / pytest
4) docker-build: apps/api, apps/web, services/embedding を buildx + gha cache でビルド
5) security: gitleaks + .claude/scripts/pr-validate.py（既存踏襲）
制約: secrets は secrets.* 経由のみ、actions の version は既存に合わせる、concurrency 付ける。
あわせて codeql.yml を javascript-typescript/python マトリクスに、.pre-commit-config.yaml の dotnet-format を prettier+eslint に置換。
RLS E2E（apps/api/test/rls-isolation.test.ts）が落ちたら fail するよう必須ジョブにする。
```

---

## Day 2 終了チェックリスト

- [ ] CI が PR で回る（Node: lint/typecheck/test/build、embedding: ruff/mypy/pytest）。**RLS E2E が必須ゲート**
- [ ] 全 11 テーブルに RLS ポリシーが適用済み（特殊 2 テーブル含む）
- [ ] 正規 JWT → 200、改ざん/期限切れ → 401
- [ ] 別テナント slug → 403、所属テナント slug → 通過
- [ ] `SET LOCAL` が毎リクエスト同一トランザクション内で Postgres ログに出ている
- [ ] Testcontainers の 6 ケースが green、ポリシー外すと red になることも確認
- [ ] `ownerPool`（owner 接続）と `appPool`（app 接続）が分離されている

## Day 3 への引き継ぎメモ

- Day3 では `/t/{slug}/categories` 系の React ページ + Node API を書く。ミドルウェアは既に `slug → tenant_id` を解決済みなので、API ハンドラ側は `req.tenantId` を `withTenant` に渡せば自動で絞られる
- Excel 取込スクリプトはミドルウェアを通らないので、`ownerPool` でテナント作成 → 個別接続で `SET LOCAL`（`set_config`）してデータ投入、の 2 段で組む

> **対応済み（Day2-2 で発覚 / DB 接続の前提）**: `.env.local` の `DATABASE_URL_APP` は URL 形式（`postgresql://user:pass@host/db`）。`pg` の `Pool({ connectionString })` は URL 形式をそのまま受け付けるので、文字列パースの自前変換は不要。ただし managed Postgres は SSL 必須のことが多く、URL に `?sslmode=require` が無いと接続が拒否される。対応 — `appPool` / `ownerPool` 生成時に `ssl: { rejectUnauthorized: false }`（または CA 指定）を明示し、URL とコード両経路で SSL 要件を 1 箇所に集約。生 `.env.local`（URL 形式）でローカル起動成功を確認済み。
>
> TODO（PR #30 レビュー指摘 / 今すぐではないフォロー）:
> - SSL 設定は本番固定にせず、ローカル docker postgres（SSL 非対応）では `?sslmode=disable` を尊重できるよう、接続文字列のクエリを見て切り替える
> - プール生成は副作用なので、接続文字列の正規化（URL → 設定オブジェクト）を純粋関数に切り出し、`apps/api/test` にユニットテスト3本（SSL 有 / SSL 無 / ポート省略）を足すと回帰防止になる
