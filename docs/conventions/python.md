# Python 規約

対象: `services/embedding`（FastAPI 推論サービス）と ML 推論コード — スタック内で**唯一の非 TypeScript**（[`design/02`](../../design/02_architecture.md)）。共通原則は [README.md](README.md)。

> AI 向けの in-tree 作業ルールは [`embedding/CLAUDE.md`](../../embedding/CLAUDE.md) が持つ。本書はそれと**同じ方針を人間のレビュー基準として**まとめ直したもの。両者が食い違ったらまず CLAUDE.md と本書を一致させる（重複定義を放置しない）。

## 前提

- **Python 3.11 固定**（`.python-version`）。3.10 へのフォールバック構文を書かない。
- 整形・lint は **ruff**（`ruff format` + `ruff check`）、型は **mypy --strict**。設定は [`embedding/pyproject.toml`](../../embedding/pyproject.toml) が正。**整形はレビューで指摘しない**（`make format.embedding` が直す）。
- ruff ルールセット: `E,W,F,I,B,UP,S,SIM,RUF,TID,PT`（bugbear・pyupgrade・bandit(S)・simplify を含む）。`ruff format` はダブルクォート・スペースインデント。

## ファイル / モジュール

- モジュールは小さく単一責務（`app/embedder.py`, `app/models.py`, `app/main.py`）。`from x import *` 禁止。
- ルート（`app/main.py`）は**オーケストレーションのみ**。ロジックは `app/<feature>.py` に出す。
- import は ruff(`I`=isort) が整列。`known-first-party = ["app"]`、`combine-as-imports`。

## 命名

- 関数・変数・モジュール: `snake_case`。クラス: `PascalCase`。定数: `UPPER_SNAKE_CASE`。
- 非公開は先頭 `_`。boolean は `is_`/`has_`。
- 名前は意図を表す（[README.md](README.md)）。1 文字名はループ変数や数式の慣習的なものに限る。

## 型ヒント（最重要）

- **公開関数すべてに型ヒント**。`mypy --strict`（`disallow_untyped_defs` 等）が前提なので、型無し関数はそもそも通らない。
- **PEP 604 ユニオン**（`int | None`）と **PEP 695 ジェネリクス**（`def f[T](x: T) -> T`）を使う。`typing.Optional` / 旧 `TypeVar` は使わない。
- `Any` を避ける。外部入力は **Pydantic v2 モデル**で受けて型を確定（境界での検証、[README.md](README.md)）。
- `# type: ignore` は理由付きで最小限（`warn_unused_ignores=true` なので不要な ignore は CI で落ちる）。

## 定義順（モジュール内）

1. モジュール docstring（WHY が要るときだけ。WHAT の言い換えにしない）
2. `from __future__`（必要時）→ import（標準 → サードパーティ → first-party、ruff が整列）
3. 定数（`UPPER_SNAKE_CASE`）
4. Pydantic モデル / dataclass / 型エイリアス
5. **公開関数・公開クラス**（モジュールの主役を上に）
6. 非公開ヘルパー（`_xxx`、下に）

クラス内: クラス変数 → `__init__` → 公開メソッド → 非公開メソッド。

## FastAPI

- リクエスト/レスポンスは `app/models.py` の **Pydantic v2 `BaseModel`**。境界（長さ・範囲）は `Field(min_length=..., max_length=...)` で**サーバ側検証**（ドキュメントでなく強制）。
- エンドポイントは `response_model=...` を宣言してスキーマを強制。1 エンドポイント 1 責務、ルートはロジックを呼ぶだけ。
- 依存は `Depends(get_xxx)` + モジュールレベルのシングルトンファクトリ（`@lru_cache`）。グローバル可変状態を持たない。
- エラーは `HTTPException(status_code=4xx, detail=...)`。`return {"error": ...}` を 200 で返さない。
- 重い初期化（モデルロード）は**遅延**。`import app.main` がモデルをダウンロードしてはいけない。

