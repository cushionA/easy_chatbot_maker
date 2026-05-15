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
install-tooling: ## Install pre-commit + dotnet local tools
	pre-commit install
	cd backend && dotnet tool restore

.PHONY: lint
lint: lint.backend lint.embedding ## Lint everything

.PHONY: test
test: test.backend test.embedding ## Test everything

.PHONY: format
format: format.backend format.embedding ## Auto-format everything

# ---- backend ----------------------------------------------------------------

.PHONY: build.backend
build.backend: ## Build the .NET solution
	cd backend && dotnet build Portfolio.sln -c Release

.PHONY: test.backend
test.backend: ## Run xUnit tests
	cd backend && dotnet test Portfolio.sln -c Release --nologo

.PHONY: lint.backend
lint.backend: ## dotnet format verify
	cd backend && dotnet format Portfolio.sln --verify-no-changes

.PHONY: format.backend
format.backend: ## dotnet format apply
	cd backend && dotnet format Portfolio.sln

.PHONY: run.backend
run.backend: ## Run Blazor server locally
	cd backend && dotnet run --project Portfolio.Web

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
