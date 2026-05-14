# 08. 機能リスト

## MVP（採用面接で見せる必須セット）

### 認証・組織管理

- [ ] サインアップ・サインイン（Supabase Auth）
- [ ] 組織（テナント）作成・編集
- [ ] テナントメンバー招待・ロール管理（admin/member）
- [ ] 組織別ボット URL 払い出し（`/t/{slug}/chat`）

### マスタ管理

- [ ] ナレッジマスタアップロード（Excel または JSON）
- [ ] カテゴリ管理（CRUD）
- [ ] 問題エントリ管理（CRUD、`example_queries` `auto_resolution` `guidance_message` `ticket_priority` 編集）
- [ ] フィールド定義管理（CRUD、`is_multi` フラグ含む）
- [ ] バリデーションルール管理（CRUD）

### 分類フロー

- [ ] カテゴリ選択 UI
- [ ] **コンボボックス**（入力フィルタ可能ドロップダウン）
- [ ] 自然言語入力
- [ ] キーワード完全一致検索
- [ ] **BM25 + Embedding ハイブリッド検索（RRF）**
- [ ] `match_count` 重みによるランキング補正
- [ ] LLM フォールバック（BYOK 時のみ、Gemini API）
- [ ] 新規問題自由入力 → unclassified_queue 登録

### 3段階エスカレーション

- [ ] `auto_resolution` あり → 自動回答完結 + 「解決した？」ボタン
- [ ] `guidance_message` あり → ガイダンス表示 → セルフ解決誘導 → フォームへ
- [ ] 両方なし → 直接フォーム

### 動的フォーム

- [ ] フィールド型対応（text/text_short/choice/radio/multi/date/time/datetime/number/bool/file）
- [ ] **複数項目フラグ（is_multi）** で行追加可能
- [ ] バリデーション（必須・文字数・正規表現・ファイル拡張子・サイズ）
- [ ] 確認画面

### 起票

- [ ] **ITicketDestination インターフェース**（Adapter パターン）
- [ ] **Redmine Adapter**
- [ ] **GitHub Issues Adapter**
- [ ] destination 登録・編集（接続テスト機能付き）
- [ ] **プライマリ＋切替**（fan-out なし）
- [ ] フィールドマッピング（JSONB）
- [ ] **API キー Supabase Vault 保管**
- [ ] 起票本文 Markdown 化（既存 Streamlit 版 `build_description` 移植）
- [ ] 起票失敗時の `draft_fields` 短期保持・リトライ

### 引用元表示

- [ ] 回答画面に matched `knowledge_entries` の情報表示
- [ ] admin 向けにマスタ管理画面への遷移リンク

### 未分類キュー

- [ ] 「どれでもない」「新規問題として」の自由入力受付
- [ ] admin 向けレビュー画面
- [ ] マスタ追加 or 破棄
- [ ] レビュー時のコメント

### ナレッジギャップ検出

- [ ] `inquiries.confidence_score` 集計
- [ ] 低確信度回答のリスト表示
- [ ] マスタ改善候補の可視化

### 暗黙フィードバック収集

- [ ] `inquiries.status` / `match_strategy` で挙動を記録
- [ ] 自動回答時の「解決した？」ボタンで `inquiries.resolved` 保存

### 埋め込みウィジェット

- [ ] `tenant_public_keys` テーブル（公開鍵管理）
- [ ] `embed.js` 配信エンドポイント
- [ ] 利用者サイトに `<script>` タグで埋込
- [ ] CORS / Origin チェック
- [ ] レートリミット
- [ ] 匿名アクセス用の限定 RLS ポリシー
- [ ] スタイリング（shadow DOM で利用者サイトと隔離）

### 利用ログ・分析

- [ ] 問い合わせ件数（日次・週次・月次）
- [ ] match_strategy の分布
- [ ] 上位 N 問題（match_count 順）
- [ ] 未分類キュー件数推移
- [ ] 低確信度回答の比率

### 運用

- [ ] RLS ポリシー E2E テスト（テナント間漏洩がないことの保証）
- [ ] エラー監視（Sentry 無料枠）
- [ ] Keep-alive ping（プランB時、Supabase 自動停止防止）

## Phase 2（拡張・追加でストーリー強化）

### 検索強化

- [ ] **クロスエンコーダ Re-ranker**（bge-reranker 等で Top-K 再ランク）
- [ ] **LLM Query Rewriting / HyDE**（BYOK 時、検索精度向上）
- [ ] マルチターン対話の文脈保持（直近 N 発言の合成）

### 非構造文書対応

- [ ] **`document_chunks` テーブル**追加
- [ ] PDF / Word / Markdown ファイルアップロード
- [ ] テキスト抽出 + chunk 分割
- [ ] chunk-based RAG（structured Q&A と統合検索）
- [ ] LLM による自動 Q&A ペア抽出（BYOK）

### マスタ取り込み拡張

- [ ] **Git リポジトリ同期**（GitOps for knowledge base）
- [ ] webhook での即時更新
- [ ] 差分 embedding（変更分のみ再計算）

### Embedding クライアント化

- [ ] **Transformers.js でブラウザ embedding**
- [ ] 量子化モデル配信、Service Worker キャッシュ
- [ ] サーバ FastAPI 推論サービスのリタイア（HTTP インターフェースは保持）

### プライバシー強化

- [ ] **PII 自動マスキング**（メール・電話番号等）
- [ ] チャットログ保存期間設定
- [ ] テナント単位のデータエクスポート・削除（GDPR）

### モデレーション・運用

- [ ] 管理画面で過去会話履歴の閲覧・検索
- [ ] チャットログのエクスポート（CSV）
- [ ] テナント単位のレート制限

## Phase 3（あれば訴求倍増だが MVP では不要）

### マネージドサービスインテグレーション

- [ ] **Slack 連携**：チャットボットを Slack で利用可能に
- [ ] **Teams 連携**
- [ ] **Discord 連携**

### 高度な機能

- [ ] A/B プロンプトテスト
- [ ] ペルソナカスタマイズ（テナントごとのボット口調）
- [ ] 多言語対応（英語・中国語等）
- [ ] 音声入力・出力
- [ ] OGP 対応の回答シェア機能

### 起票先拡張

- [ ] Jira Adapter
- [ ] Backlog Adapter
- [ ] Notion DB Adapter
- [ ] Asana / Linear Adapter

### モデル独自化

- [ ] **日本語特化モデル FT**（独自データで multilingual-e5 を fine-tune）
- [ ] ONNX 化 + C# 内蔵化

## 明示的に却下した機能（やらない）

| 機能 | 却下理由 |
|---|---|
| KNN over 過去問い合わせ | Embedding と効果重複、`match_count` 重み で代替 |
| 👍/👎 明示フィードバック | 回答が事前定義で生成型でない、暗黙シグナルで代替 |
| 別テーブル `tenant_synonyms` | `example_queries` 列に統合 |
| Schema-per-tenant | 無料枠で多 schema 不可、RLS で十分 |
| fan-out 起票 | 部分失敗ハンドリング重い、Phase 2 で検討 |
| LLM 必須依存 | コスト爆発、BYOK で利用者負担 |
| マスタをクライアントローカルストレージに置く | マルチテナント SaaS の本質に反する |

## MVP 機能数まとめ

- **必須セット**: 約70項目（チェックリスト）
- **完成目安**: Phase 1（共通基盤）省略前提で、3〜4ヶ月（座布団さん主導 + AI 補助）
