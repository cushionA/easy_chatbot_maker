# 08. 機能リスト

## 一言で

開発系 Web の言及を **API 主軸 + クロール脇役**で収集し、技術用語の**ライフサイクル（新出・急上昇・廃れ）を時系列で検知・可視化**する。MVP の核は **F2 ライフサイクル検知**で、それを支える収集・抽出・正規化・エビデンスを最小構成で揃える。

各機能に「使う層（**源泉**＝収集ソース / **ML**＝抽出・embedding・検知 / **データ層**＝Postgres / ES / BigQuery）」を添える。設計の根拠は [01_overview.md](01_overview.md) / [05_search_classification.md](05_search_classification.md) / [06_destinations.md](06_destinations.md) / [07_data_strategy.md](07_data_strategy.md)。

---

## MVP（採用面接で見せる必須セット）

### 認証・テナント基盤（横断インフラ）

- [ ] サインイン（**OIDC** / JWKS 検証）— 層: データ層（Postgres `users`）
- [ ] テナント解決（JWT → `user_tenants` 照合、`/t/{slug}/...`）— 層: データ層
- [ ] **軽量マルチテナント**: 本体コーパスは共有グローバル、テナント単位は `tenant_settings` / `watchlists` / プライベート `sources` のみ RLS — 層: データ層
- [ ] ロール `admin` / `member`（[04_security_multitenant.md](04_security_multitenant.md)）— 層: データ層

### F1: トレンド可視化（用語 × 時系列）

- [ ] 用語の出現を時系列グラフで表示（`mentions` / `share`）— 層: データ層（BigQuery `daily_term_stats`）
- [ ] **総量正規化済み `share`** で「投稿が多い日に全部伸びて見える」を防ぐ — 層: ML / データ層
- [ ] ロケール（global / jp）切替の素地（F5 へ接続）— 層: データ層

> F1 は集計済み `daily_term_stats` を読むだけ。重い計算は BigQuery のスケジュールクエリ側に寄せる。

### F2: ライフサイクル検知（核）

- [ ] **新出（emerging）**: 「昨日までほぼゼロ → 直近に複数ソースで出現」を**クロスソース裏取り**（`distinct_sources >= N_min`）+ 最小サポート（`mentions >= M_min`）で確定 — 層: ML / データ層（BigQuery → `detections`）
- [ ] **急上昇（rising）**: `share` を**総量正規化 + EWMA**で平滑化し **z-score** が `Z_TH` 超 + 低カウント除外 — 層: ML / データ層
- [ ] **廃れ（declining）**: trailing peak からの連続低下 / 回帰トレンドが有意に負 — 層: ML / データ層
- [ ] 検知結果を `detections`（type / score / window / `distinct_sources` / evidence）へ書き出し — 層: データ層（Postgres）
- [ ] **採用メトリクスでの裏付け**: rising の term に `term_metrics`（DL 数 / スター）のソース内変化率を突合し evidence に添える（「言及も DL も伸びている」= 確度最高）— 層: ML / データ層（BigQuery）
- [ ] 人手レビュー（`status`: open → confirmed / dismissed）→ 除外語 / 別名へフィードバック — 層: ML / データ層

> 検知パラメータ `ε / N_min / M_min / Z_TH / halflife / K` は設定で保持し固定データセットで較正（未確定は [11_open_questions.md](11_open_questions.md)）。式は [05_search_classification.md](05_search_classification.md)。

### F3: 技術サマリ自動生成（LLM / RAG）

- [ ] 用語ごとに「直近どう動いているか」を Gemini で要約（BYOK or システムキー）— 層: ML（LLM）
- [ ] 入力は ES のタイトル / スニペット / 日付 + 検知シグナル。**本文全文はプロンプトに入れない** — 層: データ層（ES）
- [ ] 出力を zod で構造化検証（要約 + 根拠リンク + `related_terms`）— 層: ML
- [ ] **末尾に関連トピック**（embedding 近傍 / 共起）を付与 — 層: ML / データ層（ES kNN）
- [ ] `summaries`（term × locale）にキャッシュ、出典 doc 参照を保持 — 層: データ層（Postgres）

### F6: エビデンス・ドリルダウン

