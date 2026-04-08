param(
  [string]$VmName = "flowboard-lab-vm",
  [string]$Namespace = "flowboard",
  [string]$BackendImage = "",
  [string]$FrontendImage = "",
  [switch]$BuildLocal,
  [string]$LocalBackendImage = "flowboard-backend:local",
  [string]$LocalFrontendImage = "flowboard-frontend:local",
  [switch]$SkipSmokeTest
)

$ErrorActionPreference = "Stop"
$scriptVersion = "2026-04-06.7"
Write-Host "deploy_vm_minikube.ps1 version: $scriptVersion"

function Require-Cmd {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function Invoke-MultipassBash {
  param(
    [string]$Vm,
    [string]$Script,
    [int]$Retries = 4
  )
  for ($attempt = 1; $attempt -le $Retries; $attempt++) {
    & multipass exec $Vm -- bash -lc $Script
    if ($LASTEXITCODE -eq 0) {
      return 0
    }
    Start-Sleep -Seconds 3
    & multipass start $Vm *> $null
  }
  return $LASTEXITCODE
}

function Invoke-MultipassTransferRecursive {
  param(
    [string]$Source,
    [string]$Destination,
    [int]$Retries = 4
  )
  for ($attempt = 1; $attempt -le $Retries; $attempt++) {
    & multipass transfer -r $Source $Destination
    if ($LASTEXITCODE -eq 0) {
      return 0
    }
    Start-Sleep -Seconds 3
  }
  return $LASTEXITCODE
}

function Ensure-MultipassVmReachable {
  param(
    [string]$Vm,
    [int]$Retries = 6
  )
  & multipass start $Vm *> $null
  for ($attempt = 1; $attempt -le $Retries; $attempt++) {
    & multipass exec $Vm -- bash -lc "echo vm-reachable" *> $null
    if ($LASTEXITCODE -eq 0) {
      return
    }
    Start-Sleep -Seconds 3
    & multipass stop $Vm *> $null
    Start-Sleep -Seconds 2
    & multipass start $Vm *> $null
  }
  throw "VM '$Vm' is not reachable via multipass exec."
}

function Show-DeploymentDiagnostics {
  param(
    [string]$Vm,
    [string]$Ns,
    [string]$Deployment,
    [string]$LabelSelector
  )
  & multipass exec $Vm -- bash -lc "kubectl -n $Ns get pods -o wide || true"
  & multipass exec $Vm -- bash -lc "kubectl -n $Ns describe deployment $Deployment || true"
  & multipass exec $Vm -- bash -lc "kubectl -n $Ns describe pods -l $LabelSelector || true"
  & multipass exec $Vm -- bash -lc "kubectl -n $Ns logs deployment/$Deployment --tail=100 || true"
}

Require-Cmd multipass

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$k8sDir = Join-Path $repoRoot "deploy\k8s"
if (-not (Test-Path $k8sDir)) {
  throw "Kubernetes manifests directory not found: $k8sDir"
}
$backendDir = Join-Path $repoRoot "backend"
$frontendDir = Join-Path $repoRoot "frontend"
if ($BuildLocal) {
  if (-not (Test-Path $backendDir)) { throw "Backend source directory not found: $backendDir" }
  if (-not (Test-Path $frontendDir)) { throw "Frontend source directory not found: $frontendDir" }
}

$remoteDir = "/tmp/flowboard-k8s"
$remoteSrcDir = "/tmp/flowboard-src"

Write-Host "Preparing manifests in VM '$VmName'..."
Ensure-MultipassVmReachable -Vm $VmName
Invoke-MultipassBash -Vm $VmName -Script "set -euo pipefail; rm -rf $remoteDir; mkdir -p $remoteDir" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to prepare manifest directory in VM." }

Invoke-MultipassTransferRecursive -Source "$k8sDir" -Destination "$VmName`:$remoteDir" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to transfer Kubernetes manifests into VM." }

if ($BuildLocal) {
  Write-Host "Building local images inside VM..."
  Invoke-MultipassBash -Vm $VmName -Script "set -euo pipefail; rm -rf $remoteSrcDir; mkdir -p $remoteSrcDir" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to prepare source directory in VM." }

  Invoke-MultipassTransferRecursive -Source "$backendDir" -Destination "$VmName`:$remoteSrcDir/" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to transfer backend sources into VM." }
  Invoke-MultipassTransferRecursive -Source "$frontendDir" -Destination "$VmName`:$remoteSrcDir/" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to transfer frontend sources into VM." }

  $buildScript = @'
set -euo pipefail
run_cmd() {
  "$@" && return 0
  if command -v sg >/dev/null 2>&1; then
    sg docker -c "$*"
    return $?
  fi
  return 1
}

run_cmd docker build -t __BACKEND_IMAGE__ __SRC_DIR__/backend
run_cmd docker build -t __FRONTEND_IMAGE__ __SRC_DIR__/frontend
run_cmd minikube image load __BACKEND_IMAGE__
run_cmd minikube image load __FRONTEND_IMAGE__
'@
  $buildScript = $buildScript.Replace("__SRC_DIR__", $remoteSrcDir)
  $buildScript = $buildScript.Replace("__BACKEND_IMAGE__", $LocalBackendImage)
  $buildScript = $buildScript.Replace("__FRONTEND_IMAGE__", $LocalFrontendImage)
  Invoke-MultipassBash -Vm $VmName -Script $buildScript | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to build/load local images in VM." }

  if (-not $BackendImage) { $BackendImage = $LocalBackendImage }
  if (-not $FrontendImage) { $FrontendImage = $LocalFrontendImage }
}

Write-Host "Ensuring Minikube API is reachable..."
Invoke-MultipassBash -Vm $VmName -Script @'
set -euo pipefail
if ! minikube status >/dev/null 2>&1; then
  minikube start --driver=docker --force
fi
for i in {1..60}; do
  if kubectl version --request-timeout=5s >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
kubectl version --request-timeout=10s >/dev/null 2>&1
'@ | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Minikube API is not reachable in VM." }

Write-Host "Applying manifests..."
Invoke-MultipassBash -Vm $VmName -Script @"
set -euo pipefail
kubectl apply --validate=false -f $remoteDir/k8s/namespace.yaml
kubectl apply --validate=false -f $remoteDir/k8s/postgres.yaml
kubectl apply --validate=false -f $remoteDir/k8s/backend.yaml
kubectl apply --validate=false -f $remoteDir/k8s/frontend.yaml
kubectl apply --validate=false -f $remoteDir/k8s/backend-hpa.yaml
kubectl apply --validate=false -f $remoteDir/k8s/frontend-hpa.yaml
"@ | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to apply Kubernetes manifests." }

