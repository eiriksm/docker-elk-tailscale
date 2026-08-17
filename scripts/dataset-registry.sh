#!/bin/bash
# Resolves the OCI repository the datasets live in. Sourced, not run.
#
# Datasets are stored as OCI artifacts in the same GitHub Container Registry
# namespace as the repo. Unlike Actions artifacts they never expire, and each
# one is addressable by the stack version that produced it, so
# "boot 9.5.0 on the data 9.4.4 left behind" stays reproducible indefinitely.

# GITHUB_REPOSITORY is set in Actions; fall back to the git remote locally.
if [[ -z ${GITHUB_REPOSITORY:-} ]]; then
  origin=$(git remote get-url origin 2>/dev/null || true)
  GITHUB_REPOSITORY=$(sed -E 's#^.*github\.com[:/]##; s#\.git$##' <<<"${origin}")
fi
[[ -n ${GITHUB_REPOSITORY} ]] || fail "cannot determine the GitHub repository; set GITHUB_REPOSITORY"

# OCI repository names must be lowercase.
DATASET_REPO="${DATASET_REPO:-ghcr.io/$(tr '[:upper:]' '[:lower:]' <<<"${GITHUB_REPOSITORY}")/esdata}"
DATASET_ARTIFACT_TYPE="application/vnd.elk-tailscale.esdata.v1+tar"
