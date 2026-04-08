param(
  [string]$Namespace = 'flowboard',
  [string]$BackendImage = 'ghcr.io/discipliny/dev_ops/backend:latest',
  [string]$FrontendImage = 'ghcr.io/discipliny/dev_ops/frontend:latest',
  [switch]$BuildLocal,
  [switch]$EnableObservability = $true
)

$ErrorActionPreference = 'Stop'

function Require-Cmd {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$k8sDir = Join-Path $repoRoot 'deploy\k8s'

Require-Cmd minikube
Require-Cmd kubectl
Require-Cmd docker

$mkStatus = minikube status 2>$null
if ($LASTEXITCODE -ne 0) {
  throw 'minikube is not running. Start it first: minikube start --driver=docker'
}

if ($EnableObservability) {
  Require-Cmd helm
  minikube addons enable metrics-server
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack `
    --namespace monitoring `
    --create-namespace `
    --set grafana.service.type=ClusterIP `
    --set prometheus.service.type=ClusterIP
  kubectl -n monitoring rollout status deployment/kube-prometheus-stack-operator --timeout=300s
}

kubectl apply -f (Join-Path $k8sDir 'namespace.yaml')
kubectl apply -f (Join-Path $k8sDir 'postgres.yaml')
kubectl apply -f (Join-Path $k8sDir 'backend.yaml')
kubectl apply -f (Join-Path $k8sDir 'frontend.yaml')
kubectl apply -f (Join-Path $k8sDir 'backend-hpa.yaml')
kubectl apply -f (Join-Path $k8sDir 'frontend-hpa.yaml')

if ($BuildLocal) {
  $localBackend = 'flowboard-backend:local'
  $localFrontend = 'flowboard-frontend:local'

  Push-Location $repoRoot
  try {
    docker build -t $localBackend .\backend
    docker build -t $localFrontend .\frontend
  }
  finally {
    Pop-Location
  }

  minikube image load $localBackend
  minikube image load $localFrontend

  $BackendImage = $localBackend
  $FrontendImage = $localFrontend
}

kubectl -n $Namespace set image deployment/backend backend=$BackendImage
kubectl -n $Namespace set image deployment/frontend frontend=$FrontendImage

kubectl -n $Namespace rollout status deployment/postgres --timeout=300s
kubectl -n $Namespace rollout status deployment/backend --timeout=300s
kubectl -n $Namespace rollout status deployment/frontend --timeout=300s

kubectl -n $Namespace get pods,svc,hpa

Write-Host "`nUseful local access via port-forward:"
Write-Host '  Frontend  : kubectl -n flowboard port-forward svc/frontend 18081:80'
Write-Host '  Backend   : kubectl -n flowboard port-forward svc/backend 18080:8080'
Write-Host '  Grafana   : kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 13000:80'
Write-Host '  Prometheus: kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090'