if ($BackendImage) {
  Write-Host "Setting backend image: $BackendImage"
  Invoke-MultipassBash -Vm $VmName -Script "set -euo pipefail; kubectl -n $Namespace set image deployment/backend backend='$BackendImage'" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to set backend image in deployment." }
}

if ($FrontendImage) {
  Write-Host "Setting frontend image: $FrontendImage"
  Invoke-MultipassBash -Vm $VmName -Script "set -euo pipefail; kubectl -n $Namespace set image deployment/frontend frontend='$FrontendImage'" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Failed to set frontend image in deployment." }
}

Write-Host "Waiting for rollout..."
Invoke-MultipassBash -Vm $VmName -Script "kubectl -n $Namespace rollout status deployment/postgres --timeout=300s" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Postgres rollout failed." }

Invoke-MultipassBash -Vm $VmName -Script "kubectl -n $Namespace rollout status deployment/backend --timeout=300s" | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Backend rollout failed. Diagnostics:"
  Show-DeploymentDiagnostics -Vm $VmName -Ns $Namespace -Deployment "backend" -LabelSelector "app=backend"
  throw "Backend rollout failed. See diagnostics above."
}

Invoke-MultipassBash -Vm $VmName -Script "kubectl -n $Namespace rollout status deployment/frontend --timeout=300s" | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Frontend rollout failed. Diagnostics:"
  Show-DeploymentDiagnostics -Vm $VmName -Ns $Namespace -Deployment "frontend" -LabelSelector "app=frontend"
  throw "Frontend rollout failed. See diagnostics above."
}

Invoke-MultipassBash -Vm $VmName -Script "kubectl -n $Namespace get pods,svc,hpa" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to read cluster status after rollout." }

if (-not $SkipSmokeTest) {
  Write-Host "Running smoke test..."
  $smokeScript = @'
set -euo pipefail
frontend_url="$(minikube service frontend -n __NAMESPACE__ --url | sed -n '1p')"
curl -fsS -m 20 "${frontend_url}/api/insights" >/dev/null
curl -fsS -m 20 "${frontend_url}/api/tasks" >/dev/null
echo "Smoke test passed via: ${frontend_url}"
'@
  $smokeScript = $smokeScript.Replace("__NAMESPACE__", $Namespace)
  Invoke-MultipassBash -Vm $VmName -Script $smokeScript | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Smoke test failed." }
}

Write-Host ""
Write-Host "Deployment completed."
Write-Host "Check from VM: multipass exec $VmName -- kubectl -n $Namespace get pods,svc,hpa"
