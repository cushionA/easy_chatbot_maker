# 06. 起票先（Destinations）

## 設計思想

組織ごとに使う起票先が異なる（Redmine 派、Jira 派、GitHub Issues 派など）。
**Adapter パターン**で抽象化し、新しい起票先を追加できる設計にする。

## ITicketDestination インターフェース

```csharp
public interface ITicketDestination
{
    string Kind { get; }   // "redmine" / "github_issues" 等

    Task<TestConnectionResult> TestConnectionAsync(
        DestinationConfig config,
        CancellationToken ct);

    Task<TicketSubmitResult> SubmitAsync(
        Ticket ticket,
        DestinationConfig config,
        CancellationToken ct);
}

public record DestinationConfig(
    JsonElement PublicConfig,    // URL, project_id 等
    string SecretValue,          // Vault から復号した API キー
    JsonElement FieldMapping     // ticket_priority 等の変換
);

public record Ticket(
    string Title,
    string BodyMarkdown,
    string TicketPriority,        // low/normal/high/urgent
    Guid TenantId,
    Guid KnowledgeEntryId
);

public record TicketSubmitResult(
    bool Success,
    string? ExternalId,
    string? ExternalUrl,
    string? ErrorMessage
);
```

## MVP 対応する起票先

| 起票先 | 理由 |
|---|---|
| **Redmine** | 既存 Streamlit 版で実装済、コード資産がある |
| **GitHub Issues** | 公開 API、無料、採用面接でデモしやすい（誰でも触れる） |

将来追加候補（Phase 2 以降、語るだけ）：

- Jira
- Backlog
- Notion DB
- Asana
- Linear
- Slack（通知用、起票ではない）

## 複数登録時の挙動：プライマリ＋切替

- テナントに複数 destination 登録可能
- 1つだけ `is_primary = true`（DB の UNIQUE INDEX で保証）
- 起票画面でデフォルトはプライマリ、ドロップダウンで他に切替可能
- **fan-out（全 destination に同時起票）は MVP では対応しない**：部分失敗ハンドリングが重い

## フィールドマッピング

`destinations.field_mapping` (jsonb) でテナント固有の変換を保持。

### Redmine の例

```json
{
  "ticket_priority": {
    "field": "priority_id",
    "values": {
      "low":    3,
      "normal": 4,
      "high":   5,
      "urgent": 6
    }
  },
  "default_tracker_id": 1,
  "default_assigned_to_id": 12
}
```

### GitHub Issues の例

```json
{
  "ticket_priority": {
    "field": "labels",
    "values": {
      "low":    ["priority:low"],
      "normal": ["priority:normal"],
      "high":   ["priority:high"],
      "urgent": ["priority:urgent", "needs-attention"]
    }
  },
  "default_labels": ["from-chatbot"]
}
```

## 起票本文の組立

- **タイトル**：`knowledge_entries.name`（問題名）+ 必要なら短い要約
- **本文（Markdown）**：動的フォームで収集した値を Markdown 化
- **既存 Streamlit 版 `build_description` の C# 移植**で実装

本文フォーマット例：

```markdown
## 問い合わせ情報

**発生日時:** 2026/05/15 14:30
**発生場所:** 本社2F会議室A
**詳細:** メールクライアントを起動するとエラーが出る

---
*このチケットは社内チャットボットから自動起票されました*
*問題ID: a3f...（knowledge_entry id）*
*問い合わせID: b4e...（inquiry id）*
```

これにより、外部チケットから内部 ID への遡及が可能。

## 戦略1：本文は外部システムに置きっぱなし

[07_data_strategy.md](07_data_strategy.md) と連動する。

- 起票本文は Redmine / GitHub 側が真の保管先
- うちの `inquiries` テーブルは「**チケットID + URL + 分類結果 + Embedding**」のみ
- 容量 1 レコード数百バイト

この設計により：

- 容量問題が桁違いに減る
- GDPR 等の「データ削除要求」は外部システムに転送するだけ
- 「我々はルーター、ソース・オブ・トゥルースは外部」と語れる

## 起票失敗時の挙動

```
起票 API 呼出
   │
   ├─ 成功 → inquiries.status = 'created' + 外部ID/URL を保存
   │
   └─ 失敗
       │
       ├─ ネットワークエラー / 一時的 → リトライ（指数バックオフ、最大3回）
       │
       └─ 認証エラー / 不正リクエスト → 即失敗
           │
           ├─ inquiries.status = 'failed'
           ├─ inquiries.draft_fields = フォーム入力値（短期保持）
           └─ ユーザーに再試行 or destination 切替提案
```

`draft_fields` は失敗時のみ保持、起票成功時は NULL クリア（プライバシー観点）。

## 接続テスト機能

destination 登録/編集時：

- 「接続テスト」ボタン → `TestConnectionAsync` 呼出
- 結果を画面表示（成功 / API キー無効 / URL 到達不可 / 権限不足）
- 失敗時は登録させない（不正設定の混入を防ぐ）

## API キーの保管

- `destinations.secret_vault_id` で Supabase Vault レコードを参照
- Vault は pgsodium で暗号化保管
- 復号は admin role のみ
- 詳細：[04_security_multitenant.md](04_security_multitenant.md)

## Adapter 実装ファイル構成（C#）

```
src/Chatbot.Destinations/
├── ITicketDestination.cs
├── Models/
│   ├── DestinationConfig.cs
│   ├── Ticket.cs
│   └── TicketSubmitResult.cs
├── Adapters/
│   ├── RedmineDestination.cs
│   └── GitHubIssuesDestination.cs
└── DestinationRegistry.cs    -- kind 文字列 → 実装の解決
```

`DestinationRegistry` で DI 登録、起票時にテナント設定の `kind` から実装を解決。

## 面接で語る点

> 「組織ごとに使う起票システム（Redmine, GitHub Issues, Jira 等）が異なるため、ITicketDestination インターフェースと Adapter パターンで抽象化した。フィールドマッピング（優先度の変換等）は JSONB で柔軟に持ち、テナント側で設定可能にした。MVP は Redmine と GitHub Issues の2実装、他は追加可能な拡張点として残した」

> 「API キー等の秘匿情報は Supabase Vault で暗号化保管、テナント間は Row Level Security で隔離。起票本文は外部チケットシステム側が真の保管先で、当システムはメタデータのみを保持する設計（データ複製を避ける）」
