#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
GRAFANA_URL="${GRAFANA_URL:-}"
PROMETHEUS_URL="${PROMETHEUS_URL:-}"
GRAFANA_PORT_FORWARD_PORT="${GRAFANA_PORT_FORWARD_PORT:-13100}"
PROMETHEUS_PORT_FORWARD_PORT="${PROMETHEUS_PORT_FORWARD_PORT:-19100}"
GRAFANA_PORT_FORWARD_PID=""
PROMETHEUS_PORT_FORWARD_PID=""

source "${ROOT_DIR}/scripts/lib_minikube.sh"

cleanup() {
  if [[ -n "${GRAFANA_PORT_FORWARD_PID}" ]]; then
    kill "${GRAFANA_PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    wait "${GRAFANA_PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  fi

  if [[ -n "${PROMETHEUS_PORT_FORWARD_PID}" ]]; then
    kill "${PROMETHEUS_PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    wait "${PROMETHEUS_PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  fi
}

assert_json_field_equals() {
  local url="$1"
  local path_expr="$2"
  local expected="$3"
  local curl_args=("${@:4}")
  local response

  response="$(curl -fsS "${curl_args[@]}" "${url}")"

  JSON_PAYLOAD="${response}" python3 - "${path_expr}" "${expected}" <<'PY'
import json
import os
import sys

path = sys.argv[1].split(".")
expected = sys.argv[2]
payload = json.loads(os.environ["JSON_PAYLOAD"])
current = payload
for segment in path:
    current = current[segment]
if str(current) != expected:
    raise SystemExit(f"Error: expected {'.'.join(path)}={expected!r}, got {current!r}")
PY
}

assert_query_has_ready_target() {
  local query="$1"
  local description="$2"
  local response

  response="$(curl -fsS "${PROMETHEUS_URL}/api/v1/query" --get --data-urlencode "query=${query}")"

  JSON_PAYLOAD="${response}" python3 - "${description}" <<'PY'
import json
import os
import sys

description = sys.argv[1]
payload = json.loads(os.environ["JSON_PAYLOAD"])
results = payload.get("data", {}).get("result", [])
if not results:
    raise SystemExit(f"Error: Prometheus query returned no series for {description}.")

for result in results:
    value = result.get("value", [])
    if len(value) >= 2 and str(value[1]) == "1":
        sys.exit(0)

raise SystemExit(f"Error: Prometheus query did not report a ready target for {description}.")
PY
}

assert_query_has_series() {
  local query="$1"
  local description="$2"
  local response

  response="$(curl -fsS "${PROMETHEUS_URL}/api/v1/query" --get --data-urlencode "query=${query}")"

  JSON_PAYLOAD="${response}" python3 - "${description}" <<'PY'
import json
import os
import sys

description = sys.argv[1]
payload = json.loads(os.environ["JSON_PAYLOAD"])
results = payload.get("data", {}).get("result", [])
if not results:
    raise SystemExit(f"Error: Prometheus query returned no series for {description}.")
PY
}

require_cmd kubectl
require_cmd curl
require_cmd python3

trap cleanup EXIT

if [[ -z "${GRAFANA_URL}" ]]; then
  kubectl -n "${MONITORING_NAMESPACE}" port-forward service/grafana "${GRAFANA_PORT_FORWARD_PORT}:80" >/tmp/flowboard-grafana-verify-port-forward.log 2>&1 &
  GRAFANA_PORT_FORWARD_PID=$!
  wait_for_local_port "${GRAFANA_PORT_FORWARD_PORT}" 127.0.0.1 30
  GRAFANA_URL="http://127.0.0.1:${GRAFANA_PORT_FORWARD_PORT}"
fi

if [[ -z "${PROMETHEUS_URL}" ]]; then
  kubectl -n "${MONITORING_NAMESPACE}" port-forward service/prometheus "${PROMETHEUS_PORT_FORWARD_PORT}:9090" >/tmp/flowboard-prometheus-verify-port-forward.log 2>&1 &
  PROMETHEUS_PORT_FORWARD_PID=$!
  wait_for_local_port "${PROMETHEUS_PORT_FORWARD_PORT}" 127.0.0.1 30
  PROMETHEUS_URL="http://127.0.0.1:${PROMETHEUS_PORT_FORWARD_PORT}"
fi

echo "Checking Grafana health..."
assert_json_field_equals "${GRAFANA_URL}/api/health" "database" "ok"

echo "Checking Grafana dashboard provisioning..."
assert_json_field_equals "${GRAFANA_URL}/api/dashboards/uid/flowboard-overview" "dashboard.title" "FlowBoard Overview" -u admin:admin
assert_json_field_equals "${GRAFANA_URL}/api/dashboards/uid/flowboard-pod-details" "dashboard.title" "FlowBoard Pod Details" -u admin:admin

echo "Checking Prometheus health..."
curl -fsS "${PROMETHEUS_URL}/-/healthy" | grep -q 'Healthy'

echo "Checking Prometheus scrape targets..."
assert_query_has_ready_target 'up{job="flowboard-backend"}' 'flowboard-backend'

echo "Checking application metrics..."
assert_query_has_series 'flowboard_http_requests_total' 'flowboard request counters'

echo
echo "Observability verification passed."
