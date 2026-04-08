#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S_DIR="${K8S_DIR:-${ROOT_DIR}/deploy/k8s}"
NAMESPACE="${NAMESPACE:-flowboard}"
BACKEND_IMAGE="${BACKEND_IMAGE:-ghcr.io/discipliny/dev_ops/backend:latest}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-ghcr.io/discipliny/dev_ops/frontend:latest}"
ENABLE_OBSERVABILITY="${ENABLE_OBSERVABILITY:-1}"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: ${cmd}"
    exit 1
  fi
}

require_cmd minikube
require_cmd kubectl

if ! minikube status >/dev/null 2>&1; then
  echo "Error: minikube is not running. Start it first: minikube start"
  exit 1
fi

if [[ "${ENABLE_OBSERVABILITY}" == "1" ]]; then
  require_cmd helm
  minikube addons enable metrics-server
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace \
    --set grafana.service.type=ClusterIP \
    --set prometheus.service.type=ClusterIP
fi

kubectl apply -f "${K8S_DIR}/namespace.yaml"
kubectl apply -f "${K8S_DIR}/postgres.yaml"
kubectl apply -f "${K8S_DIR}/backend.yaml"
kubectl apply -f "${K8S_DIR}/frontend.yaml"
kubectl apply -f "${K8S_DIR}/backend-hpa.yaml"
kubectl apply -f "${K8S_DIR}/frontend-hpa.yaml"

kubectl -n "${NAMESPACE}" set image deployment/backend backend="${BACKEND_IMAGE}"
kubectl -n "${NAMESPACE}" set image deployment/frontend frontend="${FRONTEND_IMAGE}"

kubectl -n "${NAMESPACE}" rollout status deployment/postgres --timeout=180s
kubectl -n "${NAMESPACE}" rollout status deployment/backend --timeout=180s
kubectl -n "${NAMESPACE}" rollout status deployment/frontend --timeout=180s

echo ""
echo "Kubernetes resources:"
kubectl -n "${NAMESPACE}" get pods,svc,hpa

echo ""
echo "Frontend URL (minikube):"
minikube service frontend -n "${NAMESPACE}" --url

echo ""
echo "Backend URL (minikube):"
minikube service backend -n "${NAMESPACE}" --url

echo ""
echo "Port-forward helpers:"
echo "  Grafana: kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 13000:80"
echo "  Prometheus: kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090"
