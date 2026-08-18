#!/bin/bash
# Asserts that a running stack holds exactly the dataset seed.sh produced.
#
# Used twice: once right after seeding (proves the dataset is what we think it
# is before we archive it) and once after an upgrade has been started on top of
# the restored data directory (proves the migration preserved it).
#
#   scripts/verify.sh [--check-writes]
#
# --check-writes additionally pushes a fresh document through Logstash and
# confirms it lands, so an upgrade that leaves the cluster readable but broken
# for ingest still fails.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK_WRITES=0
[[ ${1:-} == --check-writes ]] && CHECK_WRITES=1

META="${DATASET_DIR}/metadata.json"
[[ -f ${META} ]] || fail "no metadata at ${META}; run seed.sh or restore a dataset first"

failures=0
check() {
  local what=$1 expected=$2 actual=$3
  if [[ ${expected} == "${actual}" ]]; then
    printf '  ok    %-34s %s\n' "${what}" "${actual}"
  else
    printf '  FAIL  %-34s expected %s, got %s\n' "${what}" "${expected}" "${actual}"
    failures=$((failures + 1))
  fi
}

wait_for_es

seeded_version=$(jq -r '.stack_version' "${META}")
running_version=$(es GET / | jq -r '.version.number')
log "dataset written by ${seeded_version}, cluster now running ${running_version}"

log "cluster health"
health=$(es GET '/_cluster/health?wait_for_status=yellow&timeout=180s')
check "cluster name" "$(jq -r '.cluster_name' "${META}")" "$(jq -r '.cluster_name' <<<"${health}")"
check "health request timed out" false "$(jq -r '.timed_out' <<<"${health}")"
# Any unassigned primary means data that is on disk but not readable, which is
# exactly the failure mode a bad upgrade produces.
check "unassigned primary shards" 0 "$(jq -r '.unassigned_primary_shards' <<<"${health}")"

# Cluster-wide green is unreachable here: Kibana's alerting and security
# plugins create system indices with a hardcoded replica that a single node
# can never allocate. So health is asserted on the indices this project owns,
# which the seed templates give zero replicas.
data_health=$(es GET '/_cluster/health/ci-events,logs-ci-default,logstash-*?wait_for_status=green&timeout=120s')
check "seeded index health" green "$(jq -r '.status' <<<"${data_health}")"

es POST /_all/_refresh >/dev/null

log "document counts"
while read -r pattern expected; do
  check "count ${pattern}" "${expected}" "$(count_docs "${pattern}")"
done < <(jq -r '.counts | to_entries[] | "\(.key) \(.value)"' "${META}")

log "content assertions"
expected_errors=$(jq -r '.assertions.error_level_events' "${META}")
actual_errors=$(es GET /ci-events/_count '{"query":{"term":{"level":"error"}}}' | jq -r '.count')
check "ci-events level=error" "${expected_errors}" "${actual_errors}"

# A specific document, fetched by id, with its mapping still intact. Counts
# alone would not catch a mapping migration that mangled field values.
doc=$(es GET /ci-events/_doc/evt-00042)
check "evt-00042 seq" 42 "$(jq -r '._source.seq' <<<"${doc}")"
# seed.sh cycles debug/info/warn/error, so document 42 is levels[42 % 4] = warn.
check "evt-00042 level" warn "$(jq -r '._source.level' <<<"${doc}")"
check "evt-00042 timestamp" 1704069720000 "$(jq -r '._source["@timestamp"]' <<<"${doc}")"

# Aggregations exercise doc_values, which is where a botched upgrade shows up.
agg=$(es GET /ci-events/_search '{"size":0,"aggs":{"levels":{"terms":{"field":"level","size":10}}}}')
check "distinct levels" 4 "$(jq -r '.aggregations.levels.buckets | length' <<<"${agg}")"

log "data stream is still a data stream"
check "logs-ci-default exists" 1 "$(es GET /_data_stream/logs-ci-default | jq -r '.data_streams | length')"

log "Kibana"
wait_for_kibana
check "kibana status" available \
  "$(kbn GET /api/status | jq -r '.status.overall.level')"
# Kibana rewrites its saved objects on every upgrade; if that migration fails
# it usually still starts, just without the objects.
check "data view survived" ci-events-dv \
  "$(kbn GET /api/data_views/data_view/ci-events-dv | jq -r '.data_view.id // "missing"')"

if [[ ${CHECK_WRITES} -eq 1 ]]; then
  log "ingest still works after migration"
  wait_for_logstash
  before=$(count_docs 'logstash-*')
  curl -fsS -o /dev/null -X POST "${LOGSTASH_HTTP_URL}" \
    -H 'Content-Type: application/json' \
    -d '{"seq":9999,"source":"post-migration","message":"written after upgrade"}' ||
    fail "Logstash refused a document after the upgrade"
  for i in $(seq 1 60); do
    es POST "/logstash-*/_refresh?ignore_unavailable=true" >/dev/null 2>&1 || true
    after=$(count_docs 'logstash-*')
    [[ ${after} -gt ${before} ]] && break
    [[ ${i} -eq 60 ]] && fail "post-upgrade document never reached Elasticsearch"
    sleep 2
  done
  check "post-upgrade write landed" "$((before + 1))" "${after}"
fi

if [[ ${failures} -gt 0 ]]; then
  fail "${failures} assertion(s) failed"
fi
log "all assertions passed"
