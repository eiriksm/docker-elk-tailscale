#!/bin/bash
# Exercises the Slack-alerting logic in logstash/pipeline/20-filters.conf in
# isolation, using the real Logstash binary rather than a reimplementation of
# its conditionals: a stdin input feeds fixture events through the unmodified
# filter file, and a file output records whether each one got flagged for
# Slack and what text it would have posted. No Elasticsearch, no tailnet, and
# the real http output in 30-outputs.conf is never loaded, so nothing is
# actually posted anywhere.
#
#   scripts/test-filters.sh
#
# Runs scripts/fixtures/slack-filter-events.ndjson three times: once with
# Slack and Kibana both configured (exercising every alert / no-alert
# branch), once with the webhook unset (every fixture must come out
# unflagged, configured or not), and once with the webhook set but no Kibana
# URL (an alert must come out with no "View in Kibana" link appended).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ENV_FILE=.env
[[ -f ${ENV_FILE} ]] || ENV_FILE=.env.example
STACK_VERSION="$(grep '^STACK_VERSION=' "${ENV_FILE}" | cut -d= -f2)"
IMAGE="docker.elastic.co/logstash/logstash:${STACK_VERSION}"

FIXTURES="$(pwd)/scripts/fixtures/slack-filter-events.ndjson"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT


# Progress output goes to stderr: run_case is called as `x=$(run_case ...)` to
# capture the one line it actually returns (the results file path), and that
# capture would otherwise swallow these right along with it.
log()  { echo "==> $*" >&2; }
fail() { echo "FAIL: $*" >&2; exit 1; }

failures=0

# run_case NAME SLACK_WEBHOOK_URL KIBANA_PUBLIC_URL FIXTURE_FILE
# Boots one throwaway Logstash container with a synthetic pipeline: our own
# stdin input, the repo's real 20-filters.conf, and a filter+output pair that
# exposes what it decided onto the event so it can be read back from a plain
# file. Prints the path to the resulting NDJSON.
run_case() {
  local name=$1 slack_url=$2 kibana_url=$3 fixture=$4
  local dir="${WORKDIR}/${name}"
  mkdir -p "${dir}/pipeline" "${dir}/results"
  # The official image runs Logstash as a non-root user, which does not
  # necessarily map onto whatever uid owns these host-side directories.
  chmod 777 "${dir}/results"

  cat >"${dir}/pipeline/10-input.conf" <<'EOF'
input {
  stdin { codec => json_lines }
}
EOF

  # The real filter file, unmodified -- this is the thing under test.
  cp logstash/pipeline/20-filters.conf "${dir}/pipeline/20-filters.conf"
  chmod -R a+rX "${dir}/pipeline"

  # @metadata never reaches an output's codec, so surface the two fields the
  # real 30-outputs.conf reads out of it onto ordinary event fields.
  cat >"${dir}/pipeline/30-expose.conf" <<'EOF'
filter {
  if [@metadata][slack_alert] {
    mutate {
      add_field => {
        "test_slack_alert" => "true"
        "test_slack_text"  => "%{[@metadata][slack_text]}"
      }
    }
  } else {
    mutate {
      add_field => { "test_slack_alert" => "false" }
    }
  }
}
EOF

  cat >"${dir}/pipeline/40-output.conf" <<'EOF'
output {
  file {
    path => "/results/output.ndjson"
    codec => json_lines
  }
}
EOF

  log "running case '${name}' (SLACK_WEBHOOK_URL=${slack_url:+set}${slack_url:-unset}, KIBANA_PUBLIC_URL=${kibana_url:+set}${kibana_url:-unset})"
  timeout 180 docker run --rm -i \
    -v "${dir}/pipeline:/usr/share/logstash/pipeline:ro" \
    -v "${dir}/results:/results" \
    -e LS_JAVA_OPTS="-Xms256m -Xmx256m" \
    -e SLACK_WEBHOOK_URL="${slack_url}" \
    -e KIBANA_PUBLIC_URL="${kibana_url}" \
    "${IMAGE}" \
    <"${fixture}" \
    >"${dir}/logstash.log" 2>&1 ||
    { cat "${dir}/logstash.log" >&2; fail "logstash exited non-zero for case '${name}'"; }

  [[ -f "${dir}/results/output.ndjson" ]] ||
    { cat "${dir}/logstash.log" >&2; fail "case '${name}' produced no output -- see Logstash log above"; }

  echo "${dir}/results/output.ndjson"
}

