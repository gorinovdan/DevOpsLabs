#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${ROOT_DIR}/scripts/lib_minikube.sh"

GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-gorinovdan/DevOpsLabs}"
GITHUB_SHA="${GITHUB_SHA:-$(git -C "${ROOT_DIR}" rev-parse HEAD)}"
REPO_LC="${REPO_LC:-$(printf '%s' "${GITHUB_REPOSITORY}" | tr '[:upper:]' '[:lower:]')}"

RUN_BACKEND="${RUN_BACKEND:-1}"
RUN_FRONTEND="${RUN_FRONTEND:-1}"
RUN_DEPLOY="${RUN_DEPLOY:-1}"
RUN_PUBLISH="${RUN_PUBLISH:-1}"
RUN_OBSERVABILITY_VERIFY="${RUN_OBSERVABILITY_VERIFY:-1}"
RUN_HPA_VALIDATION="${RUN_HPA_VALIDATION:-0}"
ENABLE_PORT_FORWARD="${ENABLE_PORT_FORWARD:-1}"

BACKEND_LATEST_IMAGE="${BACKEND_LATEST_IMAGE:-ghcr.io/${REPO_LC}/backend:latest}"
FRONTEND_LATEST_IMAGE="${FRONTEND_LATEST_IMAGE:-ghcr.io/${REPO_LC}/frontend:latest}"
BACKEND_SHA_IMAGE="${BACKEND_SHA_IMAGE:-ghcr.io/${REPO_LC}/backend:${GITHUB_SHA}}"
FRONTEND_SHA_IMAGE="${FRONTEND_SHA_IMAGE:-ghcr.io/${REPO_LC}/frontend:${GITHUB_SHA}}"
FRONTEND_NGINX_IMAGE="${FRONTEND_NGINX_IMAGE:-nginx:1.25-alpine}"

should_run() {
  [[ "${1}" == "1" ]]
}

ensure_runner_toolchain() {
  local cmd

  for cmd in bash git docker kubectl minikube curl tar python3 go node npm; do
    require_cmd "${cmd}"
  done
}

print_versions() {
  echo "Using toolchain:"
  echo "  go      : $(go version)"
  echo "  node    : $(node --version)"
  echo "  npm     : $(npm --version)"
  echo "  docker  : $(docker --version | head -n 1)"
  echo "  kubectl : $(kubectl version --client=true --output=yaml 2>/dev/null | awk -F': ' '/gitVersion:/ {print $2; exit}')"
  echo "  minikube: $(minikube version --short 2>/dev/null || minikube version | head -n 1)"
}

validate_backend() {
  if ! should_run "${RUN_BACKEND}"; then
    echo "Skipping backend validation."
    return 0
  fi

  echo "Running backend tests..."
  (
    cd "${ROOT_DIR}/backend"
    go test -race -covermode=atomic -coverprofile=coverage.out ./...
  )

  echo "Running backend build..."
  (
    cd "${ROOT_DIR}/backend"
    go build ./...
  )
}

validate_frontend() {
  if ! should_run "${RUN_FRONTEND}"; then
    echo "Skipping frontend validation."
    return 0
  fi

  ensure_frontend_dependencies "${ROOT_DIR}/frontend"

  echo "Running frontend tests..."
  (
    cd "${ROOT_DIR}/frontend"
    npm test
  )

  echo "Running frontend build..."
  (
    cd "${ROOT_DIR}/frontend"
    npm run build
  )
}

build_backend_image() {
  if ! should_run "${RUN_BACKEND}"; then
    echo "Skipping backend image build."
    return 0
  fi

  if docker image inspect "${BACKEND_SHA_IMAGE}" >/dev/null 2>&1; then
    echo "Reusing cached backend image: ${BACKEND_SHA_IMAGE}"
    docker tag "${BACKEND_SHA_IMAGE}" "${BACKEND_LATEST_IMAGE}"
    return 0
  fi

  build_backend_runtime_image_with_host_tools "${ROOT_DIR}" "${BACKEND_SHA_IMAGE}"
  docker tag "${BACKEND_SHA_IMAGE}" "${BACKEND_LATEST_IMAGE}"
}

