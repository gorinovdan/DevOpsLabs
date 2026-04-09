#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-minikube}"
MINIKUBE_ACTION="${MINIKUBE_ACTION:-stop}"
PURGE="${PURGE:-0}"
NAMESPACE="${NAMESPACE:-flowboard}"
LOAD_POD_NAME="${LOAD_POD_NAME:-backend-loadgen}"

source "${ROOT_DIR}/scripts/lib_minikube.sh"

require_cmd minikube

echo "Stopping local port-forwards..."
stop_default_port_forwards

if minikube -p "${MINIKUBE_PROFILE}" status >/dev/null 2>&1; then
  if command -v kubectl >/dev/null 2>&1; then
    echo "Removing transient load pod if present..."
    kubectl -n "${NAMESPACE}" delete pod "${LOAD_POD_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  fi
else
  echo "Minikube profile ${MINIKUBE_PROFILE} is not running."
fi

case "${MINIKUBE_ACTION}" in
  stop)
    if minikube -p "${MINIKUBE_PROFILE}" status >/dev/null 2>&1; then
      echo "Stopping minikube profile ${MINIKUBE_PROFILE}..."
      minikube -p "${MINIKUBE_PROFILE}" stop
    else
      echo "Minikube profile ${MINIKUBE_PROFILE} is already stopped."
    fi
    ;;
  delete)
    echo "Deleting minikube profile ${MINIKUBE_PROFILE}..."
    if [[ "${PURGE}" == "1" ]]; then
      minikube -p "${MINIKUBE_PROFILE}" delete --purge
    else
      minikube -p "${MINIKUBE_PROFILE}" delete
    fi
    ;;
  *)
    echo "Error: unsupported MINIKUBE_ACTION=${MINIKUBE_ACTION}. Use stop or delete." >&2
    exit 1
    ;;
esac

echo "Shutdown flow completed."
