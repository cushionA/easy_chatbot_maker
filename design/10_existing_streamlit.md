# 10. 既存 Streamlit 版（helpdesk_bot）からの流用・発展

## 既存版の位置

| 項目 | 内容 |
|---|---|
| パス | `C:\Users\tatuk\Desktop\チャットボット\helpdesk_bot` |
| 役割 | PoC（概念検証） |
| 本格 Web 版での扱い | 「PoC → 本格 Web 版への発展」のストーリー資産 |

## ファイル別マッピング

### `app.py` — Streamlit エントリ

| 機能 | 移行先 |
|---|---|
| Phase 管理（CATEGORY/CLASSIFY/COLLECT/CONFIRM/DONE） | React のページ・コンポーネント階層に再構成 |
| `session_state` | React の state + Node API のコンテキスト |
| サイドバー（ナレッジ再読込・統計） | 管理画面の独立ページに分離 |
| カテゴリバー | 共通ヘッダーコンポーネント |

**設計上の発展**：
- 単一セッションのフロー → マルチユーザー・マルチテナント対応
- session_state 整合性チェック → 認証・テナントスコープで自動担保

### `config.py` — 設定

| 既存 | 新設計 |
|---|---|
| `data.xlsx` の `settings` シートで設定値管理 | 環境変数（.env）で管理 |
| `MOCK_MODE` | テスト用フラグとして継承 |
| `EMBEDDING_MODEL_NAME` 等 | テナント別ではなく**システム全体で1つ**（embedding_model 列で行単位混在は許容） |
| `REDMINE_*` 設定 | `destinations` テーブルでテナント別管理 |

### `knowledge.py` — マスタ管理

| 機能 | 流用度 | 新設計 |
|---|---|---|
| `load_knowledge` / `load_fields` / `load_categories` / `load_validations` | パース部分は流用 | Excel → DB INSERT に変更 |
| `get_categories` / `get_category_maps` | UI 用ヘルパ | TypeScript で同等機能 |
| `filter_by_category` | カテゴリで絞込 | SQL `WHERE category_id = ?` で代替 |
| `get_embedding_model` | SentenceTransformer ロード | FastAPI 推論サーバに移管 |
| `build_embeddings` | embedding 生成 | FastAPI が担当 |
| `load_all_embeddings` / `filter_embeddings` | キャッシュ管理 | Elasticsearch に保存・kNN で検索 |
| `parse_required_info` | カンマ区切りパース | DB は `text[]` 配列で持つ、パース不要 |
| `get_fields_for_issue` | カテゴリ必須＋問題別必須の結合 | **ロジック流用**、`required_field_codes` 配列の結合に変更 |

### `classifier.py` — 分類ロジック

| 機能 | 流用度 | 新設計 |
|---|---|---|
| `build_query` | 直近3発言結合 | **そのまま流用**（TypeScript 移植） |
| `search_by_embedding` | コサイン類似度 Top-K | Elasticsearch の kNN に置換 |
| `classify`（Embedding 主・LLM フォールバック） | ロジックの骨子は流用 | **BM25 + Embedding + match_count + LLM の4段に発展** |
| `get_candidate_with_solution` | 候補に解決方法付与 | `auto_resolution` / `guidance_message` の2列に分離 |
| MOCK_MODE 部分 | テスト用 | テスト時のみ使用 |

**設計上の発展**：

```
[既存]
Embedding 検索 → top1 >= 閾値 ? Embedding 結果 : LLM フォールバック

[新]
キーワード完全一致 → ヒット ? 確定 : ↓
BM25 + Embedding ハイブリッド RRF → match_count 重み → top1 >= 閾値 ? 候補提示 : ↓
LLM フォールバック（BYOK 時のみ） → 該当なし ? 未分類キュー : 候補提示
```

### `forms.py` — 動的フォーム

| 機能 | 流用度 | 新設計 |
|---|---|---|
| `render_field`（型別ウィジェット分岐） | ロジック流用 | React コンポーネント (`<DynamicField>`) に再構成 |
| `pd_isna` | NaN 判定 | TypeScript では null/undefined で代替、不要 |
| `render_form` | フォーム全体描画 | React フォーム（react-hook-form）+ zod |
| `validate_field`（型別バリデーション） | **ロジック流用**（TypeScript 移植） | + `is_multi` フィールド対応追加 |
| `validate_form` | 全フィールドバリデーション | 同上 |
| `format_collected_info` | 表示用フォーマット | 起票本文（Markdown）生成に統合 |

