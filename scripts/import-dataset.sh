#!/bin/bash
# Replaces the Elasticsearch data volume with the contents of
# dataset/esdata.tar.gz, so the next `up` starts the configured STACK_VERSION
# on top of data written by an earlier one.
#
# This is destructive: whatever is in the volume now is gone.
set -euo pipefail
# shellcheck source=scripts/host-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/host-lib.sh"

[[ -f ${DATASET_DIR}/esdata.tar.gz ]] || fail "no archive at ${DATASET_DIR}/esdata.tar.gz"
[[ -f ${DATASET_DIR}/metadata.json ]] || fail "no metadata at ${DATASET_DIR}/metadata.json"

# Validate and report before destroying anything.
info="$(tb 'set -e
  jq -e ".archive.sha256" /dataset/metadata.json >/dev/null || { echo "metadata has no checksum" >&2; exit 1; }
  want=$(jq -r .archive.sha256 /dataset/metadata.json)
  got=$(sha256sum /dataset/esdata.tar.gz | cut -d" " -f1)
  [ "$want" = "$got" ] || { echo "archive checksum mismatch: expected $want, got $got" >&2; exit 1; }
  jq -r "\"\(.stack_version) \(.cluster_name)\"" /dataset/metadata.json')"

read -r seeded_version seeded_cluster <<<"${info}"
log "restoring a dataset written by Elasticsearch ${seeded_version} (cluster '${seeded_cluster}')"

# Elasticsearch refuses to start against a data directory that belongs to a
# different cluster; catch it here with a readable message instead of a
# 200-line Java stack trace ten minutes later.
[[ ${seeded_cluster} == "${CLUSTER_NAME}" ]] ||
  fail "dataset cluster name '${seeded_cluster}' != configured CLUSTER_NAME '${CLUSTER_NAME}'"

# Same idea for the two upgrade paths Elasticsearch does not support. Failing
# here says what is wrong; failing later just says the node would not start.
ver_le() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }

ver_le "${seeded_version}" "${STACK_VERSION}" ||
  fail "dataset was written by ${seeded_version}, newer than STACK_VERSION=${STACK_VERSION}; Elasticsearch cannot open a data directory from a newer version"

if (( ${STACK_VERSION%%.*} - ${seeded_version%%.*} > 1 )); then
  fail "cannot upgrade ${seeded_version} to ${STACK_VERSION} in place; Elasticsearch only reads data from the previous major version. Step through ${seeded_version%%.*}.x -> $(( ${seeded_version%%.*} + 1 )).x first."
fi

log "tearing down the stack and discarding the current data volume"
"${COMPOSE[@]}" down --remove-orphans --timeout 120 >/dev/null 2>&1 || true

VOL="$(es_data_volume)"
docker volume rm -f "${VOL}" >/dev/null 2>&1 || true
docker volume create "${VOL}" >/dev/null

log "extracting into ${VOL}"
docker run --rm \
  -v "${VOL}:/data" \
  -v "${DATASET_DIR}:/in:ro" \
  "${ALPINE_IMAGE}" \
  tar xzf /in/esdata.tar.gz -C /data

# Elasticsearch runs as uid 1000 and will not start if it cannot write here.
docker run --rm -v "${VOL}:/data" "${ALPINE_IMAGE}" chown -R 1000:0 /data

log "restored; bring the stack up with STACK_VERSION=${STACK_VERSION} to exercise the migration"
