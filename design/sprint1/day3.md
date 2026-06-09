# Sprint 1 Day 3 作業指示書（2026-05-19）

> テーマ: **最初の画面と CRUD**
> 完了時の状態: `/t/{slug}/categories` で一覧/作成/編集が動き、Excel 取込でデモテナントのデータが画面に出る
> 推定所要: 5〜7 時間

---

## Day3-1. ルーティングを `/t/{slug}/...` 形式に整える [FE]

**目的**
URL に `slug` が必須なルーティングに切り替え、Day2-3 のミドルウェアが意味を持つ状態にする。既存トップページはデバッグ用に退避。

**自分で書く理由**
URL 設計はサービスの顔。後から変更すると影響範囲が広い。

**前提確認**
- [ ] Day 2 完了
- [ ] `design/04_security_multitenant.md:148-155`（URL 設計）を読んだ

**手順**
1. 既存トップページのルートを `/` から `/t/:slug/_debug/embedding` に変更（React Router の route 定義）
   ```tsx
   // apps/web/src/App.tsx（ルート定義の例）
   <Route path="/t/:slug/_debug/embedding" element={<EmbeddingDebug />} />
   ```
   ```tsx
   // EmbeddingDebug 側で slug を受ける
   const { slug } = useParams();
   ```
2. 新規 `apps/web/src/pages/Landing.tsx` を `/` ルートで作成し、簡単な「ログインして /t/{slug}/chat へ」案内 + 自分が所属するテナント一覧リンクを表示
3. レイアウトコンポーネント（`apps/web/src/layouts/MainLayout.tsx`）を改装:
   - URL の `slug` を `useParams` で取得し、配下のページに props か context で流す
   - MVP では各ページで `useParams().slug` を読む単純実装で十分
   - sidebar に `Chat` / `Categories` / `Knowledge` / `Settings` の 4 リンクを置く（実体は今日 Category だけ）

**完了確認**
- [ ] `/` → ランディング
- [ ] `/t/tenant-a/_debug/embedding` → Embedding 動作確認画面（認証 + 所属チェック後）

---

## Day3-2. Category 一覧ページ `/t/{Slug}/categories` [FE] [BE]

**目的**
RLS が UI 経由でも効いていることを目視確認できる最初のページ。

**前提確認**
- [ ] Day3-1 完了
- [ ] Day1-4 で投入した手動データが残っている

**手順**
1. 新規 API エンドポイント `apps/api/src/routes/categories.ts`（一覧）:
   ```ts
   // GET /t/:slug/categories  （authMiddleware → tenantMiddleware 通過済み）
   router.get("/t/:slug/categories", async (req, res) => {
     const rows = await withTenant(req.tenantId, req.userId, (client) =>
       client.query("SELECT id, name, description, display_order FROM categories ORDER BY display_order"),
     );
     res.json(rows.rows);
   });
   ```
   **重要**: `WHERE tenant_id = ?` を書かない。RLS が絞るのを目視確認したい。
2. 新規 React ページ `apps/web/src/pages/categories/Index.tsx`:
   ```tsx
   export function CategoriesIndex() {
     const { slug } = useParams();
     const [rows, setRows] = useState<Category[] | null>(null);

     useEffect(() => {
       fetch(`/t/${slug}/categories`).then((r) => r.json()).then(setRows);
     }, [slug]);

     if (rows === null) return <p>Loading...</p>;
     return (
       <>
         <h2>Categories</h2>
         <a href={`/t/${slug}/categories/new`}>+ New</a>
         <table>
           <thead><tr><th>Name</th><th>Description</th><th>Order</th><th></th></tr></thead>
           <tbody>
             {rows.map((c) => (
               <tr key={c.id}>
                 <td>{c.name}</td>
                 <td>{c.description}</td>
                 <td>{c.displayOrder}</td>
                 <td><a href={`/t/${slug}/categories/${c.id}/edit`}>Edit</a></td>
               </tr>
             ))}
           </tbody>
         </table>
       </>
     );
   }
   ```
   - 認証必須ルートにマウントする（未ログインはログイン誘導）

