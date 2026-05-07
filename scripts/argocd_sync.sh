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
ARGOCD_BIN="${ARGOCD_BIN:-argocd}"
ARGOCD_SYNC_TIMEOUT="${ARGOCD_SYNC_TIMEOUT:-600}"

source "${ROOT_DIR}/scripts/lib_minikube.sh"

require_cmd kubectl

if ! command -v "${ARGOCD_BIN}" >/dev/null 2>&1; then
  echo "Error: argocd CLI not found on PATH. Install via 'brew install argocd' or set ARGOCD_BIN." >&2
  exit 1
fi

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

# Use --core mode so argocd CLI talks directly to the cluster API rather
# than requiring a logged-in argocd-server session over HTTPS.
ARGO_FLAGS=(--core --grpc-web --plaintext)

# argocd --core reads argocd-cm from the kubeconfig's current namespace,
# so point at argocd for the duration of the sync.
PRIOR_NS="$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || true)"
kubectl config set-context --current --namespace="${ARGOCD_NAMESPACE}" >/dev/null
restore_namespace() {
  if [[ -n "${PRIOR_NS}" ]]; then
    kubectl config set-context --current --namespace="${PRIOR_NS}" >/dev/null 2>&1 || true
  else
    kubectl config set-context --current --namespace=default >/dev/null 2>&1 || true
  fi
}
trap restore_namespace EXIT

# argocd CLI talks to the local cluster (kubernetes.default.svc), but the
# host shell may have HTTP/SOCKS proxy env set for outbound traffic. Strip
# proxy so argocd does not tunnel cluster API calls through it.
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy

# In --core mode the argocd CLI runs an in-process argocd-server. Its
# default 60s gRPC deadline to the in-cluster argocd-repo-server is too
# tight: every `app set --kustomize-image <new SHA>` triggers a fresh
# kustomize render through host proxy that takes 60-90s. Bump to 300s so
# cold renders no longer fail with DeadlineExceeded. (Cluster-side
# argocd-server is already patched to the same value via install_argocd.)
export ARGOCD_SERVER_REPO_SERVER_TIMEOUT_SECONDS="${ARGOCD_SERVER_REPO_SERVER_TIMEOUT_SECONDS:-300}"

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

# The Application has syncPolicy.automated.{prune,selfHeal}=true so the
# argocd-application-controller picks up the new spec automatically and
# reconciles within seconds. Calling `argocd app sync` explicitly would
# hit the same gRPC deadline that broke `app set`, and would block for
# 10+ minutes on ComparisonError when the repo-server's local git
# checkout is in a transient bad state. Trust the controller instead.

echo "Waiting for Argo CD Application '${APP_NAME}' to become Healthy..."
# We only wait for --health here. Argo CD's comparator can mark Deployments
# OutOfSync due to schema-level differences (e.g. terminatingReplicas added
# in newer apiserver) even when the live state matches the rendered manifest
# byte-for-byte; the --sync wait then loops indefinitely for those false
# positives. Health is the authoritative signal that the workloads are up.
#
# Retry the argocd CLI call: it has a strict selector check that fails
# with "cannot find ready pod" if argocd-repo-server is mid-rollout
# even though `kubectl rollout status` already returned OK. A few-second
# wait clears the race.
wait_attempts=5
for attempt in $(seq 1 "${wait_attempts}"); do
  if "${ARGOCD_BIN}" app wait "${APP_NAME}" \
       "${ARGO_FLAGS[@]}" \
       --health \
       --timeout "${ARGOCD_SYNC_TIMEOUT}"; then
    break
  fi
  if [[ "${attempt}" -eq "${wait_attempts}" ]]; then
    echo "Error: 'argocd app wait --health' failed after ${wait_attempts} attempts." >&2
    exit 1
  fi
  echo "  app wait attempt ${attempt} failed (likely repo-server pod transitioning), retrying in 10s..."
  sleep 10
done

echo
echo "Argo CD sync completed. Application status:"
"${ARGOCD_BIN}" app get "${APP_NAME}" "${ARGO_FLAGS[@]}"
