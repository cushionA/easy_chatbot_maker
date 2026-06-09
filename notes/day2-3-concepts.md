# Day2-3 で学んだ概念メモ

## JWT（JSON Web Token）
ログイン成功時に Supabase が発行する「証明書」。3パーツをドットでつないだ文字列（`xxxxx.yyyyy.zzzzz`）。
中間部分に誰が・いつまで有効かなどの情報が JSON で入っている。改ざんすると署名検証で弾かれる。

## JWT クレーム
JWT の中身の各フィールド。`sub`（subject）= ユーザーID が代表的。

```json
{ "sub": "a1b2c3-...", "exp": 1717000000, "email": "foo@bar.com" }
```

`sub` の値が Supabase の user_id（UUID）と一致する。

## Bearer 認証の流れ

```
リクエスト到着
  ↓
app.UseAuthentication() が走る
  → Authorization: Bearer <token> ヘッダからトークンを抜く
  → AddJwtBearer の設定で Supabase JWKS を使って署名検証
  → ctx.User（ClaimsPrincipal）にクレームをセット
  ↓
TenantResolutionMiddleware が走る（この時点で ctx.User が使える）
```

認証方式（JWT/Cookie/APIキー等）が変わっても、ミドルウェア側は `ctx.User.FindFirst("sub")` と書くだけでよい。
`UseAuthentication()` が方式の違いを吸収してくれる。

## ctx.User.FindFirst("sub")
JWT クレームの中から指定キーの値を1件取り出す。見つからなければ null。

```csharp
ctx.User.FindFirst("sub")?.Value  // → "a1b2c3-..."
```

## slug と `/t/{slug}/chat`
slug = URL に使う人間が読める短い識別子。UUID を URL に露出させないための代替。
`/t/acme/chat` → `acme` が slug、DB の `tenants.slug` 列と照合して `tenant_id` に変換する。

## テナント解決の仕組み（Day2-3 でやったこと）

```
リクエストごとに毎回:
  ① URL から slug を取り出す（/t/acme/... → "acme"）
  ② ctx.User.FindFirst("sub") で user_id を取得
  ③ DB で slug → tenant_id を解決（tenants テーブル）
  ④ user_tenants テーブルで「この user_id はこの tenant_id のメンバーか」確認
  ⑤ OKなら ctx.Items["TenantId"] に格納して次のミドルウェアへ
```

毎リクエスト確認する理由: ログイン後にテナントから除名されても即座に弾けるようにするため。

## SET LOCAL（Day2-4 でやること）

```sql
SET LOCAL app.tenant_id = 'a1b2c3-...';
```

EF Core の `DbConnectionInterceptor` が毎クエリ前に発行する。
Postgres の RLS ポリシーが `current_setting('app.tenant_id')` を参照して他テナントの行を弾く。

## ステータスコードの使い分け
- **401 Unauthorized** = 未認証（ログインしていない）
- **403 Forbidden** = 認証済みだがアクセス権がない（テナント未所属など）

## 注意点（OwnerDbContext 問題）
`TenantResolutionMiddleware` は `SET LOCAL` 発行前に走るため、`AppDbContext`（`portfolio_app` ロール）で
`user_tenants` を引くと RLS が空集合を返す可能性がある。
本来は `OwnerDbContext`（`portfolio_owner` ロール）を DI 登録してここで使うべき。→ Day2-3 の TODO
