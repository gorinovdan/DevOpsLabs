#!/usr/bin/env bash
set -euo pipefail

WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-90}"
WAIT_DELAY_SEC="${WAIT_DELAY_SEC:-2}"
VERIFY_REESTABLISH_PORT_FORWARDS="${VERIFY_REESTABLISH_PORT_FORWARDS:-0}"

FRONTEND_URL="${FRONTEND_URL:-http://127.0.0.1:18081/}"
BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:18080/health}"
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:13000/api/health}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:19090/-/healthy}"
ARGOCD_URL="${ARGOCD_URL:-http://127.0.0.1:18083/}"
SONARQUBE_URL="${SONARQUBE_URL:-http://127.0.0.1:19000/api/system/status}"
DASHBOARD_URL="${DASHBOARD_URL:-http://127.0.0.1:18001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/}"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: ${cmd}" >&2
    exit 1
  fi
}

wait_for_url() {
  local name="$1"
  local url="$2"
  local attempt

  echo "Checking ${name}: ${url}"
  for attempt in $(seq 1 "${WAIT_ATTEMPTS}"); do
    if curl --noproxy '*' -fsSL --connect-timeout 2 --max-time 5 "${url}" >/dev/null 2>&1; then
      echo "  OK: ${name}"
      return 0
    fi

    if [[ "${attempt}" -lt "${WAIT_ATTEMPTS}" ]]; then
      sleep "${WAIT_DELAY_SEC}"
    fi
  done

  echo "Error: ${name} is not reachable at ${url}" >&2
  return 1
}

require_cmd curl

if [[ "${VERIFY_REESTABLISH_PORT_FORWARDS}" == "1" ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/lib_minikube.sh
  source "${script_dir}/lib_minikube.sh"

  echo "Re-establishing CI/CD port-forwards before URL verification..."
  ensure_port_forward "frontend"   "flowboard"  "frontend"      "18081" "80"   "/"
  ensure_port_forward "backend"    "flowboard"  "backend"       "18080" "8080" "/health"
  ensure_port_forward "grafana"    "monitoring" "grafana"       "13000" "80"   "/api/health"
  ensure_port_forward "prometheus" "monitoring" "prometheus"    "19090" "9090" "/-/healthy"
  ensure_port_forward "argocd"     "argocd"     "argocd-server" "18083" "80"   "/"
  ensure_port_forward "sonarqube"  "sonarqube"  "sonarqube"     "19000" "9000" "/api/system/status"
  ensure_kubectl_proxy 18001
  echo
fi

wait_for_url "Frontend" "${FRONTEND_URL}"
wait_for_url "Backend health" "${BACKEND_URL}"
wait_for_url "Grafana" "${GRAFANA_URL}"
wait_for_url "Prometheus" "${PROMETHEUS_URL}"
wait_for_url "Argo CD" "${ARGOCD_URL}"
wait_for_url "SonarQube" "${SONARQUBE_URL}"
wait_for_url "Kubernetes Dashboard" "${DASHBOARD_URL}"

echo
echo "All published CI/CD URLs are reachable."
