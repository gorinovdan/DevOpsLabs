#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-flowboard}"
FRONTEND_URL="${FRONTEND_URL:-}"
PORT_FORWARD_PORT="${PORT_FORWARD_PORT:-18081}"
PORT_FORWARD_LOG="${PORT_FORWARD_LOG:-/tmp/flowboard-frontend-port-forward.log}"
PORT_FORWARD_PID=""

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: ${cmd}" >&2
    exit 1
  fi
}

cleanup() {
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    wait "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/"/\\"/g'
}

extract_task_id() {
  sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p' | head -n 1
}

require_cmd minikube
require_cmd kubectl
require_cmd curl

if [[ -z "${FRONTEND_URL}" ]]; then
  FRONTEND_URL="http://127.0.0.1:${PORT_FORWARD_PORT}"
  if ! curl --noproxy '*' -fsS --connect-timeout 2 --max-time 5 "${FRONTEND_URL}/" >/dev/null 2>&1; then
    rm -f "${PORT_FORWARD_LOG}"
    kubectl -n "${NAMESPACE}" port-forward service/frontend "${PORT_FORWARD_PORT}:80" >"${PORT_FORWARD_LOG}" 2>&1 &
    PORT_FORWARD_PID=$!
    trap cleanup EXIT
  fi
fi

if [[ -z "${FRONTEND_URL}" ]]; then
  echo "Error: cannot resolve frontend URL from minikube." >&2
  exit 1
fi

echo "Using frontend URL: ${FRONTEND_URL}"

echo "Waiting for frontend root page..."
for _ in $(seq 1 30); do
  if curl --noproxy '*' -fsS --connect-timeout 2 --max-time 5 "${FRONTEND_URL}/" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! curl --noproxy '*' -fsS --connect-timeout 2 --max-time 5 "${FRONTEND_URL}/" >/dev/null 2>&1; then
  echo "Error: frontend did not become reachable at ${FRONTEND_URL}" >&2
  exit 1
fi

title="Smoke Task $(date +%s)"
create_payload="$(cat <<EOF
{"title":"$(json_escape "${title}")","description":"minikube smoke test","status":"todo","priority":"medium","owner":"ci","effortHours":2,"tags":["smoke","minikube"]}
EOF
)"

echo "Creating a task through frontend -> backend -> postgres..."
created_task="$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 10 -X POST "${FRONTEND_URL}/api/tasks" -H 'Content-Type: application/json' --data "${create_payload}")"
task_id="$(printf '%s' "${created_task}" | extract_task_id)"

if [[ -z "${task_id}" ]]; then
  echo "Error: cannot parse created task id. Response: ${created_task}" >&2
  exit 1
fi

echo "Created task id=${task_id}"

echo "Checking task fetch and insights..."
fetched_task="$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 10 "${FRONTEND_URL}/api/tasks/${task_id}")"
printf '%s' "${fetched_task}" | grep -q "\"id\":${task_id}"
curl --noproxy '*' -fsS --connect-timeout 2 --max-time 10 "${FRONTEND_URL}/api/insights" >/dev/null
curl --noproxy '*' -fsS --connect-timeout 2 --max-time 10 "${FRONTEND_URL}/api/tasks" >/dev/null

update_payload='{"title":"Smoke Task Updated","status":"in_progress","priority":"high","owner":"ci","effortHours":3,"tags":["smoke","updated"]}'
echo "Updating the created task..."
updated_task="$(curl --noproxy '*' -fsS --connect-timeout 2 --max-time 10 -X PUT "${FRONTEND_URL}/api/tasks/${task_id}" -H 'Content-Type: application/json' --data "${update_payload}")"
printf '%s' "${updated_task}" | grep -q '"title":"Smoke Task Updated"'

echo "Deleting the created task..."
curl --noproxy '*' -fsS --connect-timeout 2 --max-time 10 -X DELETE "${FRONTEND_URL}/api/tasks/${task_id}" >/dev/null

echo "Verifying backend endpoints behind the frontend reverse proxy..."
curl --noproxy '*' -fsS --connect-timeout 2 --max-time 10 "${FRONTEND_URL}/api/tasks" >/dev/null
curl --noproxy '*' -fsS --connect-timeout 2 --max-time 10 "${FRONTEND_URL}/api/insights" >/dev/null

echo
echo "Smoke test passed."
kubectl -n "${NAMESPACE}" get pods
