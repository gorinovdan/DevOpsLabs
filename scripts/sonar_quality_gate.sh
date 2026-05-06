#!/usr/bin/env bash
set -euo pipefail

# Idempotently create a SonarQube quality gate "FlowBoard Gate" that
# requires:
#   - overall coverage >= 80%
#   - zero new bugs
#   - zero new vulnerabilities
#   - zero blocker / critical issues
#   - no failing tests
#   - security rating A
#   - reliability rating A
#
# Then make it the gate associated with the "flowboard" project.

SONARQUBE_URL="${SONARQUBE_URL:-http://127.0.0.1:9000}"
SONARQUBE_TOKEN="${SONARQUBE_TOKEN:-}"
SONARQUBE_ADMIN_USER="${SONARQUBE_ADMIN_USER:-admin}"
SONARQUBE_ADMIN_PASSWORD="${SONARQUBE_ADMIN_PASSWORD:-admin}"
PROJECT_KEY="${PROJECT_KEY:-flowboard}"
GATE_NAME="${GATE_NAME:-FlowBoard Gate}"

curl_auth() {
  if [[ -n "${SONARQUBE_TOKEN}" ]]; then
    curl -sS -u "${SONARQUBE_TOKEN}:" "$@"
  else
    curl -sS -u "${SONARQUBE_ADMIN_USER}:${SONARQUBE_ADMIN_PASSWORD}" "$@"
  fi
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required to manage SonarQube quality gates." >&2
    exit 1
  fi
}

require_jq

gate_exists() {
  curl_auth -G "${SONARQUBE_URL}/api/qualitygates/list" \
    | jq -e --arg n "${GATE_NAME}" '.qualitygates[] | select(.name==$n)' >/dev/null 2>&1
}

if gate_exists; then
  echo "Quality gate '${GATE_NAME}' already exists."
else
  echo "Creating quality gate '${GATE_NAME}'..."
  curl_auth -X POST -G "${SONARQUBE_URL}/api/qualitygates/create" \
    --data-urlencode "name=${GATE_NAME}" >/dev/null
fi

upsert_condition() {
  local metric="$1" op="$2" error="$3"

  local existing
  existing="$(curl_auth -G "${SONARQUBE_URL}/api/qualitygates/show" \
    --data-urlencode "name=${GATE_NAME}" \
    | jq -r --arg m "${metric}" '.conditions[]? | select(.metric==$m) | .id // ""')"

  if [[ -n "${existing}" ]]; then
    curl_auth -X POST "${SONARQUBE_URL}/api/qualitygates/update_condition" \
      --data-urlencode "id=${existing}" \
      --data-urlencode "metric=${metric}" \
      --data-urlencode "op=${op}" \
      --data-urlencode "error=${error}" >/dev/null
    echo "Updated condition: ${metric} ${op} ${error}"
  else
    curl_auth -X POST "${SONARQUBE_URL}/api/qualitygates/create_condition" \
      --data-urlencode "gateName=${GATE_NAME}" \
      --data-urlencode "metric=${metric}" \
      --data-urlencode "op=${op}" \
      --data-urlencode "error=${error}" >/dev/null
    echo "Created condition: ${metric} ${op} ${error}"
  fi
}

# Coverage on overall code: fails when value < 80.
upsert_condition coverage LT 80
# Zero issues on overall code.
upsert_condition bugs GT 0
upsert_condition vulnerabilities GT 0
upsert_condition blocker_violations GT 0
upsert_condition critical_violations GT 0
# Tests must pass - SonarQube reads the JSON test report.
upsert_condition test_failures GT 0
upsert_condition test_errors GT 0
# Security and reliability rating must remain A (rating > 1.0 means worse than A).
upsert_condition security_rating GT 1
upsert_condition reliability_rating GT 1

echo "Associating gate '${GATE_NAME}' with project '${PROJECT_KEY}'..."
# project must exist before select succeeds; ignore failure when running before first scan.
if curl_auth -X POST "${SONARQUBE_URL}/api/qualitygates/select" \
    --data-urlencode "gateName=${GATE_NAME}" \
    --data-urlencode "projectKey=${PROJECT_KEY}" >/dev/null 2>&1; then
  echo "Gate associated with project '${PROJECT_KEY}'."
else
  echo "Project '${PROJECT_KEY}' not yet known to SonarQube; gate will associate after first scan."
fi

echo "Quality gate '${GATE_NAME}' is configured."
