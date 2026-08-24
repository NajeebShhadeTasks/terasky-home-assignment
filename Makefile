.PHONY: help test lint fmt build kustomize-build validate policy-test tf-fmt tf-validate verify all

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'

test: ## Run application unit tests
	cd app && ./.venv/bin/python -m pytest -q 2>/dev/null || (cd app && python3 -m pytest -q)

lint: ## Ruff lint + format check
	cd app && ./.venv/bin/ruff format --check . && ./.venv/bin/ruff check .

fmt: ## Auto-format Python + Terraform
	cd app && ./.venv/bin/ruff format .
	terraform -chdir=infra/terraform fmt -recursive

build: ## Build the container image locally
	docker build -t terasky-backend:local app/

kustomize-build: ## Render all three overlays
	kubectl kustomize apps/backend/overlays/dev >/dev/null && echo dev OK
	kubectl kustomize apps/backend/overlays/staging >/dev/null && echo staging OK
	kubectl kustomize apps/backend/overlays/production >/dev/null && echo production OK

validate: kustomize-build ## Schema-validate rendered manifests (kubeconform)
	for d in apps/backend/overlays/dev apps/backend/overlays/staging apps/backend/overlays/production infrastructure/controllers infrastructure/configs clusters/demo; do \
	  echo "== $$d"; kubectl kustomize $$d | kubeconform -strict -summary \
	    -schema-location default \
	    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' || exit 1; \
	done

policy-test: ## Kyverno policy unit tests
	kyverno test policies/tests

tf-fmt: ## Terraform format check
	terraform -chdir=infra/terraform fmt -check -recursive

tf-validate: ## Terraform validate
	terraform -chdir=infra/terraform validate

verify: ## Full runtime verification against the live cluster
	./scripts/verify.sh

all: lint test kustomize-build validate policy-test tf-fmt tf-validate ## Everything local
