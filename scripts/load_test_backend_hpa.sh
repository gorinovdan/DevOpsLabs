#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-flowboard}"
LOAD_POD_NAME="${LOAD_POD_NAME:-backend-loadgen}"
WORKERS="${WORKERS:-48}"
DURATION_SEC="${DURATION_SEC:-150}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-5}"
TARGET_REPLICAS="${TARGET_REPLICAS:-2}"
LOADGEN_IMAGE="${LOADGEN_IMAGE:-busybox:1.36}"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: ${cmd}" >&2
    exit 1
  fi
}

cleanup() {
  kubectl -n "${NAMESPACE}" delete pod "${LOAD_POD_NAME}" --ignore-not-found >/dev/null 2>&1 || true
}

require_cmd kubectl

if ! kubectl top nodes >/dev/null 2>&1; then
  echo "Error: Metrics API is not available. metrics-server must be ready before HPA validation." >&2
  exit 1
fi

cleanup
trap cleanup EXIT

echo "Starting backend load pod ${LOAD_POD_NAME} with ${WORKERS} workers for ${DURATION_SEC}s..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${LOAD_POD_NAME}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: loadgen
      image: ${LOADGEN_IMAGE}
      command:
        - sh
        - -c
        - |
          i=0
          while [ "\$i" -lt "${WORKERS}" ]; do
            (
              while true; do
                wget -q -O- http://backend:8080/api/tasks >/dev/null
              done
            ) &
            i=\$((i + 1))
          done
          sleep "${DURATION_SEC}"
          kill 0
EOF

scaled=0
attempts=$((DURATION_SEC / POLL_INTERVAL_SEC + 18))

for _ in $(seq 1 "${attempts}"); do
  current="$(kubectl -n "${NAMESPACE}" get hpa backend-hpa -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo 0)"
  desired="$(kubectl -n "${NAMESPACE}" get hpa backend-hpa -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || echo 0)"
  cpu_target="$(kubectl -n "${NAMESPACE}" get hpa backend-hpa -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null || echo '?')"
  current_cpu="$(kubectl -n "${NAMESPACE}" get hpa backend-hpa -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true)"

  echo "HPA status: currentReplicas=${current:-0} desiredReplicas=${desired:-0} cpu=${current_cpu:-n/a}% target=${cpu_target}%"
  kubectl -n "${NAMESPACE}" top pods -l app=backend --no-headers 2>/dev/null || true

  if [[ "${desired:-0}" -ge "${TARGET_REPLICAS}" || "${current:-0}" -ge "${TARGET_REPLICAS}" ]]; then
    scaled=1
    break
  fi

  sleep "${POLL_INTERVAL_SEC}"
done

echo
kubectl -n "${NAMESPACE}" get hpa backend-hpa
kubectl -n "${NAMESPACE}" get pods -l app=backend -o wide

if [[ "${scaled}" != "1" ]]; then
  echo "Error: backend HPA did not scale to ${TARGET_REPLICAS} replicas under load." >&2
  exit 1
fi

echo "Backend HPA scaled successfully."
