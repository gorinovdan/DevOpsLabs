#!/usr/bin/env bash
set -euo pipefail

# Trigger a sync of the FlowBoard Argo CD Application using the argocd
# CLI in --core mode (talks to the cluster directly via kubectl context).
#
# Required environment variables:
#   BACKEND_IMAGE  - full image reference (registry/path:tag) for backend
#   FRONTEND_IMAGE - full image reference (registry/path:tag) for frontend

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAME="${ARGOCD_APP_NAME:-flowboard}"
BACKEND_IMAGE="${BACKEND_IMAGE:?BACKEND_IMAGE is required}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:?FRONTEND_IMAGE is required}"
ARGOCD_SYNC_TIMEOUT="${ARGOCD_SYNC_TIMEOUT:-600}"

source "${ROOT_DIR}/scripts/lib_minikube.sh"

require_cmd kubectl

echo "Verifying Application '${APP_NAME}' exists..."
if ! kubectl -n "${ARGOCD_NAMESPACE}" get application.argoproj.io "${APP_NAME}" >/dev/null 2>&1; then
  echo "Error: Argo CD Application '${APP_NAME}' is not registered. Run scripts/install_argocd.sh first." >&2
  exit 1
fi

# argocd --core delegates manifest rendering to argocd-repo-server pod.
# Wait until each Argo CD workload has at least one Ready replica, otherwise
# CLI commands fail with "cannot find ready pod with selector ...". The
# 360s timeout absorbs upstream quay.io 502s during ImagePullBackOff
# retries while the kubelet falls back to the locally preloaded image.
echo "Waiting for Argo CD core pods to become Ready..."
for d in argocd-repo-server argocd-application-controller argocd-server argocd-redis; do
  if kubectl -n "${ARGOCD_NAMESPACE}" get deploy "${d}" >/dev/null 2>&1; then
    kubectl -n "${ARGOCD_NAMESPACE}" rollout status "deploy/${d}" --timeout=360s
  elif kubectl -n "${ARGOCD_NAMESPACE}" get statefulset "${d}" >/dev/null 2>&1; then
    kubectl -n "${ARGOCD_NAMESPACE}" rollout status "statefulset/${d}" --timeout=360s
  fi
done

# The host shell may have HTTP/SOCKS proxy env set for outbound traffic.
# Strip proxy so kubectl does not tunnel local cluster API calls through it.
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy

# Patch the Application's kustomize image overrides directly via the
# Kubernetes API. `argocd app set --kustomize-image` runs validation
# server-side which has a hardcoded ~90s gRPC deadline to repo-server,
# and the first cold render after a deploy reliably exceeds that. A
# direct kubectl patch updates spec.source.kustomize.images instantly;
# the application controller does the kustomize build asynchronously
# during the next reconcile loop with no client-side deadline.
echo "Patching Argo CD Application '${APP_NAME}' kustomize image overrides..."
kubectl -n "${ARGOCD_NAMESPACE}" patch application "${APP_NAME}" --type=merge -p "$(cat <<EOF
{"spec":{"source":{"kustomize":{"images":["ghcr.io/gorinovdan/devopslabs/backend=${BACKEND_IMAGE}","ghcr.io/gorinovdan/devopslabs/frontend=${FRONTEND_IMAGE}"]}}}}
EOF
)"
kubectl -n "${ARGOCD_NAMESPACE}" annotate application "${APP_NAME}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null

# The Application has syncPolicy.automated.{prune,selfHeal}=true so the
# argocd-application-controller picks up the new spec automatically and
# reconciles within seconds. Calling `argocd app sync` explicitly would
# hit the same gRPC deadline that broke `app set`, and would block for
# 10+ minutes on ComparisonError when the repo-server's local git
# checkout is in a transient bad state. Trust the controller instead.

echo "Waiting for Argo CD Application '${APP_NAME}' to become Healthy..."
deadline=$((SECONDS + ARGOCD_SYNC_TIMEOUT))
while (( SECONDS < deadline )); do
  health="$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  sync="$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  phase="$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
  backend_live="$(kubectl -n flowboard get deployment backend -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  frontend_live="$(kubectl -n flowboard get deployment frontend -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"

  if [[ "${health}" == "Healthy" \
     && "${sync}" == "Synced" \
     && "${phase}" != "Running" \
     && "${backend_live}" == "${BACKEND_IMAGE}" \
     && "${frontend_live}" == "${FRONTEND_IMAGE}" ]]; then
    kubectl -n flowboard rollout status deploy/backend --timeout=120s
    kubectl -n flowboard rollout status deploy/frontend --timeout=120s
    break
  fi

  echo "  status: health=${health:-unknown}, sync=${sync:-unknown}, phase=${phase:-unknown}, backend=${backend_live:-missing}, frontend=${frontend_live:-missing}"
  sleep 10
done

if (( SECONDS >= deadline )); then
  echo "Error: Application '${APP_NAME}' did not converge within ${ARGOCD_SYNC_TIMEOUT}s." >&2
  kubectl -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" -o yaml >&2 || true
  kubectl -n flowboard get deploy,pods -o wide >&2 || true
  exit 1
fi

echo
echo "Argo CD sync completed. Application status:"
kubectl -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" -o wide
