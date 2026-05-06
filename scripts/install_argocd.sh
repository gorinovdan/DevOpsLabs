#!/usr/bin/env bash
set -euo pipefail

# Install Argo CD into the minikube cluster and bootstrap the FlowBoard
# AppProject and Application. Requires kubectl context pointing at minikube.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.13.1}"
ARGOCD_INSTALL_MANIFEST="${ARGOCD_INSTALL_MANIFEST:-https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml}"
ARGOCD_LOCAL_PORT="${ARGOCD_LOCAL_PORT:-18083}"
ARGOCD_BOOTSTRAP_DIR="${ARGOCD_BOOTSTRAP_DIR:-${ROOT_DIR}/deploy/argocd/bootstrap}"
ARGOCD_FORCE_INSECURE="${ARGOCD_FORCE_INSECURE:-1}"

source "${ROOT_DIR}/scripts/lib_minikube.sh"

require_cmd kubectl

ensure_argocd_cli() {
  if command -v argocd >/dev/null 2>&1; then
    return 0
  fi

  echo "argocd CLI not on PATH, installing..."
  case "$(uname -s)" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install argocd
        return 0
      fi
      ;;
  esac

  local arch="$(uname -m)"
  case "${arch}" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=amd64 ;;
    *) echo "Error: unsupported arch ${arch} for argocd CLI install." >&2; exit 1 ;;
  esac
  local os="linux"
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) echo "Error: unsupported OS for argocd CLI install." >&2; exit 1 ;;
  esac

  local target="/usr/local/bin/argocd"
  if [[ ! -w "$(dirname "${target}")" ]]; then
    target="${HOME}/.local/bin/argocd"
    mkdir -p "$(dirname "${target}")"
    case ":${PATH}:" in
      *":$(dirname "${target}"):"*) ;;
      *) export PATH="$(dirname "${target}"):${PATH}" ;;
    esac
  fi

  curl -fsSL -o "${target}" "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-${os}-${arch}"
  chmod +x "${target}"
  echo "Installed argocd CLI at ${target}"
}

ensure_namespace() {
  if ! kubectl get namespace "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
    echo "Creating namespace ${ARGOCD_NAMESPACE}..."
    kubectl create namespace "${ARGOCD_NAMESPACE}"
  fi
}

preload_argocd_images_into_minikube() {
  if ! command -v minikube >/dev/null 2>&1; then
    return 0
  fi

  # Some networks (corporate proxies, VPNs) block in-cluster pulls from
  # quay.io / ghcr.io / docker.io. Pre-loading the images on the host
  # docker daemon and then `minikube image load` works around that.
  local images=(
    "${ARGOCD_CORE_IMAGE:-quay.io/argoproj/argocd:${ARGOCD_VERSION}}"
    "${ARGOCD_DEX_IMAGE:-ghcr.io/dexidp/dex:v2.41.1}"
    "${ARGOCD_REDIS_IMAGE:-redis:7.0.15-alpine}"
  )
  local img
  for img in "${images[@]}"; do
    echo "Pre-loading Argo CD image into minikube: ${img}"
    if ! load_image_into_minikube "${img}"; then
      echo "Error: failed to preload Argo CD image into minikube: ${img}" >&2
      exit 1
    fi
  done

  echo "Argo CD images now in minikube docker:"
  eval "$(minikube -p minikube docker-env --shell bash)"
  for img in "${images[@]}"; do
    if docker image inspect "${img}" >/dev/null 2>&1; then
      echo "  ✓ ${img}"
    else
      echo "  ✗ ${img} (missing!)"
      exit 1
    fi
  done
}

install_argocd_components() {
  if kubectl -n "${ARGOCD_NAMESPACE}" get deploy argocd-server >/dev/null 2>&1; then
    echo "Argo CD already installed in namespace ${ARGOCD_NAMESPACE}, skipping bulk install."
    return 0
  fi

  preload_argocd_images_into_minikube

  echo "Applying Argo CD manifests from ${ARGOCD_INSTALL_MANIFEST}..."
  kubectl apply -n "${ARGOCD_NAMESPACE}" -f "${ARGOCD_INSTALL_MANIFEST}"
}

wait_for_argocd_ready() {
  echo "Waiting for Argo CD core components to roll out..."
  for d in argocd-server argocd-repo-server argocd-application-controller argocd-applicationset-controller argocd-redis argocd-dex-server argocd-notifications-controller; do
    if kubectl -n "${ARGOCD_NAMESPACE}" get deploy "${d}" >/dev/null 2>&1; then
      kubectl -n "${ARGOCD_NAMESPACE}" rollout status "deploy/${d}" --timeout=300s || true
    elif kubectl -n "${ARGOCD_NAMESPACE}" get statefulset "${d}" >/dev/null 2>&1; then
      kubectl -n "${ARGOCD_NAMESPACE}" rollout status "statefulset/${d}" --timeout=300s || true
    fi
  done
}

configure_insecure_server() {
  if [[ "${ARGOCD_FORCE_INSECURE}" != "1" ]]; then
    return 0
  fi

  echo "Configuring argocd-server to serve plain HTTP for local minikube use..."
  kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cmd-params-cm \
    --type merge \
    -p '{"data":{"server.insecure":"true"}}'
  kubectl -n "${ARGOCD_NAMESPACE}" rollout restart deployment argocd-server >/dev/null
  kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment argocd-server --timeout=300s || true
}

apply_bootstrap_manifests() {
  echo "Applying FlowBoard AppProject..."
  kubectl apply -f "${ARGOCD_BOOTSTRAP_DIR}/project.yaml"
  echo "Applying FlowBoard Application..."
  kubectl apply -f "${ARGOCD_BOOTSTRAP_DIR}/application.yaml"
}

setup_local_port_forward() {
  if [[ "${ENABLE_PORT_FORWARD:-1}" != "1" ]]; then
    return 0
  fi

  ensure_port_forward "argocd" "${ARGOCD_NAMESPACE}" "argocd-server" "${ARGOCD_LOCAL_PORT}" 80 "/healthz"
}

print_initial_credentials() {
  if ! kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret >/dev/null 2>&1; then
    return 0
  fi

  local password
  password="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
  echo
  echo "Argo CD UI:       http://127.0.0.1:${ARGOCD_LOCAL_PORT}"
  echo "Argo CD username: admin"
  echo "Argo CD password: ${password}"
  echo
}

ensure_argocd_cli
ensure_namespace
install_argocd_components
wait_for_argocd_ready
configure_insecure_server
apply_bootstrap_manifests
setup_local_port_forward
print_initial_credentials
