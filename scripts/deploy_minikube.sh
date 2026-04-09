#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S_DIR="${K8S_DIR:-${ROOT_DIR}/deploy/k8s}"
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
KUBE_STATE_METRICS_IMAGE="${KUBE_STATE_METRICS_IMAGE:-registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0}"
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
  local backend_context

  if docker image inspect "${LOCAL_BACKEND_IMAGE}" >/dev/null 2>&1; then
    echo "Using cached backend image: ${LOCAL_BACKEND_IMAGE}"
    return 0
  fi

  require_cmd go

  backend_context="$(mktemp -d)"
  trap 'rm -rf "${backend_context}"' RETURN

  echo "Building backend binary on host..."
  (
    cd "${ROOT_DIR}/backend"
    CGO_ENABLED=0 GOOS=linux GOARCH="$(go env GOARCH)" go build -trimpath -ldflags="-s -w" -o "${backend_context}/server" ./cmd/server
  )

  cat > "${backend_context}/Dockerfile" <<'EOF'
FROM scratch
COPY server /server
ENV PORT=8080
EXPOSE 8080
USER 10001:10001
ENTRYPOINT ["/server"]
EOF

  echo "Packaging backend runtime image: ${LOCAL_BACKEND_IMAGE}"
  docker build -t "${LOCAL_BACKEND_IMAGE}" "${backend_context}" >/dev/null

  trap - RETURN
  rm -rf "${backend_context}"
}

build_frontend_image_with_host_tools() {
  local frontend_context

  if docker image inspect "${LOCAL_FRONTEND_IMAGE}" >/dev/null 2>&1; then
    echo "Using cached frontend image: ${LOCAL_FRONTEND_IMAGE}"
    return 0
  fi

  require_cmd npm

  if [[ ! -d "${ROOT_DIR}/frontend/node_modules" ]]; then
    echo "Installing frontend dependencies..."
    (cd "${ROOT_DIR}/frontend" && npm ci --prefer-offline >/dev/null)
  fi

  echo "Building frontend assets on host..."
  (cd "${ROOT_DIR}/frontend" && npm run build >/dev/null)

  frontend_context="$(mktemp -d)"
  trap 'rm -rf "${frontend_context}"' RETURN

  cp "${ROOT_DIR}/frontend/nginx.conf" "${frontend_context}/nginx.conf"
  cp -R "${ROOT_DIR}/frontend/dist" "${frontend_context}/dist"

  cat > "${frontend_context}/Dockerfile" <<EOF
FROM ${FRONTEND_NGINX_IMAGE}
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY dist /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
EOF

  echo "Packaging frontend runtime image: ${LOCAL_FRONTEND_IMAGE}"
  docker build -t "${LOCAL_FRONTEND_IMAGE}" "${frontend_context}" >/dev/null

  trap - RETURN
  rm -rf "${frontend_context}"
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

ensure_metrics_server() {
  load_image_into_minikube "${METRICS_SERVER_IMAGE}"

  echo "Enabling metrics-server addon..."
  minikube addons enable metrics-server >/dev/null

  if kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q '^True$'; then
    return 0
  fi

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

apply_template_manifest() {
  local template_path="$1"
  local rendered_path

  rendered_path="$(mktemp)"
  trap 'rm -f "${rendered_path}"' RETURN
  render_template_file "${template_path}" "${rendered_path}"
  kubectl_apply_if_changed "${rendered_path}" "${template_path}"
  trap - RETURN
  rm -f "${rendered_path}"
}

apply_application_manifests() {
  kubectl apply -f "${K8S_DIR}/namespace.yaml"
  apply_template_manifest "${K8S_DIR}/postgres.yaml"
  kubectl -n "${NAMESPACE}" rollout status deployment/postgres --timeout=300s

  apply_template_manifest "${K8S_DIR}/backend.yaml"
  apply_template_manifest "${K8S_DIR}/frontend.yaml"
  kubectl_apply_if_changed "${K8S_DIR}/backend-hpa.yaml" "${K8S_DIR}/backend-hpa.yaml"
  kubectl_apply_if_changed "${K8S_DIR}/frontend-hpa.yaml" "${K8S_DIR}/frontend-hpa.yaml"

  kubectl -n "${NAMESPACE}" rollout status deployment/backend --timeout=300s
  kubectl -n "${NAMESPACE}" rollout status deployment/frontend --timeout=300s
}

setup_port_forwards() {
  if [[ "${ENABLE_PORT_FORWARD}" != "1" ]]; then
    return 0
  fi

  ensure_port_forward "frontend" "${NAMESPACE}" "frontend" "${FRONTEND_LOCAL_PORT}" 80
  ensure_port_forward "backend" "${NAMESPACE}" "backend" "${BACKEND_LOCAL_PORT}" 8080

  if [[ "${ENABLE_OBSERVABILITY}" == "1" ]]; then
    ensure_port_forward "grafana" "monitoring" "grafana" "${GRAFANA_LOCAL_PORT}" 80
    ensure_port_forward "prometheus" "monitoring" "prometheus" "${PROMETHEUS_LOCAL_PORT}" 9090
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
