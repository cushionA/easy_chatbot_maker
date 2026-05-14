# 07. データ戦略

## 3層のデータ配置

無料運用前提で、データを「どこに置くか」を3層に分けて最適化。

```
[ブラウザ（クライアント）]
  - Embedding モデル本体（Transformers.js, Phase 2）
  - クエリ単位のベクトル化計算（Phase 2）

[サーバ DB（Supabase / 自前 Postgres）]
  - メタデータ + Embedding ベクトル
  - 容量最小（〜数MB / テナント）

[外部システム（Redmine / GitHub Issues）]
  - チケット本文（フォーム入力結果）
  - 添付ファイル
  - 真の保管先（Source of Truth）
```

## 戦略1：本文は外部システムに置きっぱなし（最も重要）

`inquiries` テーブルには本文を持たない：

| 列 | 内容 |
|---|---|
| `external_ticket_id` | "12345" 等 |
| `external_ticket_url` | "https://redmine.example.com/issues/12345" |
| `raw_query` | 自然言語入力（短い） |
| `query_embedding` | ベクトル（分析用、HNSWインデックス無し） |
| `matched_knowledge_id` | 分類結果 |
| `match_strategy` | dropdown / keyword / hybrid / llm |
| `confidence_score` | ナレッジギャップ検出用 |

**1レコード数百バイト**。10万件起票しても数十MB。

### 副次効果

- GDPR 等の「データ削除要求」は外部システムに転送するだけで対応
- 自社で機密本文を保持しない設計はガバナンス的に有利
- 面接で「データ最小化原則」「データ責任分離」と語れる

## 戦略2：Embedding 計算はクライアント（Phase 2）

`intfloat/multilingual-e5-base` を Transformers.js でブラウザ実行：

- 量子化版モデル（〜100MB）をブラウザにダウンロード
- Service Worker で永続キャッシュ → 次回以降は読み込みなし
- クエリは**ブラウザでベクトル化してから**サーバに送信
- サーバの CPU / RAM を使わない

### メリット

- サーバ Embedding 推論サービス（FastAPI）が**Phase 2 で不要**になる
- 「**クエリ内容がベクトル化されてからサーバに到達するため、原文を中継しないモード**」をプライバシー強化版として語れる
- Render Free の 512MB RAM 制約から解放される

### MVP では？

MVP は **サーバ側 Embedding**（FastAPI）で始める：

- ブラウザ Embedding は実装コストがある
- 初回 100MB のダウンロード UX を解決する必要
- iPhone Safari の挙動検証が必要

Phase 2 で「サーバ→クライアント」の移行を行う。インターフェース（HTTP）は変えない。

## 戦略3：マスタは Web UI アップロード（MVP は A 案）

ナレッジマスタの取り込みは Web UI から：

- 管理者が Excel / JSON をアップロード
- サーバでパース → DB 保存 → 元ファイルは即削除
- DB にはテキスト + Embedding のみ残る

### Git 連携は Phase 2 で

技術リテラシーの高い組織向けに Git からの同期も将来サポート可能：

```csharp
public interface IKnowledgeSource
{
    Task<List<KnowledgeEntry>> FetchAsync(SourceConfig config);
}

public class WebUploadSource : IKnowledgeSource { ... }     // MVP
public class GitRepositorySource : IKnowledgeSource { ... } // Phase 2
```

**MVP では実装しないが、インターフェースで拡張可能性を示す**。

## クライアントローカルストレージは使わない

「マスタを利用者ブラウザに置く」は破綻する理由：

- マルチテナント SaaS は **同組織内の複数ユーザーがデータ共有**するのが本質
- ユーザー1がアップロード → ユーザー2はマスタにアクセスできない（同期不可）
- IndexedDB 容量は信頼性低い、ブラウザキャッシュクリアで消える
- ブラウザツールに退化する

## 容量見積もり

### 1テナントあたり

| 種類 | 1件 | 件数 | 小計 |
|---|---|---|---|
| `knowledge_entries`（テキスト） | 〜1KB | 100問題 | 100KB |
| `knowledge_entries.embedding`（vec(768)） | 1.5KB | 100問題 | 150KB |
| `inquiries`（メタ、本文無し） | 〜1KB | 1万件 | 10MB |
| `inquiries.query_embedding` | 1.5KB | 1万件 | 15MB |
| `unclassified_queue` | 〜2KB | 1000件 | 2MB |
| **合計** | | | **〜27MB** |

### Supabase Free（500MB）でのキャパ

500MB ÷ 27MB ≒ **15〜20 テナント**収容可能。

ポートフォリオ規模（1〜3テナント）では全く問題なし。

スケール時の有料化ポイント：
- 20テナント超え → Supabase Pro（$25/月、8GB DB）
- それでも100テナント超え → 自前 Postgres（Oracle Cloud VM内）

## マスタアップロード後の処理フロー

```
[管理者ブラウザ]
  Excel/JSON アップロード（multipart/form-data）
   ↓
[Blazor Server]
  - ファイル受信、一時ストレージに保存
  - パース（Excel: ClosedXML 等 / JSON: System.Text.Json）
  - スキーマ検証（必須カラム等）
   ↓
[Embedding 推論サービス (FastAPI)]
  - 各 knowledge_entry の (name + keywords + example_queries) を embedding 化
  - C# にベクトル返却
   ↓
[Postgres]
  - tenant_id 付与で INSERT
  - tsvector 自動生成（GENERATED ALWAYS AS）
  - HNSW インデックス更新
   ↓
[Blazor Server]
  - 一時ファイル削除
  - 完了通知
```

## バックアップ・障害対策

| 対象 | 方針 |
|---|---|
| ナレッジマスタ | テナントの手元（アップロード元ファイル）が原本 |
| 起票本文 | 外部システム側が原本（戦略1） |
| メタデータ・Embedding | 失っても再生成可能（マスタ再アップロード→再embedding） |

**全データ消失しても、テナントが元の Excel/JSON を再アップロードすれば復元可能**な設計。

これは面接で語れる：

> 「無料運用前提のためバックアップに高コストをかけない代わりに、**真のデータは全て外部に残る**設計にした。当システムが全データ消失しても、利用者がマスタを再アップロードし起票履歴は外部から復元可能」

## サマリ：データはどこにある？

| データ | 場所 | 理由 |
|---|---|---|
| マスタ（ナレッジ） | 当システム DB | 検索インデックスのため |
| Embedding ベクトル | 当システム DB | 検索のため |
| 起票本文 | 外部システム（Redmine/GitHub） | 真の保管先 |
| Embedding モデル | サーバ（MVP）→ クライアント（Phase 2） | コスト最適化 |
| API キー等秘匿 | Supabase Vault | 暗号化必須 |
| マスタ元ファイル | アップロード後即削除 | 必要なし |