**設計上の発展**：
- `is_multi` フラグで複数値入力対応（行追加 UI）
- バリデーションはサーバ側でも再検証（クライアント信頼しない）

### `llm_client.py` — LLM 呼出

| 機能 | 流用度 | 新設計 |
|---|---|---|
| `build_llm_master_text` | マスタの整形 | **そのまま流用**（TypeScript 移植） |
| `build_system_prompt` | システム指示文の組立 | **プロンプトはそのまま流用** |
| `classify_mock` | MOCK_MODE 用 | テスト用 |
| `classify` | Ollama API 呼出 | **Gemini API 呼出に置換**（HTTP 直接） |
| `classify_with_retry` | リトライラッパ | TypeScript のリトライ（指数バックオフ）で実装 |
| `Pydantic ClassificationResult` | 構造化出力スキーマ | **TypeScript の型 + zod**で同等 |

**設計上の発展**：
- Ollama（ローカル）→ Gemini API（クラウド、BYOK）
- LLM 呼出は **`Shared.LLM` ラッパ**（将来 Groq 等への切替容易）

### `redmine_client.py` — Redmine 起票

| 機能 | 流用度 | 新設計 |
|---|---|---|
| `build_description` | フォーム値の Markdown 化 | **そのまま流用**（TypeScript 移植） |
| Redmine REST API 呼出 | API 呼出パターン | `RedmineDestination` Adapter として再実装 |
| MOCK_MODE 部分 | テスト用 | テスト用 |

**設計上の発展**：
- 単独ファイル → `ITicketDestination` インターフェース実装の1つ
- GitHub Issues Adapter が並列で増える
- API キーは Secret Manager 経由で取得

### `models.py` — データモデル

| 既存 | 新設計 |
|---|---|
| `Candidate` / `ClassificationResult` (Pydantic) | TypeScript の型で同等定義 |

## データファイル

| 既存 | 新設計 |
|---|---|
| `data/data.xlsx`（knowledge/field_types/categories/validations/settings） | テナント別 DB レコードに移行 |
| 採用面接用デモデータ | 既存 `data.xlsx` をデモテナントの初期データに使う |

**デモテナント用に、既存 `data.xlsx` の中身をそのまま流用してインポートする**。リアリティのあるデモデータが既にある = ポートフォリオ的アドバンテージ。

## ロジック資産まとめ

| 既存ロジック | 新設計での扱い |
|---|---|
| **Embedding 検索 + LLM フォールバック戦略** | 戦略の妥当性は検証済み、本格 Web 版で「ハイブリッド検索 + LLM フォールバック」に進化 |
| **構造化出力のスキーマ設計**（Pydantic） | TypeScript の型に 1:1 移植 |
| **動的フォーム + バリデーション設計** | テーブル駆動の設計思想を継承 |
| **カテゴリ別必須情報 + 問題別必須情報の結合** | `required_field_codes` 配列の結合ロジックで継承 |
| **MOCK_MODE** | テストモードとして継承 |
| **チャット履歴連結クエリ** | 直近3発言結合をそのまま流用 |
| **Markdown 化した起票本文** | `build_description` ロジックそのまま |

## 面接の語り筋

> 「最初に Streamlit 版で PoC を作り、**Embedding + LLM フォールバック**という分類戦略の妥当性、**Excel 駆動の動的フォーム生成**の手応え、**カテゴリ別+問題別の必須情報結合**のロジックを検証した。
>
> 本格 Web 版では、PoC で固まった戦略を **TypeScript / Node.js（React + Node API）** に載せ替え、以下を追加した：
>
> - **マルチテナント設計**（RLS + Secret Manager + OIDC/JWT）
> - **ハイブリッド検索**（BM25 を加えて Embedding 単独の弱点を補完）
> - **3段階エスカレーション**（自動回答 / ガイダンス / 直接起票）
> - **複数起票先の抽象化**（Adapter パターン）
> - **埋め込みウィジェット**（テナント自社サイトに埋込可能）
> - **BYOK LLM 設計**（コスト爆発を回避）
>
> Streamlit では本質的に厳しかった **マルチテナント・本物のセッション管理・同時接続** が解決された。」

このストーリーが採用面接での **「実プロダクトを段階的に発展させた経験」** の証明になる。
