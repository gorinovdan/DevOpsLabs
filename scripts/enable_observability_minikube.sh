#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S_DIR="${K8S_DIR:-${ROOT_DIR}/deploy/k8s}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"

AUTO_START_MINIKUBE="${AUTO_START_MINIKUBE:-0}"
BUILD_OBSERVABILITY_LOCAL="${BUILD_OBSERVABILITY_LOCAL:-0}"
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-6144}"

POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
INIT_POSTGRES_IMAGE="${INIT_POSTGRES_IMAGE:-postgres:16-alpine}"
BACKEND_IMAGE="${BACKEND_IMAGE:-ghcr.io/discipliny/dev_ops/backend:latest}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-ghcr.io/discipliny/dev_ops/frontend:latest}"
PROMETHEUS_IMAGE="${PROMETHEUS_IMAGE:-quay.io/prometheus/prometheus:v2.54.1}"
GRAFANA_IMAGE="${GRAFANA_IMAGE:-docker.io/grafana/grafana-oss:11.2.2}"
KUBE_STATE_METRICS_IMAGE="${KUBE_STATE_METRICS_IMAGE:-registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0}"
METRICS_SERVER_IMAGE="${METRICS_SERVER_IMAGE:-registry.k8s.io/metrics-server/metrics-server:v0.8.1}"
PROMETHEUS_RELEASE_VERSION="${PROMETHEUS_RELEASE_VERSION:-2.54.1}"
GRAFANA_RELEASE_VERSION="${GRAFANA_RELEASE_VERSION:-11.2.2}"

source "${ROOT_DIR}/scripts/lib_minikube.sh"

apply_monitoring_manifest() {
  local rendered_path
  rendered_path="$(mktemp)"
  trap 'rm -f "${rendered_path}"' RETURN
  render_template_file "${K8S_DIR}/monitoring.yaml" "${rendered_path}"
  kubectl_apply_if_changed "${rendered_path}" "${K8S_DIR}/monitoring.yaml"
  trap - RETURN
  rm -f "${rendered_path}"
}

wait_for_metrics_api() {
  for _ in $(seq 1 30); do
    if kubectl top nodes >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done

  echo "Error: Metrics API did not become available." >&2
  exit 1
}

require_cmd minikube
require_cmd kubectl
require_cmd docker

ensure_minikube_running "${AUTO_START_MINIKUBE}" "${MINIKUBE_DRIVER}" "${MINIKUBE_CPUS}" "${MINIKUBE_MEMORY}"

if [[ "${BUILD_OBSERVABILITY_LOCAL}" == "1" ]]; then
  build_local_observability_images \
    "${PROMETHEUS_IMAGE}" \
    "${PROMETHEUS_RELEASE_VERSION}" \
    "${GRAFANA_IMAGE}" \
    "${GRAFANA_RELEASE_VERSION}"
fi

load_image_into_minikube "${METRICS_SERVER_IMAGE}"
load_image_into_minikube "${PROMETHEUS_IMAGE}"
load_image_into_minikube "${GRAFANA_IMAGE}"
load_image_into_minikube "${KUBE_STATE_METRICS_IMAGE}"

echo "Enabling metrics-server addon..."
minikube addons enable metrics-server >/dev/null

if ! kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q '^True$'; then
  kubectl -n kube-system delete pod -l k8s-app=metrics-server --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n kube-system rollout status deployment/metrics-server --timeout=300s
fi

wait_for_metrics_api

echo "Applying monitoring manifests..."
apply_monitoring_manifest
kubectl -n "${MONITORING_NAMESPACE}" rollout status deployment/kube-state-metrics --timeout=300s
kubectl -n "${MONITORING_NAMESPACE}" rollout status deployment/prometheus --timeout=300s
kubectl -n "${MONITORING_NAMESPACE}" rollout status deployment/grafana --timeout=300s

echo
echo "Monitoring pods:"
kubectl -n "${MONITORING_NAMESPACE}" get pods

echo
echo "Port-forward helpers:"
echo "  Grafana   : kubectl -n ${MONITORING_NAMESPACE} port-forward svc/grafana 13000:80"
echo "  Prometheus: kubectl -n ${MONITORING_NAMESPACE} port-forward svc/prometheus 19090:9090"