- [ ] 用語ページ: 時系列 + **出典記事リンク** + 例文スニペット + 関連語 — 層: データ層（BigQuery + ES）
- [ ] 出典は ES `documents` を `term_slugs` でフィルタし `title` / `url`（リンク）/ `published_at` / `source` を新しい順 — 層: データ層（ES）
- [ ] 例文は `snippet`（用語を含む**短い文脈**・上限文字数の引用）。**本文全文は保存せずリンク** — 層: データ層 / 源泉
- [ ] 関連トピック（embedding 近傍 / 共起）を「関連語」として表示 — 層: ML

### F8: 収集ヘルス

- [ ] ソース別の鮮度（`last_ok_at`）/ 失敗率（`consecutive_failures`）ダッシュボード — 層: 源泉 / データ層（Postgres `sources`）
- [ ] **`parser_broken` 検知**（`discover` 0 件 / `collect` 必須フィールド欠落 = サイト構造変化）→ 即アラート対象 — 層: 源泉
- [ ] 連続失敗閾値でアラート（黙ってデータが腐るのを防ぐ）— 層: 源泉

### F9: 用語辞書・正規化

- [ ] 別名マージ（`k8s` ↔ `Kubernetes`）: `term_aliases.alias` → 正規 `term.slug` に畳む — 層: ML / データ層（Postgres）
- [ ] 除外語（`app` / `data` / `user` 等の一般語、`is_excluded`）を出現から除外 — 層: ML / データ層
- [ ] **曖昧性解消**（`"Go"` = 言語か動詞か）: `is_ambiguous` の別名は周辺共起語 / ソース文脈で技術語か判定、迷えば Gemini に少数文脈分類 — 層: ML
- [ ] 新規 term の登録（辞書に無い候補がクロスソース裏取りを満たしたら `terms` upsert）— 層: ML / データ層
- [ ] 誤検知レビュー → 除外語 / 別名へのフィードバックループ — 層: ML / データ層

### 収集パイプライン（F2 / F6 の素を作る）

- [ ] **Source Adapter**（`discover` / `collect`）でソース差異を抽象化、新ソースは実装 + `sources` 行追加 — 層: 源泉
- [ ] **礼儀正しい取得**（`FetchContext`）: robots 遵守 / レート制御 + 指数バックオフ / 条件付き GET / 連絡先入り UA / 必要時のみ Playwright — 層: 源泉
- [ ] **API 主軸**ソース（GitHub / Hacker News / Qiita / dev.to / Stack Exchange / npm・PyPI DL / GitHub Archive）— 層: 源泉
- [ ] **クロール脇役**ソース（GitHub Trending / 記事本文 / CHANGELOG。公式 API が無い隙間のみ）— 層: 源泉
- [ ] 抽出（本文 → 用語候補: 辞書マッチ + NER / パターン）— 層: ML
- [ ] **dedup**: `content_hash`（完全一致）+ embedding kNN（近重複）— 層: ML / データ層（ES）
- [ ] **派生データのみ保存**（用語頻度・メタ・短いスニペット・embedding・要約）、本文全文は抽出後破棄 — 層: データ層 / 源泉
- [ ] Embedding 推論サービス（Python / FastAPI、`multilingual-e5-base`、`query:` / `passage:` 規約）— 層: ML

### データ基盤（3 層）

- [ ] Postgres: `users` / `tenants` / `user_tenants` / `sources` / `terms` / `term_aliases` / `term_identities` / `detections` / `summaries` / `tenant_settings` / `watchlists` / `watchlist_items` — 層: データ層
- [ ] Elasticsearch: `documents`（title / snippet / `term_slugs[]` / embedding / `content_hash` / `popularity`）— 層: データ層
- [ ] BigQuery: `occurrences`（言及ファクト）/ `term_metrics`（採用メトリクス時系列）/ `daily_term_stats`（スケジュールクエリで日次集計）— 層: データ層
- [ ] BYOK LLM キーは Secret Manager に保管、DB は `secret_ref` のみ — 層: データ層

### セキュリティ・コンプラ（横断）

- [ ] **収集物 = 信頼できない入力**の防御: SSRF（`FetchContext` の宛先 URL 検証）/ プロンプトインジェクション（F3 のデータ・指示分離）/ stored XSS（スニペットのエスケープ）/ ReDoS（抽出正規表現）— 層: BE / 源泉（[04_security_multitenant.md](04_security_multitenant.md)）
- [ ] **API レート制限**（per-tenant / per-user）+ F3 要約の日次上限（LLM・BigQuery の金銭 DoS 防止）— 層: BE
- [ ] **特権操作の監査ログ**（BYOK 変更・ソース登録・検知レビュー）— 層: BE / データ層
- [ ] Secret Manager IAM 最小権限 + `llm_secret_ref` の prefix 検証 — 層: INFRA

