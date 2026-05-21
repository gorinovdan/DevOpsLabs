#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-minikube}"
DASHBOARD_NAMESPACE="${DASHBOARD_NAMESPACE:-kubernetes-dashboard}"
DASHBOARD_IMAGE="${DASHBOARD_IMAGE:-kubernetesui/dashboard:v2.7.0}"
DASHBOARD_METRICS_IMAGE="${DASHBOARD_METRICS_IMAGE:-kubernetesui/metrics-scraper:v1.0.8}"
DASHBOARD_LOCAL_PORT="${DASHBOARD_LOCAL_PORT:-18001}"
ENABLE_KUBECTL_PROXY="${ENABLE_KUBECTL_PROXY:-1}"
AUTO_START_MINIKUBE="${AUTO_START_MINIKUBE:-0}"
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-6144}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"

source "${ROOT_DIR}/scripts/lib_minikube.sh"

require_cmd minikube
require_cmd kubectl
require_cmd docker

wait_for_dashboard_deployments() {
  for _ in $(seq 1 30); do
    if kubectl -n "${DASHBOARD_NAMESPACE}" get deploy kubernetes-dashboard dashboard-metrics-scraper >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "Error: Kubernetes Dashboard deployments did not appear in namespace ${DASHBOARD_NAMESPACE}." >&2
  exit 1
}

set_deployment_image_if_needed() {
  local deployment="$1"
  local container="$2"
  local image="$3"
  local current

  current="$(kubectl -n "${DASHBOARD_NAMESPACE}" get deploy "${deployment}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"

  if [[ "${current}" == "${image}" ]]; then
    echo "Dashboard deployment ${deployment} already uses ${image}."
    return 0
  fi

  echo "Setting ${deployment}/${container} image to ${image}."
  kubectl -n "${DASHBOARD_NAMESPACE}" set image "deploy/${deployment}" "${container}=${image}"
}

set_pull_policy_if_needed() {
  local deployment="$1"
  local current

  current="$(kubectl -n "${DASHBOARD_NAMESPACE}" get deploy "${deployment}" \
    -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}' 2>/dev/null || true)"

  if [[ "${current}" == "IfNotPresent" ]]; then
    return 0
  fi

  kubectl -n "${DASHBOARD_NAMESPACE}" patch deploy "${deployment}" --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' \
    >/dev/null
}

rollout_dashboard() {
  kubectl -n "${DASHBOARD_NAMESPACE}" rollout status deploy/kubernetes-dashboard --timeout="${ROLLOUT_TIMEOUT}"
  kubectl -n "${DASHBOARD_NAMESPACE}" rollout status deploy/dashboard-metrics-scraper --timeout="${ROLLOUT_TIMEOUT}"
}

ensure_minikube_running "${AUTO_START_MINIKUBE}" "${MINIKUBE_DRIVER}" "${MINIKUBE_CPUS}" "${MINIKUBE_MEMORY}"

load_image_into_minikube "${DASHBOARD_IMAGE}"
load_image_into_minikube "${DASHBOARD_METRICS_IMAGE}"

echo "Ensuring Kubernetes Dashboard addon is enabled..."
if ! run_minikube -p "${MINIKUBE_PROFILE}" addons list -o json \
    | grep -A1 '"dashboard"' | grep -q '"enabled": true'; then
  run_minikube -p "${MINIKUBE_PROFILE}" addons enable dashboard >/dev/null
fi

wait_for_dashboard_deployments
set_deployment_image_if_needed "kubernetes-dashboard" "kubernetes-dashboard" "${DASHBOARD_IMAGE}"
set_deployment_image_if_needed "dashboard-metrics-scraper" "dashboard-metrics-scraper" "${DASHBOARD_METRICS_IMAGE}"
set_pull_policy_if_needed "kubernetes-dashboard"
set_pull_policy_if_needed "dashboard-metrics-scraper"
rollout_dashboard

if [[ "${ENABLE_KUBECTL_PROXY}" == "1" ]]; then
  ensure_kubectl_proxy "${DASHBOARD_LOCAL_PORT}"
fi

echo
echo "Kubernetes Dashboard is ready:"
echo "  http://127.0.0.1:${DASHBOARD_LOCAL_PORT}/api/v1/namespaces/${DASHBOARD_NAMESPACE}/services/http:kubernetes-dashboard:/proxy/"
