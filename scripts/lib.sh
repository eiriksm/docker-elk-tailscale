#!/bin/bash
# Helpers for scripts that run INSIDE the toolbox container, on the compose
# network. Sourced, not executed.
#
# Defaults point at compose service names, so nothing here needs a published
# port. Override the URLs if you run these from somewhere else.

ES_URL="${ES_URL:-http://elasticsearch:9200}"
KIBANA_URL="${KIBANA_URL:-http://kibana:5601}"
LOGSTASH_HTTP_URL="${LOGSTASH_HTTP_URL:-http://logstash:8080}"
LOGSTASH_API_URL="${LOGSTASH_API_URL:-http://logstash:9600}"
DATASET_DIR="${DATASET_DIR:-/dataset}"
: "${ELASTIC_PASSWORD:?ELASTIC_PASSWORD must be set}"

log()  { echo "==> $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# es METHOD PATH [BODY] -- authenticated Elasticsearch request, non-2xx is fatal.
es() {
  local method=$1 path=$2 body=${3:-}
  local args=(--fail-with-body -sS -u "elastic:${ELASTIC_PASSWORD}"
    -X "${method}" "${ES_URL}${path}" -H 'Content-Type: application/json')
  if [[ -n ${body} ]]; then
    args+=(--data-binary "${body}")
  fi
  curl "${args[@]}"
}

# es_bulk PATH -- reads NDJSON on stdin.
es_bulk() {
  curl --fail-with-body -sS -u "elastic:${ELASTIC_PASSWORD}" \
    -X POST "${ES_URL}$1" \
    -H 'Content-Type: application/x-ndjson' --data-binary @-
}

# kbn METHOD PATH [BODY] -- Kibana API request. Kibana requires both
# authentication and the kbn-xsrf header on writes; without them it answers
# 401/400 with a JSON body, which is easy to mistake for success.
# Deliberately not --fail, so callers can inspect the status in the body.
kbn() {
  local method=$1 path=$2 body=${3:-}
  local args=(-sS -u "elastic:${ELASTIC_PASSWORD}" -X "${method}" "${KIBANA_URL}${path}"
    -H 'kbn-xsrf: true' -H 'Content-Type: application/json')
  if [[ -n ${body} ]]; then
    args+=(--data-binary "${body}")
  fi
  curl "${args[@]}"
}

# count_docs INDEX_PATTERN -- resolves to 0 when nothing matches the pattern.
count_docs() {
  curl -sS -u "elastic:${ELASTIC_PASSWORD}" \
    "${ES_URL}/$1/_count?ignore_unavailable=true&allow_no_indices=true" |
    jq -r '.count // 0'
}

wait_for_es() {
  log "waiting for Elasticsearch at ${ES_URL}"
  local i
  for i in $(seq 1 120); do
    if curl -fsS -u "elastic:${ELASTIC_PASSWORD}" \
      "${ES_URL}/_cluster/health?wait_for_status=yellow&timeout=5s" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  fail "Elasticsearch did not become reachable"
}

wait_for_kibana() {
  log "waiting for Kibana at ${KIBANA_URL}"
  local i status=unknown
  for i in $(seq 1 120); do
    status="$(kbn GET /api/status 2>/dev/null |
      jq -r '.status.overall.level // "unknown"' 2>/dev/null || echo unknown)"
    if [[ ${status} == available ]]; then
      return 0
    fi
    sleep 5
  done
  fail "Kibana did not reach status 'available' (last seen: ${status})"
}

# Waits on the monitoring API rather than probing the http input, so that
# waiting never injects a document and skews the seeded counts.
wait_for_logstash() {
  log "waiting for the Logstash pipeline at ${LOGSTASH_API_URL}"
  local i
  for i in $(seq 1 60); do
    if curl -fsS "${LOGSTASH_API_URL}/_node/pipelines" 2>/dev/null |
      jq -e '.pipelines.main' >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  fail "Logstash pipeline 'main' never started"
}