**完了確認**
- [ ] `/t/tenant-a/categories` でテナント A のカテゴリのみ表示
- [ ] `/t/tenant-b/categories` でテナント B のカテゴリのみ表示
- [ ] 別テナントの slug で 403（ミドルウェアの仕事）

**詰まったら**
- 全テナント分のデータが見える → `SET LOCAL` が効いていない、Day2-4 へ戻る
- 0 件しか見えない → `set_config` 未発行で接続している可能性。`req.tenantId` がハンドラに届いているか、`withTenant` を経由しているかログで確認

---

## Day3-3. Category 作成ページ `/t/{Slug}/categories/new` [FE] [BE]

**目的**
**React フォーム + Node API のお手本となる最初の 1 ページ**を自分の手で書く。これが Knowledge / FieldDefinition で AI に複製させるテンプレになる。

**自分で書く理由**
バリデーション + 保存 + リダイレクト + RLS 適用の最初の組み合わせ。説明責任を負う部分。

**前提確認**
- [ ] Day3-2 完了
- [ ] `categories` テーブルのカラム（`03_db_schema.md`）を確認

**手順**
1. 新規 API エンドポイント `apps/api/src/routes/categories.ts`（作成）:
   ```ts
   // POST /t/:slug/categories
   router.post("/t/:slug/categories", async (req, res) => {
     const { name, description, displayOrder } = req.body;
     // 境界バリデーション（外部入力）
     if (!name || name.length > 100) return res.status(400).json({ error: "name" });
     if (description && description.length > 500) return res.status(400).json({ error: "description" });

     try {
       // tenant_id は RLS の WITH CHECK で current_setting と一致が必須。
       // req.tenantId（middleware が入れた値）を使い、withTenant のトランザクション内で INSERT。
       await withTenant(req.tenantId, req.userId, (client) =>
         client.query(
           `INSERT INTO categories (id, tenant_id, name, description, display_order)
            VALUES (gen_random_uuid(), $1, $2, $3, $4)`,
           [req.tenantId, name, description ?? null, displayOrder ?? 0],
         ),
       );
       res.status(201).end();
     } catch (e) {
       // WITH CHECK 違反などはここに来る（Day3-4 でメッセージ整備）
       res.status(500).json({ error: "save failed" });
     }
   });
   ```
   - SQL はパラメータ化（`$1..$4`）。`tenant_id` はクライアント入力ではなく `req.tenantId` を使う
2. 新規 React ページ `apps/web/src/pages/categories/Create.tsx`:
   ```tsx
   export function CategoriesCreate() {
     const { slug } = useParams();
     const navigate = useNavigate();
     const [form, setForm] = useState({ name: "", description: "", displayOrder: 0 });
     const [errors, setErrors] = useState<string[]>([]);

     async function onSubmit(e: FormEvent) {
       e.preventDefault();
       const errs: string[] = [];
       if (!form.name) errs.push("Name is required");
       if (form.name.length > 100) errs.push("Name too long");
       setErrors(errs);
       if (errs.length) return;

       const res = await fetch(`/t/${slug}/categories`, {
         method: "POST",
         headers: { "Content-Type": "application/json" },
         body: JSON.stringify(form),
       });
       if (res.ok) navigate(`/t/${slug}/categories`);
       else setErrors(["Save failed"]);
     }

     return (
       <form onSubmit={onSubmit}>
         <h2>New category</h2>
         {errors.length > 0 && <ul>{errors.map((e) => <li key={e}>{e}</li>)}</ul>}
         <div><label>Name *</label>
           <input value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} /></div>
         <div><label>Description</label>
           <textarea value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} /></div>
         <div><label>Display order</label>
           <input type="number" value={form.displayOrder}
             onChange={(e) => setForm({ ...form, displayOrder: Number(e.target.value) })} /></div>
         <button type="submit">Save</button>
         <a href={`/t/${slug}/categories`}>Cancel</a>
       </form>
     );
   }
   ```

