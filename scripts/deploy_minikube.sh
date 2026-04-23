#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S_DIR="${K8S_DIR:-${ROOT_DIR}/deploy/minikube}"
NAMESPACE="${NAMESPACE:-flowboard}"

BUILD_LOCAL="${BUILD_LOCAL:-0}"
BUILD_OBSERVABILITY_LOCAL="${BUILD_OBSERVABILITY_LOCAL:-0}"
ENABLE_OBSERVABILITY="${ENABLE_OBSERVABILITY:-1}"
ENABLE_PORT_FORWARD="${ENABLE_PORT_FORWARD:-0}"
RUN_SMOKE_TEST="${RUN_SMOKE_TEST:-0}"
RUN_HPA_VALIDATION="${RUN_HPA_VALIDATION:-0}"
AUTO_START_MINIKUBE="${AUTO_START_MINIKUBE:-0}"
LOCAL_BUILD_STRATEGY="${LOCAL_BUILD_STRATEGY:-host-tools}"

MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-6144}"

BACKEND_IMAGE="${BACKEND_IMAGE:-ghcr.io/discipliny/dev_ops/backend:latest}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-ghcr.io/discipliny/dev_ops/frontend:latest}"
LOCAL_BACKEND_IMAGE="${LOCAL_BACKEND_IMAGE:-}"
LOCAL_FRONTEND_IMAGE="${LOCAL_FRONTEND_IMAGE:-}"
INIT_POSTGRES_IMAGE="${INIT_POSTGRES_IMAGE:-postgres:16-alpine}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
METRICS_SERVER_IMAGE="${METRICS_SERVER_IMAGE:-registry.k8s.io/metrics-server/metrics-server:v0.8.1}"
PROMETHEUS_IMAGE="${PROMETHEUS_IMAGE:-quay.io/prometheus/prometheus:v2.54.1}"
GRAFANA_IMAGE="${GRAFANA_IMAGE:-docker.io/grafana/grafana-oss:11.2.2}"
LOADGEN_IMAGE="${LOADGEN_IMAGE:-busybox:1.36}"
FRONTEND_NGINX_IMAGE="${FRONTEND_NGINX_IMAGE:-nginx:1.25-alpine}"
PROMETHEUS_RELEASE_VERSION="${PROMETHEUS_RELEASE_VERSION:-2.54.1}"
GRAFANA_RELEASE_VERSION="${GRAFANA_RELEASE_VERSION:-11.2.2}"
FRONTEND_LOCAL_PORT="${FRONTEND_LOCAL_PORT:-18081}"
BACKEND_LOCAL_PORT="${BACKEND_LOCAL_PORT:-18080}"
GRAFANA_LOCAL_PORT="${GRAFANA_LOCAL_PORT:-13000}"
PROMETHEUS_LOCAL_PORT="${PROMETHEUS_LOCAL_PORT:-19090}"

source "${ROOT_DIR}/scripts/lib_minikube.sh"

resolve_local_image_names() {
  if [[ -z "${LOCAL_BACKEND_IMAGE}" ]]; then
    LOCAL_BACKEND_IMAGE="flowboard-backend:local-$(compute_dir_hash "${ROOT_DIR}/backend")"
  fi

  if [[ -z "${LOCAL_FRONTEND_IMAGE}" ]]; then
    LOCAL_FRONTEND_IMAGE="flowboard-frontend:local-$(compute_dir_hash "${ROOT_DIR}/frontend")"
  fi
}

build_backend_image_with_host_tools() {
  build_backend_runtime_image_with_host_tools "${ROOT_DIR}" "${LOCAL_BACKEND_IMAGE}"
}

build_frontend_image_with_host_tools() {
  build_frontend_runtime_image_with_host_tools "${ROOT_DIR}" "${LOCAL_FRONTEND_IMAGE}" "${FRONTEND_NGINX_IMAGE}"
}

