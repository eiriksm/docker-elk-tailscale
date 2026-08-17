#!/bin/bash
# Creates the accounts Kibana and Logstash use to talk to Elasticsearch.
# Runs on every `up`; every operation here is an overwrite, so re-running is
# harmless and it is safe to run against a restored data directory.
set -euo pipefail

ES=http://elasticsearch:9200

log() { echo "[setup] $*"; }

log "waiting for Elasticsearch to accept authenticated requests"
until curl -fsS -u "elastic:${ELASTIC_PASSWORD}" \
  "${ES}/_cluster/health?wait_for_status=yellow&timeout=10s" >/dev/null 2>&1; do
  sleep 2
done

api() {
  local method=$1 path=$2 body=${3:-}
  local args=(--fail-with-body -sS -u "elastic:${ELASTIC_PASSWORD}"
    -X "${method}" "${ES}${path}" -H 'Content-Type: application/json')
  if [[ -n ${body} ]]; then
    args+=(-d "${body}")
  fi
  curl "${args[@]}" >/dev/null
}

log "setting kibana_system password"
api POST /_security/user/kibana_system/_password \
  "{\"password\":\"${KIBANA_SYSTEM_PASSWORD}\"}"

log "creating logstash_writer role"
api PUT /_security/role/logstash_writer '{
  "cluster": ["monitor", "manage_index_templates", "manage_ilm", "read_pipeline"],
  "indices": [
    {
      "names": ["logstash-*", "logs-*", "ci-*"],
      "privileges": ["write", "create", "create_index", "manage", "manage_ilm", "auto_configure"]
    }
  ]
}'

log "creating logstash_internal user"
api PUT /_security/user/logstash_internal "{
  \"password\": \"${LOGSTASH_INTERNAL_PASSWORD}\",
  \"roles\": [\"logstash_writer\"],
  \"full_name\": \"Internal Logstash writer\"
}"

log "done"
