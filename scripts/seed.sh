#!/bin/bash
# Writes a deterministic dataset into a running stack.
#
# Deterministic matters: verify.sh asserts exact document counts and exact
# aggregation results, so an upgrade that silently drops or mangles documents
# fails CI instead of passing with "well, there's *some* data".
#
# Timestamps are anchored to a fixed date rather than "now" so that a dataset
# captured months ago still verifies identically today.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_EVENTS_DOCS=500
DATA_STREAM_DOCS=250
LOGSTASH_DOCS=25
# 2024-01-01T00:00:00Z
EPOCH_BASE=1704067200

wait_for_es

log "creating index template for ci-*"
# replicas 0 so a single-node cluster can actually reach green, which lets
# verify.sh treat yellow as a failure rather than as normal.
es PUT /_index_template/ci-events '{
  "index_patterns": ["ci-events"],
  "priority": 500,
  "template": {
    "settings": { "number_of_shards": 1, "number_of_replicas": 0 },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "event_id":   { "type": "keyword" },
        "seq":        { "type": "integer" },
        "level":      { "type": "keyword" },
        "service":    { "type": "keyword" },
        "message":    { "type": "text" }
      }
    }
  }
}' >/dev/null

log "creating data stream template for logs-ci-*"
es PUT /_index_template/logs-ci '{
  "index_patterns": ["logs-ci-*"],
  "priority": 500,
  "data_stream": {},
  "template": {
    "settings": { "number_of_shards": 1, "number_of_replicas": 0 },
    "mappings": {
      "properties": {
        "@timestamp": { "type": "date" },
        "seq":        { "type": "integer" },
        "host":       { "type": "keyword" },
        "message":    { "type": "text" }
      }
    }
  }
}' >/dev/null

log "creating index template for logstash-*"
es PUT /_index_template/logstash-ci '{
  "index_patterns": ["logstash-*"],
  "priority": 500,
  "template": {
    "settings": { "number_of_shards": 1, "number_of_replicas": 0 }
  }
}' >/dev/null

log "indexing ${CI_EVENTS_DOCS} documents into ci-events"
LEVELS=(debug info warn error)
{
  for ((i = 0; i < CI_EVENTS_DOCS; i++)); do
    ts=$(( EPOCH_BASE + i * 60 ))
    printf '{"index":{"_id":"evt-%05d"}}\n' "${i}"
    printf '{"@timestamp":%d000,"event_id":"evt-%05d","seq":%d,"level":"%s","service":"svc-%d","message":"synthetic event %d"}\n' \
      "${ts}" "${i}" "${i}" "${LEVELS[$((i % 4))]}" "$((i % 5))" "${i}"
  done
} | es_bulk "/ci-events/_bulk?refresh=wait_for" | jq -e '.errors == false' >/dev/null ||
  fail "bulk index into ci-events reported errors"

log "indexing ${DATA_STREAM_DOCS} documents into the logs-ci-default data stream"
{
  for ((i = 0; i < DATA_STREAM_DOCS; i++)); do
    ts=$(( EPOCH_BASE + i * 300 ))
    printf '{"create":{}}\n'
    printf '{"@timestamp":%d000,"seq":%d,"host":"host-%d","message":"synthetic stream record %d"}\n' \
      "${ts}" "${i}" "$((i % 3))" "${i}"
  done
} | es_bulk "/logs-ci-default/_bulk?refresh=wait_for" | jq -e '.errors == false' >/dev/null ||
  fail "bulk index into logs-ci-default reported errors"

log "sending ${LOGSTASH_DOCS} documents through the Logstash HTTP input"
wait_for_logstash
for ((i = 0; i < LOGSTASH_DOCS; i++)); do
  payload=$(printf '{"seq":%d,"source":"ci-seed","message":"logstash record %d"}' "${i}" "${i}")
  # The pipeline can bind the API before the http input finishes binding, so
  # the first POST gets a few attempts.
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS -o /dev/null -X POST "${LOGSTASH_HTTP_URL}" \
      -H 'Content-Type: application/json' -d "${payload}"; then
      break
    fi
    [[ ${attempt} -eq 10 ]] && fail "Logstash rejected document ${i}"
    sleep 3
  done
done

log "waiting for Logstash output to land in Elasticsearch"
for i in $(seq 1 60); do
  es POST "/logstash-*/_refresh?ignore_unavailable=true" >/dev/null 2>&1 || true
  actual=$(count_docs 'logstash-*')
  [[ ${actual} -ge ${LOGSTASH_DOCS} ]] && break
  [[ ${i} -eq 60 ]] && fail "only ${actual}/${LOGSTASH_DOCS} Logstash documents arrived"
  sleep 2
done

log "creating a Kibana data view so saved-object migration has something to chew on"
wait_for_kibana
dv='{"data_view":{"id":"ci-events-dv","title":"ci-events","timeFieldName":"@timestamp","name":"CI events"}}'
if ! kbn POST /api/data_views/data_view "${dv}" | jq -e '.data_view.id == "ci-events-dv"' >/dev/null 2>&1; then
  # A re-seed against an existing volume is fine; anything else is not.
  kbn GET /api/data_views/data_view/ci-events-dv | jq -e '.data_view.id' >/dev/null 2>&1 ||
    fail "could not create the Kibana data view"
  log "data view already existed"
fi

es POST /_all/_refresh >/dev/null

mkdir -p "${DATASET_DIR}"
jq -n \
  --arg stack_version "${STACK_VERSION}" \
  --arg cluster_name "${CLUSTER_NAME}" \
  --argjson ci_events "$(count_docs ci-events)" \
  --argjson logs_ci "$(count_docs logs-ci-default)" \
  --argjson logstash "$(count_docs 'logstash-*')" \
  --argjson error_events "$(es GET '/ci-events/_count' '{"query":{"term":{"level":"error"}}}' | jq '.count')" \
  '{
     stack_version: $stack_version,
     cluster_name: $cluster_name,
     counts: {
       "ci-events": $ci_events,
       "logs-ci-default": $logs_ci,
       "logstash-*": $logstash
     },
     assertions: { error_level_events: $error_events }
   }' >"${DATASET_DIR}/metadata.json"

log "seeded dataset:"
cat "${DATASET_DIR}/metadata.json"
