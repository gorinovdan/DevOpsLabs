#!/usr/bin/env bash
# Запускает Kubernetes Dashboard в minikube и печатает URL для браузера.
# Лечит типичный сбой под VPN: поды dashboard в ImagePullBackOff из-за того,
# что VM-ный DNS не резолвит docker.io. Прогревает образы через host-docker,
# загружает их в minikube и снимает digest-пин с deployment'ов.
#
# Usage:
#   ./scripts/open_minikube_dashboard.sh          # включить и открыть (foreground, Ctrl+C для выхода)
#   ./scripts/open_minikube_dashboard.sh --stop   # остановить proxy

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-minikube}"
DASHBOARD_NS="kubernetes-dashboard"
DASHBOARD_IMAGE="${DASHBOARD_IMAGE:-kubernetesui/dashboard:v2.7.0}"
METRICS_IMAGE="${METRICS_IMAGE:-kubernetesui/metrics-scraper:v1.0.8}"
PROXY_PORT="${PROXY_PORT:-18001}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-90s}"

source "${ROOT_DIR}/scripts/lib_minikube.sh"

if [[ "${1:-}" == "--stop" ]]; then
  echo "Stopping dashboard proxy..."
  pkill -f "kubectl proxy --port=${PROXY_PORT}" 2>/dev/null || true
  pkill -f "minikube.*dashboard" 2>/dev/null || true
  echo "Done."
  exit 0
fi

require_cmd minikube
require_cmd kubectl
require_cmd docker

if ! minikube -p "${MINIKUBE_PROFILE}" status >/dev/null 2>&1; then
  echo "Error: minikube profile ${MINIKUBE_PROFILE} is not running. Start it first." >&2
  exit 1
fi

echo "Ensuring dashboard addon is enabled..."
if ! minikube -p "${MINIKUBE_PROFILE}" addons list -o json \
     | grep -A1 '"dashboard"' | grep -q '"enabled": true'; then
  minikube -p "${MINIKUBE_PROFILE}" addons enable dashboard >/dev/null
fi

# Ждём, пока k8s разложит манифест аддона и появятся deployment'ы.
for _ in $(seq 1 15); do
  if kubectl -n "${DASHBOARD_NS}" get deploy kubernetes-dashboard \
       dashboard-metrics-scraper >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

pods_have_pull_error() {
  kubectl -n "${DASHBOARD_NS}" get pods \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[*].state.waiting.reason}{"\n"}{end}' \
    2>/dev/null | grep -qE "ImagePullBackOff|ErrImagePull"
}

uses_digest_pin() {
  kubectl -n "${DASHBOARD_NS}" get deploy "$1" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
    | grep -q "@sha256:"
}

all_pods_ready() {
  local total ready
  total="$(kubectl -n "${DASHBOARD_NS}" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  ready="$(kubectl -n "${DASHBOARD_NS}" get pods \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    2>/dev/null | grep -c "^True$" || true)"
  [[ "${total}" -gt 0 && "${total}" == "${ready}" ]]
}

echo "Checking dashboard pod state..."
for _ in $(seq 1 10); do
  if all_pods_ready && ! uses_digest_pin kubernetes-dashboard; then break; fi
  if pods_have_pull_error; then break; fi
  sleep 2
done

needs_fix=0
pods_have_pull_error && needs_fix=1
uses_digest_pin kubernetes-dashboard && needs_fix=1

if [[ "${needs_fix}" == "1" ]]; then
  echo "Applying VPN workaround: pulling images via host docker..."
  docker pull "${DASHBOARD_IMAGE}" >/dev/null
  docker pull "${METRICS_IMAGE}" >/dev/null

  echo "Loading images into minikube..."
  minikube -p "${MINIKUBE_PROFILE}" image load "${DASHBOARD_IMAGE}"
  minikube -p "${MINIKUBE_PROFILE}" image load "${METRICS_IMAGE}"

  echo "Dropping digest pin so kubelet uses the locally loaded image..."
  kubectl -n "${DASHBOARD_NS}" set image deploy/kubernetes-dashboard \
    "kubernetes-dashboard=${DASHBOARD_IMAGE}"
  kubectl -n "${DASHBOARD_NS}" set image deploy/dashboard-metrics-scraper \
    "dashboard-metrics-scraper=${METRICS_IMAGE}"

  kubectl -n "${DASHBOARD_NS}" rollout status deploy/kubernetes-dashboard \
    --timeout="${ROLLOUT_TIMEOUT}"
  kubectl -n "${DASHBOARD_NS}" rollout status deploy/dashboard-metrics-scraper \
    --timeout="${ROLLOUT_TIMEOUT}"
fi

# Убиваем старый kubectl proxy на этом порту, если остался от прошлого запуска.
pkill -f "kubectl proxy --port=${PROXY_PORT}" 2>/dev/null || true
sleep 1

URL="http://127.0.0.1:${PROXY_PORT}/api/v1/namespaces/${DASHBOARD_NS}/services/http:kubernetes-dashboard:/proxy/"
echo
echo "Dashboard URL:"
echo "  ${URL}"
echo
echo "Starting kubectl proxy on :${PROXY_PORT} (Ctrl+C to stop)..."
exec kubectl proxy --port="${PROXY_PORT}"
