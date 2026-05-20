# Sprint 3 実装計画（3 日分）

> 想定読者: 駆け出し Web エンジニアの自分。AI（先輩）に一次実装やレビューを頼みながら進める。
> 期間: 2026-05-27 〜 2026-05-29（3 日、目安）
> ゴール: **起票（Destinations / Adapter パターン）が動く土台**を完成させる。
> Done の定義は各日末尾のチェックリスト。

## テーマとゴール

Ticket（タイトル + 本文 + 優先度 + `tenantId` + `knowledgeEntryId`）を、テナント設定の起票先（Redmine / GitHub Issues）へ送信できる状態にする。API キーは **Supabase Vault から復号して使う**（`appsettings` に持たせない）。

完了時の状態:

- `ITicketDestination` 抽象と `RedmineDestination` / `GitHubIssuesDestination` の 2 実装が存在する
- `kind`（`redmine` / `github_issues`）から実装を解決する `DestinationRegistry` が DI 登録済み
- `TestConnectionAsync` で接続テストでき、`SubmitAsync` で実起票できる（リトライ + 認証エラー即失敗）
- 起票時の API キーは SECURITY DEFINER 関数経由で Vault から復号して取得する
- destination の登録/編集 + 接続テストボタンの最小 Blazor UI が動く
- 起票失敗時に `inquiries.draft_fields` が短期保持され、成功時は NULL クリアされる

**この Sprint に含めないこと**（混ぜない）: 起票画面の本結線（フォーム → 起票）は Sprint 4。チャット UI 本体・分類ロジックは Sprint 2 の主題で、ここでは触れない。

> 前提: Sprint 1（認証 + RLS + CRUD 土台）完了。Sprint 2（分類エンジン）は並行/完了どちらでもよい。`destinations` / `inquiries` テーブルは RLS 適用済み（Sprint 1 Day2-1）であること。

## 全体マップ

| 日 | テーマ | 主成果物 |
|---|---|---|
| Day 1 | 抽象を確定する | 詳細: [`sprint3/day1.md`](sprint3/day1.md) — 新規 `backend/Portfolio.Destinations/` クラスライブラリ、`ITicketDestination` / `DestinationConfig` / `Ticket` / `TicketSubmitResult` / `TestConnectionResult`、`DestinationRegistry` + DI、起票本文 Markdown 化（`build_description` 移植） |
| Day 2 | アダプタを実装する | 詳細: [`sprint3/day2.md`](sprint3/day2.md) — `RedmineDestination`（最初の 1 個）、`GitHubIssuesDestination`（同パターン複製）、`TestConnectionAsync`、リトライ（指数バックオフ最大 3 回）+ 認証エラー即失敗、アダプタ単体テスト |
| Day 3 | Vault と UI を結線する | 詳細: [`sprint3/day3.md`](sprint3/day3.md) — Vault secret 保存/復号 SECURITY DEFINER 関数、destination 登録/編集 + 接続テスト最小 Blazor UI、起票失敗時 `draft_fields` 保持・成功時 NULL クリア、フィールドマッピング（JSONB）の優先度変換 |

各 day ファイルは、タスクごとに「**目的 / 自分で書く理由（[自分] のみ）/ 前提確認 / 手順 / 完了確認 / 詰まったら / AI 依頼テンプレ（[AI] のみ）**」の節を持つ作業指示書。明日朝は [`sprint3/day1.md`](sprint3/day1.md) を開いて Day1-1 から着手する。

「自分で書く（説明責任が重い箇所）」と「AI に委譲（仕様だけ握る）」の区分は [`09_task_split.md`](09_task_split.md) を継承する。各タスクに **[自分]** / **[AI]** を明記する。06 章の表でも `ITicketDestination` 実装は「最初の 1 個（Redmine）= 自分」「残り（GitHub Issues）= AI」と固定済み（[`09_task_split.md:79-84`](09_task_split.md)）。

---

## Day 1 — 抽象を確定する

> 「インターフェースと型を自分の手で握る」日。設計書 06 章のシグネチャをそのまま `Portfolio.Destinations` クラスライブラリに落とす。実装はまだしない。本文 Markdown 化（PoC 資産の移植）だけ AI に投げる。