**完了確認**
- [ ] 正常系: 作成 → 一覧に新規行
- [ ] バリデーション: 空 Name でエラーメッセージ表示
- [ ] テナント越境: API のボディに別テナントの値を仕込んでも、`tenant_id` は `req.tenantId` 固定なので越境できない（`WITH CHECK` も二重の防御）

**詰まったら**
- `req.tenantId` が undefined → リクエストが `/t/:slug/...` パターン外、または middleware の登録順序が後ろになっている
- `WITH CHECK` 違反で 500 → 期待動作。エラーハンドリングは Day3-4 でまとめて

**AI 依頼テンプレ**: なし（自分で書く範囲）

---

## Day3-4. Category 編集ページ `/t/{slug}/categories/{id}/edit` [AI 委譲] [FE] [BE]

**目的**
お手本 `Create.tsx` を複製して編集用に変形する作業を AI に投げる。複製パターンを確立しておけば、Knowledge / FieldDefinition も同じ依頼で増やせる。

**前提確認**
- [ ] Day3-3 完了、`Create.tsx` + 作成エンドポイントがローカルで動く

**AI 依頼テンプレ**
```
apps/web/src/pages/categories/Create.tsx と apps/api/src/routes/categories.ts（POST）をベースに、編集用ページ Edit.tsx と更新エンドポイント（PUT /t/:slug/categories/:id）を書いてほしい。

仕様:
- フロントのルート: /t/:slug/categories/:id/edit
- マウント時に GET /t/:slug/categories/:id で既存レコードを取得しフォームを埋める
- 見つからなければ 404 表示（API は RLS で見えないと 0 行 → 404 を返す）
- フォームの構成は Create.tsx と同じ（name / description / displayOrder）
- 保存ボタンで PUT → 一覧へリダイレクト
- 楽観ロック（version 列があれば WHERE version = $n で UPDATE し、0 行なら 409 を返す）

エラーハンドリングも入れて:
- DB エラー（RLS の WITH CHECK 違反含む）→ "Save failed: ..." と画面上にメッセージ
- 409（並行編集の競合）→ "Conflicted with concurrent edit, please reload" メッセージ + リロードボタン

Create.tsx / POST 側にも同様のエラーハンドリングを反映してほしい。
すべて withTenant のトランザクション内で、SQL はパラメータ化すること。
```

**自分の確認ポイント**
- [ ] 編集 → 保存 → 一覧に反映
- [ ] 別ブラウザで開いて片方を保存後、もう片方が conflict メッセージを出す（version 列が無ければスキップ可）
- [ ] 別テナントの URL の id を踏むと 404（RLS で見えないので取得が 0 行）

---

## Day3-5. Excel 取込スクリプト [AI 一次実装 → 自分レビュー] [BE] [ML]

**目的**
採用面接で見せるデモテナントを 1 コマンドで作れるようにする。既存 Streamlit 版の `data.xlsx` を流用する。

**前提確認**
- [ ] Day3-4 完了
- [ ] 既存 Streamlit 版の `data.xlsx` の場所と中身を把握（[`design/10_existing_streamlit.md`](../10_existing_streamlit.md)）

**自分が先に決めること**
- [ ] デモテナント名と slug（例: `acme` / `demo` など、採用面接で説明しやすいもの）
- [ ] デモユーザー（自分自身の OIDC ユーザー）の admin 権限を付ける

