#!/usr/bin/env bash
set -euo pipefail

# Boot a local SonarQube instance for the FlowBoard CI pipeline.
#
# Two startup modes are supported:
#   1. Native binary (default) - launches the user's local SonarQube install.
#   2. Docker container - run as a daemon on the host network.
#
# Modes are selected via SONARQUBE_MODE=native|docker.

SONARQUBE_MODE="${SONARQUBE_MODE:-native}"
SONARQUBE_HOME="${SONARQUBE_HOME:-/Users/lasat/Downloads/sonarqube-26.4.0.121862}"
SONARQUBE_URL="${SONARQUBE_URL:-http://127.0.0.1:9000}"
SONARQUBE_DOCKER_IMAGE="${SONARQUBE_DOCKER_IMAGE:-sonarqube:25-community}"
SONARQUBE_CONTAINER_NAME="${SONARQUBE_CONTAINER_NAME:-flowboard-sonarqube}"
SONARQUBE_READY_TIMEOUT="${SONARQUBE_READY_TIMEOUT:-300}"

is_sonarqube_up() {
  curl -fsS -o /dev/null --max-time 5 "${SONARQUBE_URL}/api/system/status" 2>/dev/null
}

wait_for_sonarqube() {
  local deadline=$(($(date +%s) + SONARQUBE_READY_TIMEOUT))
  while (( $(date +%s) < deadline )); do
    local status_payload=""
    if status_payload="$(curl -fsS --max-time 5 "${SONARQUBE_URL}/api/system/status" 2>/dev/null)"; then
      if printf '%s' "${status_payload}" | grep -q '"status":"UP"'; then
        echo "SonarQube is UP at ${SONARQUBE_URL}"
        return 0
      fi
    fi
    sleep 5
  done
  echo "Error: SonarQube did not reach UP state within ${SONARQUBE_READY_TIMEOUT}s." >&2
  return 1
}

start_native() {
  if [[ ! -d "${SONARQUBE_HOME}" ]]; then
    echo "Error: SONARQUBE_HOME='${SONARQUBE_HOME}' does not exist." >&2
    echo "Set SONARQUBE_HOME or use SONARQUBE_MODE=docker." >&2
    exit 1
  fi

  local launcher=""
  case "$(uname -s)" in
    Darwin) launcher="${SONARQUBE_HOME}/bin/macosx-universal-64/sonar.sh" ;;
    Linux)  launcher="${SONARQUBE_HOME}/bin/linux-x86-64/sonar.sh" ;;
    *) echo "Error: unsupported OS for native SonarQube launcher." >&2; exit 1 ;;
  esac

  if [[ ! -x "${launcher}" ]]; then
    echo "Error: SonarQube launcher not found or not executable: ${launcher}" >&2
    exit 1
  fi

  if is_sonarqube_up; then
    echo "SonarQube already responding at ${SONARQUBE_URL}, skipping start."
    return 0
  fi

  echo "Starting native SonarQube from ${SONARQUBE_HOME}..."
  "${launcher}" start
}

start_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker command not found, required for SONARQUBE_MODE=docker." >&2
    exit 1
  fi

  if is_sonarqube_up; then
    echo "SonarQube already responding at ${SONARQUBE_URL}, skipping start."
    return 0
  fi

  if docker ps --format '{{.Names}}' | grep -q "^${SONARQUBE_CONTAINER_NAME}$"; then
    echo "Container ${SONARQUBE_CONTAINER_NAME} already running."
  elif docker ps -a --format '{{.Names}}' | grep -q "^${SONARQUBE_CONTAINER_NAME}$"; then
    echo "Restarting existing container ${SONARQUBE_CONTAINER_NAME}..."
    docker start "${SONARQUBE_CONTAINER_NAME}" >/dev/null
  else
    echo "Launching SonarQube container ${SONARQUBE_CONTAINER_NAME}..."
    docker run -d \
      --name "${SONARQUBE_CONTAINER_NAME}" \
      -p 9000:9000 \
      -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
      -v flowboard-sonarqube-data:/opt/sonarqube/data \
      -v flowboard-sonarqube-logs:/opt/sonarqube/logs \
      -v flowboard-sonarqube-extensions:/opt/sonarqube/extensions \
      "${SONARQUBE_DOCKER_IMAGE}" >/dev/null
  fi
}

case "${SONARQUBE_MODE}" in
  native) start_native ;;
  docker) start_docker ;;
  *) echo "Error: unsupported SONARQUBE_MODE=${SONARQUBE_MODE}" >&2; exit 1 ;;
esac

wait_for_sonarqube
