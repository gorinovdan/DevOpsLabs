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
  # Idempotent: kubectl apply against a synthesized Namespace manifest is
  # safe whether or not it exists, and survives the transient apiserver
  # EOFs the docker-driver minikube emits during cluster restarts.
  for attempt in 1 2 3; do
    if kubectl create namespace "${ARGOCD_NAMESPACE}" --dry-run=client -o yaml \
         | kubectl apply -f - >/dev/null 2>&1; then
      return 0
    fi
    echo "ensure_namespace: apiserver hiccup, retrying in 5s (attempt ${attempt}/3)..." >&2
    sleep 5
  done
  echo "Error: could not create/verify namespace ${ARGOCD_NAMESPACE}" >&2
  return 1
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
  preload_argocd_images_into_minikube

  if ! kubectl -n "${ARGOCD_NAMESPACE}" get deploy argocd-server >/dev/null 2>&1; then
    echo "Applying Argo CD manifests from ${ARGOCD_INSTALL_MANIFEST}..."
    kubectl_retry 3 -- kubectl apply -n "${ARGOCD_NAMESPACE}" -f "${ARGOCD_INSTALL_MANIFEST}"
    configure_argocd_workloads_proxy
  else
    echo "Argo CD already installed in namespace ${ARGOCD_NAMESPACE}, skipping bulk install."
  fi

  # Always (re)apply: upstream manifest defaults imagePullPolicy=Always for
  # every workload, which means a transient 502 from quay.io blocks every
  # rollout — kubelet does a HEAD digest check before honoring local cache.
  # Switching to IfNotPresent makes Argo CD pods reuse the image we just
  # preloaded into minikube and survives upstream registry hiccups.
  patch_argocd_image_pull_policy
}

patch_argocd_image_pull_policy() {
  local d current
  local need_patch=0
  for d in argocd-server argocd-repo-server argocd-applicationset-controller \
           argocd-notifications-controller argocd-dex-server; do
    current="$(kubectl -n "${ARGOCD_NAMESPACE}" get deploy "${d}" \
      -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}' 2>/dev/null || true)"
    if [[ -n "${current}" && "${current}" != "IfNotPresent" ]]; then
      need_patch=1
      break
    fi
  done
  if [[ "${need_patch}" == "0" ]]; then
    current="$(kubectl -n "${ARGOCD_NAMESPACE}" get statefulset argocd-application-controller \
      -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}' 2>/dev/null || true)"
    if [[ -n "${current}" && "${current}" != "IfNotPresent" ]]; then
      need_patch=1
    fi
  fi

  if [[ "${need_patch}" == "0" ]]; then
    echo "Argo CD workloads already have imagePullPolicy=IfNotPresent, skipping patch."
  else
    echo "Setting imagePullPolicy=IfNotPresent on Argo CD workloads..."
    for d in argocd-server argocd-repo-server argocd-applicationset-controller \
             argocd-notifications-controller argocd-dex-server; do
      if kubectl -n "${ARGOCD_NAMESPACE}" get deploy "${d}" >/dev/null 2>&1; then
        kubectl -n "${ARGOCD_NAMESPACE}" patch deploy "${d}" --type=json \
          -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' \
          >/dev/null 2>&1 || true
      fi
    done
    if kubectl -n "${ARGOCD_NAMESPACE}" get statefulset argocd-application-controller >/dev/null 2>&1; then
      kubectl -n "${ARGOCD_NAMESPACE}" patch statefulset argocd-application-controller --type=json \
        -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' \
        >/dev/null 2>&1 || true
    fi
  fi

  # Pods already in ImagePullBackOff retain the old policy in their spec.
  # Force-delete them so the new ReplicaSet uses the patched template.
  # When the cluster is healthy this matches zero pods and is a no-op.
  local stuck
  stuck="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods --no-headers 2>/dev/null \
    | awk '$3 ~ /ImagePullBackOff|ErrImagePull/ {print $1}')"
  if [[ -n "${stuck}" ]]; then
    echo "Force-deleting stuck pods: ${stuck}"
    printf '%s\n' "${stuck}" | xargs -n 1 kubectl -n "${ARGOCD_NAMESPACE}" delete pod --grace-period=0 --force --wait=false >/dev/null 2>&1 || true
  fi
}