### 運用・テスト

- [ ] **RLS テナント越境が無いことの E2E 検証**（testcontainers + `portfolio_app`）— 層: データ層 / TEST
- [ ] **検知ロジック（新出 / 急上昇 / 廃れ）の回帰テスト**（固定データセット）— 層: ML / TEST
- [ ] 主要フロー（サインイン → トレンド閲覧 → ドリルダウン → ウォッチリスト）の Playwright E2E — 層: TEST
- [ ] エラー監視（Sentry 無料枠）/ コールドスタート対策（必要なら cron ウォームアップ）— 層: INFRA

---

## fast-follow（MVP の次、ストーリー強化）

### F5: JP vs Global 比較

- [ ] 同一 `term_slug` の `share` を locale 別（jp = Qiita 等 / global = HN 等）に並べる — 層: データ層（BigQuery）
- [ ] 「日本で先行 / 遅行している技術」「JP 限定で熱い語」を提示 — 層: ML / データ層

> 源泉（Qiita / HN）はどうせ取るので追加コストはほぼゼロ。`locale` は `sources` / `occurrences` / `daily_term_stats` に既に次元として持つ。

### F7: アラート・ダイジェスト配信 + ウォッチリスト

- [ ] ウォッチリスト（テナント単位、RLS）に用語を追加・追跡 — 層: データ層（Postgres `watchlists`）
- [ ] ウォッチ対象の検知（新出 / 急上昇 / 廃れ）をダイジェスト配信 — 層: ML / データ層
- [ ] `alerts` / 配信設定テーブルの追加 — 層: データ層

### ムーブメント検知（次の MCP）

- [ ] **急上昇した用語だけ**を embedding でクラスタリングし「塊（ムーブメント）」を発見 — 層: ML
- [ ] 創発クラスタ / `categories` テーブルの追加（全コーパス分類は不要、急上昇クラスタ限定）— 層: ML / データ層

---

## Phase 2（拡張）

- [ ] **プライベートソース文書の ES テナント分離**（テナント自社ブログ等の取込、共有インデックス + `tenant_id` フィルタ必須）— 層: データ層（ES）/ 源泉
- [ ] **公開 API / 埋め込み用の rate-limited キー**（`tenant_public_keys`）— 層: データ層
- [ ] Embedding の **ONNX 化 + Node 内蔵化**（`onnxruntime-node`、HTTP インターフェースは保持）— 層: ML
- [ ] セルフホスト運用（自前 OIDC の JWKS ローテーション / 自前シークレット管理 / OpenSearch 自前運用）— 層: INFRA

---

## 明示的に却下した機能（やらない）

| 機能 | 却下理由 |
|---|---|
| 固定タクソノミ / カテゴリ分類（旧 F10） | overkill。**関連トピック軽量版**（embedding 近傍 / 共起）で代替 |
| 規約でスクレイピングを禁じる対象の収集（小説投稿サイト・pixiv・大手 SNS 等） | ToS 違反。「需要 × 公式アクセスが無い × 合法」の 3 条件を満たさない |
| 本文全文の保存・再配信 | 著作権・容量・削除要求の三重苦。派生データ + 出典リンクで代替 |
| リアルタイム（秒単位）収集 | 日次〜数時間バッチで十分。コスト過大 |
| 高度なパーソナライズ / 推薦 | トレンド観測の本質から外れる |
| index-per-tenant（ES） | 単一共有インデックス + `tenant_id` フィルタで十分 |

---

## スコープと優先順位まとめ

| フェーズ | 機能 | 狙い |
|---|---|---|
| **MVP** | F1 / **F2** / F3 / F6 / F8 / F9 + 収集パイプライン + 3 層データ基盤 | ライフサイクル検知を出典付きで成立させる最小構成 |
| **fast-follow** | F5 / F7 / ムーブメント検知 | JP/Global の物語・追跡 UX・「次の MCP」 |
| **Phase 2** | プライベートソース ES 分離 / 公開 API キー / ONNX 化 / セルフホスト | テナント拡張・運用の深掘り |

価値は UI でなく**データ収集パイプライン・ML・データ基盤**の堅さに置く（[01_overview.md](01_overview.md)）。
