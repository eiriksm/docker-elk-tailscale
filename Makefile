# Thin wrappers. Everything here is a plain docker compose invocation you can
# also type by hand; the Makefile exists so nobody has to remember the flags.

COMPOSE      := docker compose
# The tailnet proxies need an auth key and are irrelevant to testing, so the
# test targets run with that profile switched off.
CORE_COMPOSE := COMPOSE_PROFILES= $(COMPOSE)
TOOLBOX      := $(CORE_COMPOSE) run --rm toolbox

.PHONY: help up up-core down clean logs ps seed verify test export import publish fetch migration-test

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

up: ## Start the full stack, including the tailnet proxies
	$(COMPOSE) up -d --wait --wait-timeout 600

up-core: ## Start Elasticsearch, Logstash and Kibana only (no tailnet)
	$(CORE_COMPOSE) up -d --wait --wait-timeout 600

down: ## Stop everything, keeping the data volume
	$(COMPOSE) down --remove-orphans

clean: ## Stop everything and delete the data volume
	$(COMPOSE) down --remove-orphans --volumes

logs: ## Follow logs
	$(COMPOSE) logs -f

ps: ## Show container status
	$(COMPOSE) ps

seed: ## Write the deterministic test dataset into a running stack
	$(TOOLBOX) /scripts/seed.sh

verify: ## Assert the running stack still holds exactly that dataset
	$(TOOLBOX) /scripts/verify.sh

test: up-core seed verify ## Start a clean stack, seed it, and verify it

export: ## Stop the stack and archive its data directory to dataset/
	./scripts/export-dataset.sh

import: ## Replace the data volume with dataset/esdata.tar.gz (destructive)
	./scripts/import-dataset.sh

publish: ## Push dataset/ to GHCR, tagged with the stack version and latest
	./scripts/publish-dataset.sh

fetch: ## Pull the latest published dataset into dataset/
	./scripts/fetch-dataset.sh

migration-test: fetch import up-core ## Boot the configured version on the last published dataset
	$(TOOLBOX) /scripts/verify.sh --check-writes
