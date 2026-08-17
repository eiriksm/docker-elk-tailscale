#!/bin/bash
# Helpers for scripts that run ON THE HOST, because they drive Docker itself:
# stopping containers, archiving volumes, talking to a registry.
#
# Deliberately depends on nothing but `docker` -- anything that needs jq or
# curl is handed to the toolbox container instead, so these scripts behave the
# same on a laptop and on a CI runner.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load .env, but let anything already in the environment win -- the same
# precedence docker compose uses, so `STACK_VERSION=9.4.4 make import` does
# what it looks like it does instead of being silently overridden.
if [[ -f "${ROOT}/.env" ]]; then
  while IFS= read -r _line || [[ -n ${_line} ]]; do
    [[ ${_line} =~ ^[[:space:]]*(#|$) ]] && continue
    _key=${_line%%=*}
    _key=${_key//[[:space:]]/}
    [[ ${_key} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ -n ${!_key+x} ]] && continue
    export "${_key}=${_line#*=}"
  done <"${ROOT}/.env"
  unset _line _key
fi

DATASET_DIR="${DATASET_DIR:-${ROOT}/dataset}"
ALPINE_IMAGE="${ALPINE_IMAGE:-alpine:3.22}"

# Tailscale services are irrelevant to archiving and would fail without an
# auth key, so host tooling always runs with the tailnet profile off.
COMPOSE=(env COMPOSE_PROFILES= docker compose -f "${ROOT}/docker-compose.yml")

log()  { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# tb 'shell command' -- run a command in the toolbox container. Used for jq
# so the host does not need it installed. --no-deps because the callers run
# this while Elasticsearch is deliberately stopped.
tb() {
  "${COMPOSE[@]}" run --rm --no-deps -T toolbox -c "$*"
}

# Name of the Docker volume backing the Elasticsearch data directory. Computed
# rather than looked up, so it resolves before any container exists -- which is
# the situation import-dataset.sh runs in. Must match `name:` in
# docker-compose.yml.
es_data_volume() {
  echo "${COMPOSE_PROJECT_NAME:-elk-tailscale}_esdata"
}

# Containers write into ./dataset as root; give it back to the caller.
fix_dataset_ownership() {
  docker run --rm -v "${DATASET_DIR}:/out" "${ALPINE_IMAGE}" \
    chown -R "$(id -u):$(id -g)" /out
}