**AI 依頼テンプレ**
```
Node + TypeScript の seed スクリプト `scripts/seed.ts` を新規に作ってほしい（npm run seed で実行）。

要件:
- package.json に "seed": "tsx scripts/seed.ts" を追加
- 引数: --file <xlsx path> --tenant-slug <slug> --tenant-name <name> --admin-oidc-sub <sub>
- exceljs で Excel を読む（依存追加）
- シート構成は data.xlsx 既存仕様に従う（categories / knowledge_entries の 2 シート想定。実物を見て確認してから決めて）
- 動作:
  1. owner 接続（DATABASE_URL_OWNER の pg プール）で BEGIN
  2. users に admin ユーザーを UPSERT（oidc_sub で）して内部 user_id を得る
  3. tenants に INSERT（slug 一意制約に注意、既存なら ID 取得して続行）
  4. user_tenants に admin 行を INSERT（role='admin'、user_id は内部 uuid）
  5. categories を XLSX から一括 INSERT
  6. knowledge_entries を XLSX から一括 INSERT（メタは Postgres へ）
  7. 各 knowledge_entry について embedding サービス（http://localhost:9000/embed, mode=passage）を呼び、
     本文 + ベクトルを Elasticsearch のインデックスに投入（bulk API）
  8. COMMIT
- embedding 呼び出しは並列度 4 でバッチ化（fetch で）
- ログは進捗を 100 件ごとに出力
- --dry-run で実 INSERT/インデックス投入せず件数だけ出力するモードも追加

注意:
- owner 接続なので RLS は無関係だが、tenant_id を全レコードに明示的に埋めること
- Elasticsearch ドキュメントにも tenant_id を持たせ、検索時にフィルタできるようにする
- 接続情報は環境変数（DATABASE_URL_OWNER / ELASTICSEARCH_URL）から読む
- API キーや秘匿情報を含む xlsx の取り扱いは想定外で良い
```

**自分の確認ポイント**
- [ ] `--dry-run` で件数が合う
- [ ] 本実行後、`/t/acme/categories` に Excel のカテゴリが見える
- [ ] Elasticsearch のインデックスに knowledge_entries のドキュメントが入っている（ベクトル含む）
- [ ] embedding 呼び出しが `mode=passage` になっている（**重要**: 検索品質の根幹）

**詰まったら**
- embedding が `query:` プレフィクスになっている → `embedding/app/embedder.py` の修正がまだなら先にそちらを直す（[`reviews/04_current_deliverable_review.md:161-168`](../../reviews/04_current_deliverable_review.md)）
- Elasticsearch の bulk が mapping エラーで弾かれる → ベクトル次元（dense_vector の dims）とインデックスの mapping が一致しているか確認し、インデックスを作り直す
- exceljs が複合主キー的なシートでパースに失敗 → シートの先頭行をヘッダとして固定する仕様で AI に再依頼

---

## Day 3 終了チェックリスト

- [ ] `/t/{slug}/categories` の一覧/作成/編集 3 ページが動く
- [ ] 別テナント URL を踏むと 403、別テナントの id を直接踏むと 404
- [ ] Excel 取込でデモテナントが作成され、一覧画面に出る
- [ ] knowledge_entries が `passage:` プレフィクスの embedding 付きで Elasticsearch にインデックスされている
- [ ] **「Create.tsx を見せて『同じパターンで Knowledge も書いて』で AI が複製できる**」状態になった

## Sprint 1 完走後の状態

Sprint 1 ゴール（`design/README.md:64` の 7 項目）の達成度:
- (1) managed Postgres + OIDC + Secret Manager のプロビジョニング: ✅
- (2) `0002_rls_roles.sql`: ✅
- (3) `0003_rls_policies.sql`: ✅
- (4) JWKS 検証 + テナント解決ミドルウェア: ✅
- (5) リクエスト単位の `SET LOCAL` データ層: ✅
- (6) Category / Knowledge / FieldDefinition の最小 CRUD: **Category は ✅**、Knowledge と FieldDefinition は次セッションで AI に複製依頼するだけ
- (7) Excel 取込: ✅

次は Sprint 2: **分類フロー本体**（[`05_search_classification.md`](../05_search_classification.md)）に着手。