# assert_all_unflagged RESULTS_FILE FIXTURE_FILE -- every fixture event must
# come out with test_slack_alert=false, regardless of its own expectations.
assert_all_unflagged() {
  local results=$1 fixture=$2
  local id actual
  while read -r id; do
    actual=$(jq -r --arg id "${id}" 'select(._id == $id) | .test_slack_alert' "${results}")
    if [[ ${actual} == "true" ]]; then
      echo "  FAIL  ${id}: flagged for Slack, but SLACK_WEBHOOK_URL is unset"
      failures=$((failures + 1))
    else
      echo "  ok    ${id}: not flagged"
    fi
  done < <(jq -r '._id' "${fixture}")
}

# assert_expectations RESULTS_FILE FIXTURE_FILE -- checks each fixture's own
# _alert / _contains / _excludes expectations against what the pipeline did.
assert_expectations() {
  local results=$1 fixture=$2
  local id expect_alert actual_alert text contains_list excludes_list needle ok

  while read -r id; do
    expect_alert=$(jq -r --arg id "${id}" 'select(._id == $id) | ._alert' "${fixture}")
    actual_alert=$(jq -r --arg id "${id}" 'select(._id == $id) | .test_slack_alert' "${results}")
    text=$(jq -r --arg id "${id}" 'select(._id == $id) | .test_slack_text // ""' "${results}")

    if [[ ${actual_alert} != "${expect_alert}" ]]; then
      echo "  FAIL  ${id}: expected alert=${expect_alert}, got alert=${actual_alert}"
      failures=$((failures + 1))
      continue
    fi

    ok=1
    while read -r needle; do
      [[ -z ${needle} ]] && continue
      if [[ ${text} != *"${needle}"* ]]; then
        echo "  FAIL  ${id}: slack_text does not contain expected \"${needle}\" (got: ${text})"
        failures=$((failures + 1))
        ok=0
      fi
    done < <(jq -r --arg id "${id}" 'select(._id == $id) | (._contains // [])[]' "${fixture}")

    while read -r needle; do
      [[ -z ${needle} ]] && continue
      if [[ ${text} == *"${needle}"* ]]; then
        echo "  FAIL  ${id}: slack_text unexpectedly contains \"${needle}\" (got: ${text})"
        failures=$((failures + 1))
        ok=0
      fi
    done < <(jq -r --arg id "${id}" 'select(._id == $id) | (._excludes // [])[]' "${fixture}")

    if [[ ${ok} -eq 1 ]]; then
      echo "  ok    ${id}: alert=${actual_alert}"
    fi
  done < <(jq -r '._id' "${fixture}")
}

log "case 1/3: Slack and Kibana both configured -- every branch"
results=$(run_case full "https://hooks.slack.example.test/services/T000/B000/test" "https://kibana.example.test" "${FIXTURES}")
assert_expectations "${results}" "${FIXTURES}"
# Only the one fixture the pipeline actually alerts on with dataset nginx.error
# is asserted for the Kibana link -- easiest to pin on a single known-good id.
link_text=$(jq -r 'select(._id == "nginx-error-basic") | .test_slack_text // ""' "${results}")
if [[ ${link_text} == *"View in Kibana"* && ${link_text} == *"https://kibana.example.test/app/discover"* ]]; then
  echo "  ok    nginx-error-basic: Kibana link appended"
else
  echo "  FAIL  nginx-error-basic: expected a Kibana link in slack_text (got: ${link_text})"
  failures=$((failures + 1))
fi

log "case 2/3: SLACK_WEBHOOK_URL unset -- nothing is ever flagged"
results=$(run_case webhook-disabled "" "https://kibana.example.test" "${FIXTURES}")
assert_all_unflagged "${results}" "${FIXTURES}"

log "case 3/3: KIBANA_PUBLIC_URL unset -- alert still posts, just with no link"
single_fixture="${WORKDIR}/single-fixture.ndjson"
jq -c 'select(._id == "nginx-error-basic")' "${FIXTURES}" >"${single_fixture}"
results=$(run_case kibana-disabled "https://hooks.slack.example.test/services/T000/B000/test" "" "${single_fixture}")
link_text=$(jq -r 'select(._id == "nginx-error-basic") | .test_slack_text // ""' "${results}")
if [[ ${link_text} == *"nginx error:"* && ${link_text} != *"View in Kibana"* ]]; then
  echo "  ok    nginx-error-basic: alert posted with no Kibana link"
else
  echo "  FAIL  nginx-error-basic: expected an alert with no Kibana link (got: ${link_text})"
  failures=$((failures + 1))
fi

if [[ ${failures} -gt 0 ]]; then
  fail "${failures} assertion(s) failed"
fi
log "all assertions passed"
