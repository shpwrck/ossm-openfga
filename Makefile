.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

# Every target assumes: oc logged in with cluster-admin. Nothing here reads or
# stores cluster addresses — kubeconfig context is yours to manage.

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: operators
operators: ## Install OSSM 3 + Connectivity Link operators (OLM) and wait for ready
	./scripts/install-operators.sh

.PHONY: openfga
openfga: ## Deploy OpenFGA + PostgreSQL, bootstrap store/model/tuples
	./scripts/install-openfga.sh

.PHONY: mesh
mesh: ## Demo app + mesh control plane + east-west authz via OpenFGA
	./scripts/install-mesh.sh

.PHONY: ingress
ingress: ## Gateway + HTTPRoutes + AuthPolicy (ingress authz via OpenFGA)
	./scripts/install-ingress.sh

.PHONY: egress
egress: ## Egress gateway + authz for outbound traffic via OpenFGA
	./scripts/install-egress.sh

.PHONY: perf
perf: ## (Stretch) NetworkPolicy-vs-OpenFGA comparison harness
	./scripts/run-perf.sh

.PHONY: demo
demo: operators openfga mesh ingress egress ## Everything, in order

.PHONY: clean
clean: ## Remove demo namespaces and resources (leaves operators installed)
	./scripts/cleanup.sh

.PHONY: model-test
model-test: ## Test the OpenFGA model offline (same check CI runs)
	@FGA=bin/fga; [ -x $$FGA ] || FGA=fga; $$FGA model test --tests model/store.fga.yaml

.PHONY: docs-serve
docs-serve: ## Serve the walkthrough locally on :8000
	@python3 -m venv .venv 2>/dev/null || true; \
	. .venv/bin/activate && pip install -q 'mkdocs-material==9.*' 'mkdocs<2' && mkdocs serve

.PHONY: docs-build
docs-build: ## Strict-build the walkthrough (same check CI runs)
	@python3 -m venv .venv 2>/dev/null || true; \
	. .venv/bin/activate && pip install -q 'mkdocs-material==9.*' 'mkdocs<2' && mkdocs build --strict
