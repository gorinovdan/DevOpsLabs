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

# Use --core mode so argocd CLI talks directly to the cluster API rather
# than requiring a logged-in argocd-server session over HTTPS.
ARGO_FLAGS=(--core --grpc-web --plaintext)

echo "Updating image overrides on Argo CD Application '${APP_NAME}'..."
"${ARGOCD_BIN}" app set "${APP_NAME}" \
  "${ARGO_FLAGS[@]}" \
  --kustomize-image "ghcr.io/gorinovdan/devopslabs/backend=${BACKEND_IMAGE}" \
  --kustomize-image "ghcr.io/gorinovdan/devopslabs/frontend=${FRONTEND_IMAGE}"

echo "Triggering Argo CD sync for '${APP_NAME}'..."
"${ARGOCD_BIN}" app sync "${APP_NAME}" \
  "${ARGO_FLAGS[@]}" \
  --prune \
  --timeout "${ARGOCD_SYNC_TIMEOUT}"

echo "Waiting for Argo CD Application '${APP_NAME}' to become Healthy..."
"${ARGOCD_BIN}" app wait "${APP_NAME}" \
  "${ARGO_FLAGS[@]}" \
  --health \
  --sync \
  --timeout "${ARGOCD_SYNC_TIMEOUT}"

echo
echo "Argo CD sync completed. Application status:"
"${ARGOCD_BIN}" app get "${APP_NAME}" "${ARGO_FLAGS[@]}"
