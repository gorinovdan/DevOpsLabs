param(
  [switch]$EnableMetricsServer = $true
)

$ErrorActionPreference = 'Stop'

function Require-Cmd {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

Require-Cmd minikube
Require-Cmd kubectl
Require-Cmd helm

$mkStatus = minikube status 2>$null
if ($LASTEXITCODE -ne 0) {
  throw 'minikube is not running. Start it first: minikube start --driver=docker'
}

if ($EnableMetricsServer) {
  minikube addons enable metrics-server
}

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack `
  --namespace monitoring `
  --create-namespace `
  --set grafana.service.type=ClusterIP `
  --set prometheus.service.type=ClusterIP

kubectl -n monitoring rollout status deployment/kube-prometheus-stack-operator --timeout=300s

Write-Host "`nMonitoring pods:"
kubectl get pods -n monitoring

Write-Host "`nPort-forward helpers:"
Write-Host '  Grafana   : kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 13000:80'
Write-Host '  Prometheus: kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090'
