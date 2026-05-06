#!/usr/bin/env bash
set -euo pipefail

# Run the SonarQube scan locally or on a self-hosted runner. Assumes
# coverage artefacts are already produced under:
#   - backend/coverage.out
#   - frontend/coverage/lcov.info
#
# The scanner then runs with sonar.qualitygate.wait=true, so the script
# exits non-zero if the SonarQube quality gate fails.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SONARQUBE_URL="${SONARQUBE_URL:-http://127.0.0.1:9000}"
SONARQUBE_TOKEN="${SONARQUBE_TOKEN:-}"
SONARQUBE_ADMIN_USER="${SONARQUBE_ADMIN_USER:-admin}"
SONARQUBE_ADMIN_PASSWORD="${SONARQUBE_ADMIN_PASSWORD:-admin}"
SONAR_SCANNER_BIN="${SONAR_SCANNER_BIN:-sonar-scanner}"
SONAR_SCAN_VIA_DOCKER="${SONAR_SCAN_VIA_DOCKER:-0}"
SONAR_SCANNER_DOCKER_IMAGE="${SONAR_SCANNER_DOCKER_IMAGE:-sonarsource/sonar-scanner-cli:latest}"

if ! command -v "${SONAR_SCANNER_BIN}" >/dev/null 2>&1 && [[ "${SONAR_SCAN_VIA_DOCKER}" != "1" ]]; then
  echo "Warning: sonar-scanner not on PATH; falling back to Docker image ${SONAR_SCANNER_DOCKER_IMAGE}." >&2
  SONAR_SCAN_VIA_DOCKER=1
fi

if [[ -z "${SONARQUBE_TOKEN}" ]]; then
  echo "SONARQUBE_TOKEN not set, falling back to admin credentials. Set SONARQUBE_TOKEN for production runs." >&2
fi

backend_coverage="${ROOT_DIR}/backend/coverage.out"
frontend_lcov="${ROOT_DIR}/frontend/coverage/lcov.info"
if [[ ! -f "${backend_coverage}" ]]; then
  echo "Error: backend coverage profile not found at ${backend_coverage}" >&2
  exit 1
fi
if [[ ! -f "${frontend_lcov}" ]]; then
  echo "Error: frontend lcov coverage not found at ${frontend_lcov}" >&2
  exit 1
fi

declare -a sonar_args=(
  "-Dsonar.host.url=${SONARQUBE_URL}"
  "-Dsonar.qualitygate.wait=true"
)

if [[ -n "${SONARQUBE_TOKEN}" ]]; then
  sonar_args+=("-Dsonar.token=${SONARQUBE_TOKEN}")
else
  sonar_args+=("-Dsonar.login=${SONARQUBE_ADMIN_USER}" "-Dsonar.password=${SONARQUBE_ADMIN_PASSWORD}")
fi

if [[ -n "${GITHUB_SHA:-}" ]]; then
  sonar_args+=("-Dsonar.projectVersion=${GITHUB_SHA::8}")
fi

cd "${ROOT_DIR}"

if [[ "${SONAR_SCAN_VIA_DOCKER}" == "1" ]]; then
  echo "Running sonar-scanner via Docker (${SONAR_SCANNER_DOCKER_IMAGE})..."

  # On Docker Desktop (macOS/Windows) `--network host` does not reach the
  # host loopback, so swap localhost for host.docker.internal before running.
  docker_sonar_args=()
  for arg in "${sonar_args[@]}"; do
    docker_sonar_args+=("${arg//127.0.0.1/host.docker.internal}")
    docker_sonar_args[-1]="${docker_sonar_args[-1]//localhost/host.docker.internal}"
  done

  docker run --rm \
    --add-host=host.docker.internal:host-gateway \
    -v "${ROOT_DIR}:/usr/src" \
    -w /usr/src \
    "${SONAR_SCANNER_DOCKER_IMAGE}" \
    "${docker_sonar_args[@]}"
else
  echo "Running native sonar-scanner..."
  "${SONAR_SCANNER_BIN}" "${sonar_args[@]}"
fi