build_and_load_local_images() {
  require_cmd docker
  resolve_local_image_names

  case "${LOCAL_BUILD_STRATEGY}" in
    host-tools)
      build_backend_image_with_host_tools
      build_frontend_image_with_host_tools
      ;;
    *)
      echo "Error: unsupported LOCAL_BUILD_STRATEGY=${LOCAL_BUILD_STRATEGY}" >&2
      exit 1
      ;;
  esac

  load_image_into_minikube "${LOCAL_BACKEND_IMAGE}"
  load_image_into_minikube "${LOCAL_FRONTEND_IMAGE}"
  load_image_into_minikube "${POSTGRES_IMAGE}"
  load_image_into_minikube "${INIT_POSTGRES_IMAGE}"

  BACKEND_IMAGE="${LOCAL_BACKEND_IMAGE}"
  FRONTEND_IMAGE="${LOCAL_FRONTEND_IMAGE}"
}

ensure_runtime_images_available() {
  load_image_into_minikube "${BACKEND_IMAGE}"
  load_image_into_minikube "${FRONTEND_IMAGE}"
  load_image_into_minikube "${POSTGRES_IMAGE}"
  load_image_into_minikube "${INIT_POSTGRES_IMAGE}"
}

metrics_server_has_pull_error() {
  kubectl -n kube-system get pods -l k8s-app=metrics-server \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[*].state.waiting.reason}{"\n"}{end}' \
    2>/dev/null | grep -qE "ImagePullBackOff|ErrImagePull"
}

metrics_server_uses_digest_pin() {
  kubectl -n kube-system get deploy metrics-server \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
    | grep -q "@sha256:"
}

stabilize_metrics_server_image() {
  if metrics_server_uses_digest_pin || metrics_server_has_pull_error; then
    echo "Using locally loaded metrics-server image to avoid registry pull issues..."
    kubectl -n kube-system set image deploy/metrics-server "metrics-server=${METRICS_SERVER_IMAGE}" >/dev/null
  fi
}

ensure_metrics_server() {
  load_image_into_minikube "${METRICS_SERVER_IMAGE}"

  echo "Enabling metrics-server addon..."
  run_minikube addons enable metrics-server >/dev/null

  for _ in $(seq 1 15); do
    if kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  if kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q '^True$'; then
    return 0
  fi

  stabilize_metrics_server_image
  kubectl -n kube-system delete pod -l k8s-app=metrics-server --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n kube-system rollout status deployment/metrics-server --timeout=300s

  for _ in $(seq 1 30); do
    if kubectl top nodes >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done

  echo "Error: Metrics API did not become available." >&2
  exit 1
}

prepare_observability_images() {
  if [[ "${ENABLE_OBSERVABILITY}" != "1" || "${BUILD_OBSERVABILITY_LOCAL}" != "1" ]]; then
    return 0
  fi

  build_local_observability_images \
    "${PROMETHEUS_IMAGE}" \
    "${PROMETHEUS_RELEASE_VERSION}" \
    "${GRAFANA_IMAGE}" \
    "${GRAFANA_RELEASE_VERSION}"
}

apply_application_manifests() {
  kubectl apply -f "${K8S_DIR}/namespaces/namespace.yaml"

  kubectl_apply_if_changed "${K8S_DIR}/postgres/postgres.yaml" "postgres/postgres.yaml"
  apply_template_manifest "${K8S_DIR}/postgres/postgres-deployment.yaml"
  kubectl_apply_if_changed "${K8S_DIR}/postgres/postgres-service.yaml" "postgres/postgres-service.yaml"
  kubectl -n "${NAMESPACE}" rollout status deployment/postgres --timeout=300s

  apply_template_manifest "${K8S_DIR}/backend/backend-deployment.yaml"
  kubectl_apply_if_changed "${K8S_DIR}/backend/backend-service.yaml" "backend/backend-service.yaml"
  kubectl_apply_if_changed "${K8S_DIR}/backend/backend-hpa.yaml" "backend/backend-hpa.yaml"

  apply_template_manifest "${K8S_DIR}/frontend/frontend-deployment.yaml"
  kubectl_apply_if_changed "${K8S_DIR}/frontend/frontend-service.yaml" "frontend/frontend-service.yaml"
  kubectl_apply_if_changed "${K8S_DIR}/frontend/frontend-hpa.yaml" "frontend/frontend-hpa.yaml"

  kubectl -n "${NAMESPACE}" rollout status deployment/backend --timeout=300s
  kubectl -n "${NAMESPACE}" rollout status deployment/frontend --timeout=300s
}

