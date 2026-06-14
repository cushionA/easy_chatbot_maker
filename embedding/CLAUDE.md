# embedding/ — Coding rules for FastAPI + sentence-transformers

Scope: applies under `embedding/`. Global rules in `~/.claude/CLAUDE.md` still apply.

## Setup / common commands
```bash
python -m venv .venv
. .venv/bin/activate              # Linux / macOS / Claude Code on the Web
. .venv/Scripts/activate          # Windows / Git Bash
pip install -e ".[dev]"

ruff check app tests              # lint
ruff format app tests             # format
mypy app                          # type check (strict)
FAKE_EMBEDDER=1 pytest            # fast tests, no model download
uvicorn app.main:app --reload --port 9000
```

## Python conventions
- **Target Python 3.11** (pinned in `.python-version`). No 3.10 syntax fallbacks.
- Use **PEP 695 generics** (`def f[T](x: T) -> T`) and **PEP 604 unions** (`int | None`) over `typing.Optional` / `TypeVar`.
- Type hints on every public function. `mypy --strict` rules apply.
- No `print()` in library code; use `logging.getLogger(__name__)`.
- Keep modules small and single-purpose. Avoid `from X import *`.

## FastAPI patterns
- Define request / response models as Pydantic v2 `BaseModel` in `app/models.py`. Use `Field(min_length=..., max_length=...)` for bounds — server-side validation, not just docs.
- Endpoints declare `response_model=...` so the schema is enforced.
- One responsibility per endpoint. Move logic into `app/<feature>.py`; the route file just orchestrates.
- For dependencies, prefer `Depends(get_xxx)` with module-level singleton factories (`@lru_cache`). Avoid global mutable state.
- Error responses: `HTTPException(status_code=4xx, detail=...)`. Never `return {"error": ...}` with 200.

## Embedding service specifics
- `Embedder` is **lazily loaded**. Importing `app.main` must not download a model.
- `FAKE_EMBEDDER=1` returns deterministic random unit vectors of the model's dim — used in CI and unit tests.
- Always L2-normalize vectors (`normalize_embeddings=True`) so cosine similarity reduces to dot product in pgvector.
- Match `intfloat/multilingual-e5-base` input convention: prefix `query: ` for queries, `passage: ` for documents. Misuse silently degrades recall.

## Testing
- Tests in `tests/`. `conftest.py` sets `FAKE_EMBEDDER=1`.
- Use `fastapi.testclient.TestClient` against the real `app` object — no separate "test app" instance.
- Assert HTTP status, then JSON body shape, then values. In that order.

## Security
- No secrets in code; read from environment.
- Reject inputs with `Field(max_length=8000)` style bounds — long inputs slow embedding and can DoS.
- CORS: leave **closed** by default. Only the Node API on the internal network should call this service.

## Forbidden / avoid
- `requests` for outbound (use `httpx`).
- Bare `except:`. Always specify the exception type.
- `os.system` / `subprocess.Popen(shell=True)` with user input.
- Loading the real model in unit tests (always use `FAKE_EMBEDDER=1`).