- **Day1-1.** ソリューションに `Portfolio.Destinations` クラスライブラリを追加 [自分]
- **Day1-2.** `ITicketDestination` インターフェース + record 型 4 つを定義 [自分（中核）]
- **Day1-3.** `DestinationRegistry`（kind → 実装解決）+ DI 登録 [自分]
- **Day1-4.** 起票本文 Markdown 化（既存 Streamlit `build_description` の C# 移植）[AI]

---

## Day 2 — アダプタを実装する

> 「最初の 1 個（Redmine）」を自分の手で書き、型を確定させる日。GitHub Issues は同パターンで AI に複製させる。失敗時の挙動（リトライ + 認証エラー即失敗）は 06 章のフロー図に従う。

- **Day2-1.** 共通の起票失敗分類 + リトライ方針を決める [自分]
- **Day2-2.** `RedmineDestination` を実装（既存 `redmine_client.py` から移植）= 最初の 1 個 [自分]
- **Day2-3.** `GitHubIssuesDestination` を実装（同パターン複製）[AI]
- **Day2-4.** アダプタ単体テスト（モック HTTP でリトライ/即失敗を検証）[AI 一次実装 → 自分レビュー]

---

## Day 3 — Vault と UI を結線する

> 「秘匿情報の境界」を自分の手で握る日。Vault 復号の SECURITY DEFINER 関数を自分で書き、登録 UI と起票失敗ハンドリングを AI に複製させる。

- **Day3-1.** Vault secret 保存/復号の SECURITY DEFINER 関数を書く [自分]
- **Day3-2.** `IDestinationSecretStore`（C# から Vault 関数を呼ぶ薄いラッパ）[自分]
- **Day3-3.** destination 登録/編集 + 接続テストボタンの最小 Blazor UI [AI]
- **Day3-4.** 起票実行サービス（`draft_fields` 保持/クリア + フィールドマッピング優先度変換）[自分 が骨子 → AI が肉付け]

---

## 進めるときの 1 サイクル

各タスクで [`09_task_split.md:107`](09_task_split.md) のワークフローに従う:

1. 該当する `design/` ファイルを読む（仕様の正。Sprint 3 は [`06_destinations.md`](06_destinations.md) と [`04_security_multitenant.md`](04_security_multitenant.md)）
2. 仕様を 5〜10 行の箇条書きにする（**この明文化が一番大事**）
3. インターフェース・型・SQL 雛形を自分で書く（[自分] タスクの中身）
4. AI に「この仕様で実装して」と依頼（[AI] タスク）
5. 出来たコードをレビューし、テストも AI に依頼
6. ローカルで動作確認、必要なら再依頼
7. PR にまとめてマージ（1 タスク 1 PR を基本に）

## つまづいたらここを見る

| 症状 | 見るべき場所 |
|---|---|
| インターフェースのシグネチャ | [`06_destinations.md:8-45`](06_destinations.md) |
| フィールドマッピング（優先度変換）の形 | [`06_destinations.md:70-107`](06_destinations.md) |
| 起票失敗時の挙動（リトライ/即失敗/draft_fields） | [`06_destinations.md:146-164`](06_destinations.md) |
| 接続テストの戻り値の意味 | [`06_destinations.md:166-172`](06_destinations.md) |
| Vault 復号が権限エラー | [`04_security_multitenant.md:121-142`](04_security_multitenant.md)（SECURITY DEFINER） |
| `build_description` の元ロジック | [`10_existing_streamlit.md:100-111`](10_existing_streamlit.md) |
| Adapter / 委譲の判断 | [`09_task_split.md:79-84`](09_task_split.md) |

## Sprint 3 のあとに残るタスク

Day 3 まで終わると、起票の「配管」が全部つながる。残るのは:

- **起票画面の本結線**（分類確定 → 動的フォーム入力 → `Ticket` 組立 → `SubmitAsync`）— Sprint 4 の主題
- **fan-out（全 destination 同時起票）** — MVP 非対応（[`06_destinations.md:68`](06_destinations.md)）。語るだけ
- **Jira / Backlog / Notion 等の追加 Adapter** — Phase 2 以降の拡張点（同パターン複製で増やせる状態にはなっている）
- **再試行 UI / destination 切替提案の UX** — Sprint 4 で起票画面と合わせて
