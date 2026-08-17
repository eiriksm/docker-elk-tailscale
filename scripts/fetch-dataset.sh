#!/bin/bash
# Downloads a published dataset into dataset/.
#
#   scripts/fetch-dataset.sh [TAG]      # default: latest
#
# Exits 3 (rather than 1) when the tag does not exist, so callers can tell
# "no baseline has been published yet" apart from a real failure.
set -euo pipefail
# shellcheck source=scripts/host-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/host-lib.sh"
# shellcheck source=scripts/dataset-registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/dataset-registry.sh"

command -v oras >/dev/null || fail "oras is not installed (https://oras.land)"

TAG="${1:-latest}"

if ! oras manifest fetch "${DATASET_REPO}:${TAG}" >/dev/null 2>&1; then
  echo "no dataset published at ${DATASET_REPO}:${TAG}" >&2
  exit 3
fi

mkdir -p "${DATASET_DIR}"
rm -f "${DATASET_DIR}/esdata.tar.gz" "${DATASET_DIR}/metadata.json"

log "pulling ${DATASET_REPO}:${TAG}"
oras pull "${DATASET_REPO}:${TAG}" --output "${DATASET_DIR}"

[[ -f ${DATASET_DIR}/esdata.tar.gz ]] || fail "pulled artifact contained no esdata.tar.gz"
[[ -f ${DATASET_DIR}/metadata.json ]] || fail "pulled artifact contained no metadata.json"

log "fetched a dataset written by Elasticsearch $(tb 'jq -r .stack_version /dataset/metadata.json')"