## Embedding サービス固有

- `Embedder` は遅延ロード。`FAKE_EMBEDDER=1` で**決定的なダミー単位ベクトル**を返し、CI・単体はこれを使う（実モデルを単体テストでロードしない）。
- ベクトルは常に L2 正規化（`normalize_embeddings=True`）。cosine = 内積に落ちて pgvector と整合。
- **e5 プレフィクス規約**: query には `query:`、文書には `passage:`。`/embed` の `mode` で切替。誤用は recall を静かに劣化させる（[CLAUDE.md](../../embedding/CLAUDE.md) / 横断ルール）。

## エラーハンドリング

- **裸の `except:` 禁止**。例外型を必ず指定（ruff `B` / `E722`）。握れない例外は伝播。
- 握るなら理由をコメントし、ログするか HTTP エラーに変換。「起きえない」分岐の防御コードは書かない。
- 期待される失敗（不正入力・範囲外）は `HTTPException` で表現。バグはスタックを残して 5xx。

## ログ / 観測性

- ライブラリコードに `print()` を書かない。`logging.getLogger(__name__)` を使う。
- ログに**秘密を出さない**（API キー・トークン）。
- 構造化情報はメッセージ文字列に埋めず、ロガーの引数 / extra で渡す。

## セキュリティ境界

- 秘密はコードに書かず**環境変数**から。`.env.example` に実値を置かない。
- 入力に**上限**（`Field(max_length=8000)` 等）。長大入力は推論を遅くし DoS になりうる。
- **CORS は既定で閉じる**。この推論サービスは内部ネットワークの API からのみ呼ぶ。
- アウトバウンド HTTP は `httpx`（`requests` を使わない）。`os.system` / `subprocess(shell=True)` にユーザー入力を渡さない（ruff `S` が検出）。

## テスト

- `tests/` に配置。`conftest.py` で `FAKE_EMBEDDER=1` を強制。
- `fastapi.testclient.TestClient` を**実 `app` オブジェクト**に当てる（別の "test app" を作らない）。
- assert は**ステータス → JSON の形 → 値**の順。
- 非決定（ベクトルの絶対値）は assert しない。次元・正規化・分岐・スキーマ妥当性を見る。
- `pytest --strict-markers --strict-config`。`slow`/`integration` マーカーで実モデル・ネットワークを分離。
- TS 側からは**契約テスト（zod）+ スモーク 1 本**で境界を守る（[`design/13`](../../design/13_testing_strategy.md)）。

## 禁止 / アンチパターン

- `typing.Optional` / 旧 `TypeVar`（PEP 604/695 を使う）、`Any` の常用。
- 裸の `except:`、200 でのエラー返却、`print()`。
- `import app.main` での実モデルロード、単体での実モデル使用。
- `requests`、`shell=True` + ユーザー入力、CORS 全開放。
- グローバル可変状態、巨大ルート関数（ロジックをルートに直書き）。

## レビューチェックリスト

- [ ] 公開関数に型ヒント、`mypy --strict` が緑、`Any`/不要 `type: ignore` が無い
- [ ] PEP 604/695 を使用（`Optional`/旧 `TypeVar` でない）
- [ ] 入力が Pydantic v2 + `Field` 境界で検証され、`response_model` 宣言済み
- [ ] 定義順（定数 → モデル → 公開 → ヘルパー）、ルートはロジックを呼ぶだけ
- [ ] 例外型を指定して握る／期待される失敗は `HTTPException`
- [ ] e5 の `query:`/`passage:` プレフィクスが正しい、ベクトル L2 正規化
- [ ] モデルは遅延ロード、テストは `FAKE_EMBEDDER=1`
- [ ] 秘密は環境変数、入力長上限、CORS 既定で閉、`httpx` 使用
- [ ] `make lint.embedding`（ruff + mypy）と `make test.embedding` が緑