setup_port_forwards() {
  if [[ "${ENABLE_PORT_FORWARD}" != "1" ]]; then
    return 0
  fi

  ensure_port_forward "frontend" "${NAMESPACE}" "frontend" "${FRONTEND_LOCAL_PORT}" 80 "/"
  ensure_port_forward "backend" "${NAMESPACE}" "backend" "${BACKEND_LOCAL_PORT}" 8080 "/health"

  if [[ "${ENABLE_OBSERVABILITY}" == "1" ]]; then
    ensure_port_forward "grafana" "monitoring" "grafana" "${GRAFANA_LOCAL_PORT}" 80 "/api/health"
    ensure_port_forward "prometheus" "monitoring" "prometheus" "${PROMETHEUS_LOCAL_PORT}" 9090 "/-/healthy"
  fi
}

print_status() {
  echo
  echo "Kubernetes resources in namespace ${NAMESPACE}:"
  kubectl -n "${NAMESPACE}" get pods,svc,hpa

  echo
  if [[ "${ENABLE_PORT_FORWARD}" == "1" ]]; then
    echo "Active local endpoints:"
    echo "  Frontend  : http://127.0.0.1:${FRONTEND_LOCAL_PORT}"
    echo "  Backend   : http://127.0.0.1:${BACKEND_LOCAL_PORT}"
    if [[ "${ENABLE_OBSERVABILITY}" == "1" ]]; then
      echo "  Grafana   : http://127.0.0.1:${GRAFANA_LOCAL_PORT}"
      echo "  Prometheus: http://127.0.0.1:${PROMETHEUS_LOCAL_PORT}"
    fi
  else
    echo "Port-forward helpers:"
    echo "  Frontend  : kubectl -n ${NAMESPACE} port-forward svc/frontend ${FRONTEND_LOCAL_PORT}:80"
    echo "  Backend   : kubectl -n ${NAMESPACE} port-forward svc/backend ${BACKEND_LOCAL_PORT}:8080"
    echo "  Grafana   : kubectl -n monitoring port-forward svc/grafana ${GRAFANA_LOCAL_PORT}:80"
    echo "  Prometheus: kubectl -n monitoring port-forward svc/prometheus ${PROMETHEUS_LOCAL_PORT}:9090"
  fi
}

require_cmd minikube
require_cmd kubectl
require_cmd docker

ensure_minikube_running "${AUTO_START_MINIKUBE}" "${MINIKUBE_DRIVER}" "${MINIKUBE_CPUS}" "${MINIKUBE_MEMORY}"

if [[ "${BUILD_LOCAL}" == "1" ]]; then
  build_and_load_local_images
else
  ensure_runtime_images_available
fi

prepare_observability_images

ensure_metrics_server

if [[ "${ENABLE_OBSERVABILITY}" == "1" ]]; then
  "${ROOT_DIR}/scripts/enable_observability_minikube.sh"
fi

apply_application_manifests
setup_port_forwards
print_status

if [[ "${RUN_SMOKE_TEST}" == "1" ]]; then
  if [[ "${ENABLE_PORT_FORWARD}" == "1" ]]; then
    FRONTEND_URL="http://127.0.0.1:${FRONTEND_LOCAL_PORT}" "${ROOT_DIR}/scripts/smoke_test_minikube.sh"
  else
    "${ROOT_DIR}/scripts/smoke_test_minikube.sh"
  fi
fi

if [[ "${RUN_HPA_VALIDATION}" == "1" ]]; then
  load_image_into_minikube "${LOADGEN_IMAGE}"
  LOADGEN_IMAGE="${LOADGEN_IMAGE}" "${ROOT_DIR}/scripts/load_test_backend_hpa.sh"
fi
