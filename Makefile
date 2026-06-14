# Portfolio common tasks. Works in Git Bash / WSL / Linux / macOS.
# On Windows install make via Scoop (`scoop install make`) or use Git Bash.

.SHELLFLAGS := -eu -o pipefail -c
SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# ---- repo-wide --------------------------------------------------------------

.PHONY: help
help: ## List available targets
	@awk 'BEGIN{FS=":.*##"; printf "Targets:\n"} /^[a-zA-Z0-9_.-]+:.*##/ {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: install-tooling
install-tooling: ## Install pre-commit (+commit-msg) + npm deps
	pre-commit install -t pre-commit -t commit-msg
	npm install

.PHONY: lint
lint: lint.embedding lint.ts ## Lint everything

.PHONY: test
test: test.embedding ## Test everything

.PHONY: format
format: format.embedding format.ts ## Auto-format everything

# ---- embedding --------------------------------------------------------------

.PHONY: install.embedding
install.embedding: ## pip install editable + dev deps
	cd embedding && pip install -e ".[dev]"

.PHONY: lint.embedding
lint.embedding: ## ruff check + format check + mypy
	cd embedding && ruff check app tests && ruff format --check app tests && mypy app

.PHONY: format.embedding
format.embedding: ## ruff format
	cd embedding && ruff format app tests && ruff check --fix app tests

.PHONY: test.embedding
test.embedding: ## pytest (fake embedder)
	cd embedding && FAKE_EMBEDDER=1 pytest

.PHONY: run.embedding
run.embedding: ## Run uvicorn with reload
	cd embedding && FAKE_EMBEDDER=1 uvicorn app.main:app --reload --port 9000

# ---- typescript -------------------------------------------------------------

.PHONY: install.ts
install.ts: ## npm install (root TS tooling)
	npm install

.PHONY: lint.ts
lint.ts: ## eslint + prettier check (TS / React)
	npm run lint
	npm run format:check

.PHONY: format.ts
format.ts: ## prettier write + eslint --fix
	npm run format
	npm run lint:fix

.PHONY: typecheck.ts
typecheck.ts: ## tsc -b (no-op until apps registered in tsconfig references)
	npm run typecheck

# ---- sql --------------------------------------------------------------------

.PHONY: lint.sql
lint.sql: ## sqlfluff lint migrations (needs: pip install sqlfluff)
	sqlfluff lint infra/db

.PHONY: format.sql
format.sql: ## sqlfluff fix migrations (review the diff; respects .sqlfluff)
	sqlfluff fix infra/db

# ---- compose ----------------------------------------------------------------

.PHONY: up
up: ## docker compose up --build -d
	docker compose up --build -d

.PHONY: down
down: ## docker compose down
	docker compose down

.PHONY: logs
logs: ## docker compose logs -f
	docker compose logs -f

.PHONY: ps
ps: ## docker compose ps
	docker compose ps

# ---- security ---------------------------------------------------------------

.PHONY: scan
scan: ## Run prompt-injection scan on staged changes
	python .claude/scripts/pr-validate.py --staged

.PHONY: secrets
secrets: ## Scan staged diff for secrets (gitleaks)
	gitleaks protect --staged --redact -v
