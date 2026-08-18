#!/bin/bash
# Captures the Elasticsearch data directory of the current stack into
# dataset/esdata.tar.gz, ready to publish.
#
# The stack is shut down first, on purpose. A tarball of a live Lucene
# directory is a torn snapshot: translog and segment state can disagree, and
# restoring it produces a corrupt cluster rather than a reproducible one. What
# we want to archive is exactly what an in-place upgrade would find on disk
# after a clean stop.
set -euo pipefail
# shellcheck source=scripts/host-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/host-lib.sh"

[[ -f ${DATASET_DIR}/metadata.json ]] ||
  fail "no metadata at ${DATASET_DIR}/metadata.json; run the seed first"

log "flushing Elasticsearch to disk"
# The password already lives in the container's environment, so it never has
# to be readable on the host to do this.
"${COMPOSE[@]}" exec -T elasticsearch bash -c \
  'curl -fsS -u "elastic:${ELASTIC_PASSWORD}" -XPOST localhost:9200/_flush' >/dev/null

# Writers first, then the store, so nothing is mid-bulk when Elasticsearch exits.
log "stopping the stack cleanly"
"${COMPOSE[@]}" stop --timeout 120 logstash kibana >/dev/null 2>&1 || true
"${COMPOSE[@]}" stop --timeout 120 elasticsearch >/dev/null 2>&1

cid="$("${COMPOSE[@]}" ps -aq elasticsearch)"
[[ -n ${cid} ]] || fail "no elasticsearch container found"
code="$(docker inspect "${cid}" --format '{{.State.ExitCode}}')"
# 0 is a clean exit; 143 is SIGTERM, which is also a clean shutdown path.
[[ ${code} == 0 || ${code} == 143 ]] ||
  fail "Elasticsearch exited with ${code}; refusing to archive a possibly torn data directory"

VOL="$(es_data_volume)"
log "archiving volume ${VOL}"
docker run --rm \
  -v "${VOL}:/data:ro" \
  -v "${DATASET_DIR}:/out" \
  "${ALPINE_IMAGE}" \
  tar czf /out/esdata.tar.gz -C /data .

log "recording archive size and checksum"
tb 'set -e
    bytes=$(stat -c %s /dataset/esdata.tar.gz)
    sha=$(sha256sum /dataset/esdata.tar.gz | cut -d" " -f1)
    jq --argjson bytes "$bytes" --arg sha256 "$sha" \
       ". + {archive: {bytes: \$bytes, sha256: \$sha256}}" \
       /dataset/metadata.json > /dataset/.metadata.tmp
    mv /dataset/.metadata.tmp /dataset/metadata.json
    echo "archive: $(numfmt --to=iec "$bytes")"'

fix_dataset_ownership
log "wrote ${DATASET_DIR}/esdata.tar.gz"
