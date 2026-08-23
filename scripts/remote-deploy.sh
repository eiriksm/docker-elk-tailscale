#!/bin/bash
# Runs ON THE DEPLOYMENT HOST. The workflow checks out the commit being
# deployed and then execs this file, so the deploy logic that runs is always
# the one that shipped with the code being deployed.
#
# Contract with .github/workflows/deploy.yml:
#
#   DEPLOY_SHA           commit now checked out, already proven to be on main
#   DEPLOY_PREVIOUS_SHA  commit that was checked out before
#   DEPLOY_FORCE         "true" to redeploy even when nothing changed
#
# Everything printed here lands in a public Actions log. Do not echo .env, do
# not run `docker compose config`, and do not dump container logs from here.
set -euo pipefail
# shellcheck source=scripts/host-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/host-lib.sh"

: "${DEPLOY_SHA:?DEPLOY_SHA must be set}"
: "${DEPLOY_PREVIOUS_SHA:=}"
: "${DEPLOY_FORCE:=false}"

# host-lib's COMPOSE array switches the tailnet profile off, because it exists
# for archiving and testing. A deploy is the one case that has to bring the
# proxies up, so it uses its own invocation and whatever COMPOSE_PROFILES the
# host's .env asks for.
compose=(docker compose -f "${ROOT}/docker-compose.yml")

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

# Secrets belong to the host, not to the repository and not to GitHub. This
# file is created once by hand and no deploy ever writes it.
[[ -f ${ROOT}/.env ]] ||
  fail "no .env on this host; copy .env.example and fill in the real values (see docs/deploy.md)"

if grep -qi 'changeme' "${ROOT}/.env"; then
  fail ".env still contains a 'changeme' placeholder; refusing to deploy"
fi

perms="$(stat -c %a "${ROOT}/.env")"
if (( 8#${perms} & 8#077 )); then
  echo "WARN: .env is mode ${perms}; chmod 600 it" >&2
fi

# The versions that ship with the commit win over whatever the host's .env
# says. .env.example is the file CI seeded and the migration test replayed real
# data through, so it is the one with evidence behind it; the host's .env is
# for secrets and host-specific settings. Exporting them is enough to override
# .env, because docker compose lets the environment outrank it.
for key in STACK_VERSION TAILSCALE_VERSION; do
  value="$(sed -n "s/^${key}=//p" "${ROOT}/.env.example" | head -1)"
  [[ -n ${value} ]] || fail "no ${key} in .env.example"
  export "${key}=${value}"
done

# Which version wrote the data currently on disk. Read off the container
# rather than the volume, because the image tag is the thing that actually
# opened it.
current_version=""
cid="$("${compose[@]}" ps -aq elasticsearch 2>/dev/null | head -1)"
if [[ -n ${cid} ]]; then
  image="$(docker inspect "${cid}" --format '{{.Config.Image}}')"
  current_version="${image##*:}"
fi

if [[ ${current_version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  # The same two upgrade paths import-dataset.sh refuses, checked here against
  # the live volume. There is no snapshot to fall back on, so this is the last
  # thing standing between a bad version bump and a data directory
  # Elasticsearch will not open.
  ver_le() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }

  ver_le "${current_version}" "${STACK_VERSION}" ||
    fail "this host is running ${current_version} and the commit asks for ${STACK_VERSION}; Elasticsearch cannot open a data directory written by a newer version"

  if (( ${STACK_VERSION%%.*} - ${current_version%%.*} > 1 )); then
    fail "cannot upgrade ${current_version} to ${STACK_VERSION} in place; Elasticsearch only reads data from the previous major version. Step through ${current_version%%.*}.x -> $(( ${current_version%%.*} + 1 )).x first."
  fi

  if [[ ${current_version} != "${STACK_VERSION}" ]]; then
    log "upgrading Elasticsearch ${current_version} -> ${STACK_VERSION} in place"
  fi
elif [[ -n ${current_version} ]]; then
  echo "WARN: cannot read a version out of image tag '${current_version}'; skipping the upgrade-path check" >&2
else
  log "no existing stack on this host; this is a first deploy"
fi

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------

# Every service up, and every service that has a healthcheck passing it.
stack_healthy() {
  local ids id state health
  ids="$("${compose[@]}" ps -q 2>/dev/null)" || return 1
  [[ -n ${ids} ]] || return 1
  while read -r id; do
    [[ -n ${id} ]] || continue
    read -r state health < <(docker inspect "${id}" --format \
      '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
    [[ ${state} == running ]] || return 1
    [[ ${health} == healthy || ${health} == none ]] || return 1
  done <<<"${ids}"
}

# Both required workflows can wake the deploy for the same commit. Rather than
# orchestrate that away, make the second one cheap.
if [[ ${DEPLOY_FORCE} != true && ${DEPLOY_PREVIOUS_SHA} == "${DEPLOY_SHA}" ]] && stack_healthy; then
  log "already at ${DEPLOY_SHA:0:12} and healthy; nothing to do"
  exit 0
fi

log "deploying ${DEPLOY_SHA:0:12}"

log "pulling images"
"${compose[@]}" pull --quiet

log "starting the stack"
# --force-recreate because config that changes with a commit -- logstash's
# pipeline and logstash.yml -- is bind-mounted, not baked into the image.
# Compose's own diff only looks at image/env/ports/volume list, never at
# what a bind-mounted file contains, so without this a pipeline-only change
# would reach the host but never reach the running container.
#
# --wait fails the deploy if anything does not become healthy, which is what
# turns a broken upgrade into a red run instead of a quiet outage.
"${compose[@]}" up -d --wait --wait-timeout 600 --remove-orphans --force-recreate

# --wait already waited on the healthchecks; this asserts the cluster itself
# came back, not just the process. The password is expanded inside the
# container, so it never appears on a command line or in this log.
log "checking cluster health"
"${compose[@]}" exec -T elasticsearch bash -c \
  'curl -fsS -u "elastic:${ELASTIC_PASSWORD}" "localhost:9200/_cluster/health?wait_for_status=yellow&timeout=60s" >/dev/null' ||
  fail "Elasticsearch did not reach yellow after the deploy"

# Safe to print: no host ports are published, so this is service names and
# health and nothing else.
"${compose[@]}" ps

log "deployed ${DEPLOY_SHA:0:12} (Elasticsearch ${STACK_VERSION})"