# Argo CD's repo-server pod clones the application's git repo. On a
# host that needs an HTTP proxy to reach github.com, the repo-server
# pod has to use the same proxy. Inject HTTP/HTTPS_PROXY into the
# argocd-repo-server, argocd-application-controller and
# argocd-server deployments / statefulsets via a strategic merge patch.
configure_argocd_workloads_proxy() {
  local raw_proxy="${HTTP_PROXY:-${HTTPS_PROXY:-${http_proxy:-${https_proxy:-}}}}"
  if [[ -z "${raw_proxy}" ]]; then
    return 0
  fi

  if [[ "${raw_proxy}" != http://* && "${raw_proxy}" != https://* ]]; then
    return 0
  fi

  local rewritten="${raw_proxy//127.0.0.1/host.docker.internal}"
  rewritten="${rewritten//localhost/host.docker.internal}"
  local no_proxy="localhost,127.0.0.1,::1,.svc,.svc.cluster.local,kubernetes.default.svc,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

  echo "Injecting HTTP_PROXY=${rewritten} into argocd-repo-server (git clone path)..."

  # Only the repo-server needs outbound HTTP/HTTPS access to clone the
  # application git repository. Setting it on the controller / server
  # would also tunnel intra-cluster gRPC through the host proxy, which
  # breaks the TLS handshake between application-controller and
  # repo-server.
  kubectl -n "${ARGOCD_NAMESPACE}" set env deployment/argocd-repo-server \
    "HTTP_PROXY=${rewritten}" \
    "HTTPS_PROXY=${rewritten}" \
    "NO_PROXY=${no_proxy}" >/dev/null
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

  # Read current configmap; only patch + restart workloads when something
  # actually changes. Re-running install on a fully-configured cluster
  # was firing two sequential rollouts (argocd-server, app-controller)
  # adding ~60s for nothing.
  local current insecure srv_timeout ctrl_timeout
  current="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cmd-params-cm -o json 2>/dev/null || echo '{}')"
  insecure="$(printf '%s' "${current}" | jq -r '.data["server.insecure"] // ""')"
  srv_timeout="$(printf '%s' "${current}" | jq -r '.data["server.repo.server.timeout.seconds"] // ""')"
  ctrl_timeout="$(printf '%s' "${current}" | jq -r '.data["controller.repo.server.timeout.seconds"] // ""')"
  if [[ "${insecure}" == "true" && "${srv_timeout}" == "300" && "${ctrl_timeout}" == "300" ]]; then
    echo "Argo CD argocd-cmd-params-cm already configured, skipping restart."
    return 0
  fi

  echo "Configuring argocd-server (insecure HTTP + 300s repo-server timeout)..."
  # The default 60s deadline on argocd-server -> argocd-repo-server RPC is
  # too tight for cold renders that take 60-90s. 300s leaves headroom.
  kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cmd-params-cm \
    --type merge \
    -p '{"data":{"server.insecure":"true","server.repo.server.timeout.seconds":"300","controller.repo.server.timeout.seconds":"300"}}'
  kubectl -n "${ARGOCD_NAMESPACE}" rollout restart deployment argocd-server >/dev/null
  kubectl -n "${ARGOCD_NAMESPACE}" rollout restart statefulset argocd-application-controller >/dev/null 2>&1 || true
  kubectl -n "${ARGOCD_NAMESPACE}" rollout status deployment argocd-server --timeout=300s || true
}

apply_bootstrap_manifests() {
  echo "Applying FlowBoard AppProject..."
  kubectl_retry 3 -- kubectl apply -f "${ARGOCD_BOOTSTRAP_DIR}/project.yaml"
  echo "Applying FlowBoard Application..."
  kubectl_retry 3 -- kubectl apply -f "${ARGOCD_BOOTSTRAP_DIR}/application.yaml"
  if [[ -f "${ARGOCD_BOOTSTRAP_DIR}/application-sonarqube.yaml" ]]; then
    echo "Applying SonarQube Application..."
    kubectl_retry 3 -- kubectl apply -f "${ARGOCD_BOOTSTRAP_DIR}/application-sonarqube.yaml"
  fi
}

setup_local_port_forward() {
  if [[ "${ENABLE_PORT_FORWARD:-1}" != "1" ]]; then
    return 0
  fi

  # Skip the /healthz wait: argocd-server's readiness probe already passed
  # by the time we reach here, and the wait_for_http_endpoint default of
  # 90 attempts × 3s burned 4.5 min on hot cluster runs when the port-
  # forward briefly hiccupped. The argocd-deploy job re-establishes this
  # forward at the end with the same listener-only semantics.
  ensure_port_forward "argocd" "${ARGOCD_NAMESPACE}" "argocd-server" "${ARGOCD_LOCAL_PORT}" 80
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
