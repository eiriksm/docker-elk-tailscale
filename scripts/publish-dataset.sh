#!/bin/bash
# Publishes dataset/ to GHCR as an OCI artifact, tagged with the stack version
# that produced it plus `latest`.
#
# Requires `oras` and a prior `oras login ghcr.io`.
set -euo pipefail
# shellcheck source=scripts/host-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/host-lib.sh"
# shellcheck source=scripts/dataset-registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/dataset-registry.sh"

command -v oras >/dev/null || fail "oras is not installed (https://oras.land)"

[[ -f ${DATASET_DIR}/esdata.tar.gz ]] ||
  fail "no archive at ${DATASET_DIR}/esdata.tar.gz; run scripts/export-dataset.sh first"
[[ -f ${DATASET_DIR}/metadata.json ]] || fail "no metadata at ${DATASET_DIR}/metadata.json"

version="$(tb 'jq -r .stack_version /dataset/metadata.json')"
[[ -n ${version} && ${version} != null ]] || fail "metadata has no stack_version"

log "pushing ${DATASET_REPO}:${version}"
# Pushed from inside the dataset directory so the layer titles are bare
# filenames, which is what fetch-dataset.sh relies on when unpacking.
(
  cd "${DATASET_DIR}"
  oras push "${DATASET_REPO}:${version}" \
    --artifact-type "${DATASET_ARTIFACT_TYPE}" \
    --annotation "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY}" \
    --annotation "org.opencontainers.image.description=Elasticsearch data directory seeded by CI on ${version}" \
    --annotation "io.elk-tailscale.stack-version=${version}" \
    esdata.tar.gz:application/gzip \
    metadata.json:application/json
)

# `latest` is what the migration job restores when no baseline is pinned.
log "moving the 'latest' tag to ${version}"
oras tag "${DATASET_REPO}:${version}" latest

log "published ${DATASET_REPO}:${version} (also tagged latest)"