build_frontend_image() {
  if ! should_run "${RUN_FRONTEND}"; then
    echo "Skipping frontend image build."
    return 0
  fi

  if docker image inspect "${FRONTEND_SHA_IMAGE}" >/dev/null 2>&1; then
    echo "Reusing cached frontend image: ${FRONTEND_SHA_IMAGE}"
    docker tag "${FRONTEND_SHA_IMAGE}" "${FRONTEND_LATEST_IMAGE}"
    return 0
  fi

  build_frontend_runtime_image_with_host_tools "${ROOT_DIR}" "${FRONTEND_SHA_IMAGE}" "${FRONTEND_NGINX_IMAGE}"
  docker tag "${FRONTEND_SHA_IMAGE}" "${FRONTEND_LATEST_IMAGE}"
}

push_backend_image() {
  if ! should_run "${RUN_BACKEND}" || ! should_run "${RUN_PUBLISH}"; then
    echo "Skipping backend image push."
    return 0
  fi

  echo "Pushing backend images to GHCR..."
  docker push "${BACKEND_SHA_IMAGE}"
  docker push "${BACKEND_LATEST_IMAGE}"
}

push_frontend_image() {
  if ! should_run "${RUN_FRONTEND}" || ! should_run "${RUN_PUBLISH}"; then
    echo "Skipping frontend image push."
    return 0
  fi

  echo "Pushing frontend images to GHCR..."
  docker push "${FRONTEND_SHA_IMAGE}"
  docker push "${FRONTEND_LATEST_IMAGE}"
}

deploy_minikube() {
  local backend_image="${BACKEND_LATEST_IMAGE}"
  local frontend_image="${FRONTEND_LATEST_IMAGE}"
  local smoke_test_flag="1"

  if ! should_run "${RUN_DEPLOY}"; then
    echo "Skipping minikube deploy."
    return 0
  fi

  if should_run "${RUN_BACKEND}"; then
    backend_image="${BACKEND_SHA_IMAGE}"
  fi

  if should_run "${RUN_FRONTEND}"; then
    frontend_image="${FRONTEND_SHA_IMAGE}"
  fi

  echo "Deploying to minikube with:"
  echo "  backend : ${backend_image}"
  echo "  frontend: ${frontend_image}"

  BACKEND_IMAGE="${backend_image}" \
  FRONTEND_IMAGE="${frontend_image}" \
  AUTO_START_MINIKUBE="1" \
  BUILD_LOCAL="0" \
  BUILD_OBSERVABILITY_LOCAL="1" \
  ENABLE_OBSERVABILITY="1" \
  ENABLE_PORT_FORWARD="${ENABLE_PORT_FORWARD}" \
  RUN_SMOKE_TEST="${smoke_test_flag}" \
  "${ROOT_DIR}/scripts/deploy_minikube.sh"

  echo "Running idempotent redeploy check..."
  BACKEND_IMAGE="${backend_image}" \
  FRONTEND_IMAGE="${frontend_image}" \
  AUTO_START_MINIKUBE="1" \
  BUILD_LOCAL="0" \
  BUILD_OBSERVABILITY_LOCAL="1" \
  ENABLE_OBSERVABILITY="1" \
  ENABLE_PORT_FORWARD="${ENABLE_PORT_FORWARD}" \
  RUN_SMOKE_TEST="0" \
  "${ROOT_DIR}/scripts/deploy_minikube.sh"
}

verify_observability() {
  if ! should_run "${RUN_DEPLOY}" || ! should_run "${RUN_OBSERVABILITY_VERIFY}"; then
    echo "Skipping observability verification."
    return 0
  fi

  echo "Verifying observability stack..."
  "${ROOT_DIR}/scripts/verify_observability_minikube.sh"
}

verify_hpa() {
  if ! should_run "${RUN_DEPLOY}" || ! should_run "${RUN_HPA_VALIDATION}"; then
    echo "Skipping HPA validation."
    return 0
  fi

  echo "Running HPA validation..."
  "${ROOT_DIR}/scripts/load_test_backend_hpa.sh"
}

print_summary() {
  if ! should_run "${RUN_DEPLOY}"; then
    return 0
  fi

  echo
  echo "Deployed resources:"
  kubectl -n flowboard get pods,svc,hpa
  echo "---"
  kubectl -n monitoring get pods,svc
}

main() {
  local run_image_build="0"

  ensure_runner_toolchain
  print_versions

  validate_backend
  validate_frontend

  if should_run "${RUN_DEPLOY}" || should_run "${RUN_PUBLISH}"; then
    run_image_build="1"
  fi

  if should_run "${run_image_build}"; then
    build_backend_image
    build_frontend_image
    push_backend_image
    push_frontend_image
  else
    echo "Skipping Docker image build/publish."
  fi

  deploy_minikube
  verify_observability
  verify_hpa
  print_summary
}

main "$@"
