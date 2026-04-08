param(
  [string]$VmName = "flowboard-lab-vm",
  [string]$Namespace = "flowboard",
  [string]$BackendImage = "flowboard-backend:local",
  [string]$FrontendImage = "flowboard-frontend:local",
  [ValidateSet("auto","host","vm")]
  [string]$BuildMode = "auto",
  [switch]$SkipBuild,
  [switch]$SkipSmokeTest
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}
$scriptVersion = "2026-04-07.10"
Write-Host "deploy_vm_minikube_safe.ps1 version: $scriptVersion"
$script:MultipassExe = $null
$script:TranscriptStarted = $false
$script:LogPath = Join-Path $env:TEMP ("deploy_vm_minikube_safe_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
try {
  Start-Transcript -Path $script:LogPath -Force | Out-Null
  $script:TranscriptStarted = $true
  Write-Host "Log file: $script:LogPath"
} catch {
  Write-Warning "Could not start transcript log: $($_.Exception.Message)"
}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($id)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-MultipassExe {
  $cmd = Get-Command multipass -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }

  $fallback = "C:\Program Files\Multipass\bin\multipass.exe"
  if (Test-Path $fallback) { return $fallback }

  throw "multipass executable not found. Install Multipass first."
}

function Invoke-MultipassCommand {
  param(
    [string[]]$CmdArgs,
    [int]$TimeoutSec = 60,
    [switch]$SuppressOutput
  )

  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  if ($SuppressOutput) {
    & $script:MultipassExe @CmdArgs *> $null
  } else {
    & $script:MultipassExe @CmdArgs
  }
  $global:LASTEXITCODE = $LASTEXITCODE
  $ErrorActionPreference = $prev
}

function Test-MultipassHealthy {
  Invoke-MultipassCommand -CmdArgs @("list","--format","json") -SuppressOutput
  return ($LASTEXITCODE -eq 0)
}

function Repair-MultipassService {
  Write-Host "Multipass CLI is not responding. Trying service recovery..."
  if (-not (Test-IsAdmin)) {
    throw "Multipass service recovery requires Administrator PowerShell. Re-run this script as Administrator."
  }

  Write-Host "Stopping Multipass service (non-blocking)..."
  cmd /c "sc.exe stop Multipass" *> $null
  Get-Process multipass,multipassd -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  for ($i = 1; $i -le 8; $i++) {
    $status = cmd /c "sc.exe query Multipass" 2>$null
    if (($status | Out-String) -match "STATE\s*:\s*1\s+STOPPED") { break }
    Start-Sleep -Seconds 1
  }

  Write-Host "Starting Multipass service..."
  cmd /c "sc.exe start Multipass" *> $null

  for ($i = 1; $i -le 15; $i++) {
    if (Test-MultipassHealthy) {
      Write-Host "Multipass service is healthy again."
      return
    }
    Start-Sleep -Seconds 2
  }

  throw "Multipass service did not recover. Try rebooting Windows and re-run."
}

function Ensure-MultipassHealthy {
  if (Test-MultipassHealthy) { return }
  throw "Multipass daemon is unreachable. Run scripts\\recover_multipass.ps1 manually, then retry."
}

function Require-Cmd {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function Invoke-WithRetry {
  param(
    [scriptblock]$Action,
    [string]$Label,
    [int]$Retries = 5,
    [int]$DelaySeconds = 4,
    [switch]$RecoverMultipass
  )

  for ($i = 1; $i -le $Retries; $i++) {
    Write-Host "[$Label] attempt $i/$Retries..."
    & $Action
    if ($LASTEXITCODE -eq 0) {
      return
    }
    if ($i -lt $Retries) {
      if ($RecoverMultipass) {
        try { Ensure-MultipassHealthy } catch { Write-Warning $_.Exception.Message }
      }
      Write-Host "Retry $i/$Retries for: $Label"
      Start-Sleep -Seconds $DelaySeconds
    }
  }

  throw "$Label failed after $Retries attempts."
}

function Mp-Exec-Bash {
  param(
    [string]$Vm,
    [string]$Command,
    [string]$Label = "multipass exec",
    [int]$Retries = 5,
    [int]$TimeoutSec = 300
  )

  Invoke-WithRetry -Label $Label -Retries $Retries -RecoverMultipass -Action {
    Invoke-MultipassCommand -CmdArgs @("exec",$Vm,"--","bash","-lc",$Command) -TimeoutSec $TimeoutSec
  }
}

function Mp-TransferRecursive {
  param(
    [string]$Source,
    [string]$Destination,
    [string]$Label = "multipass transfer",
    [int]$Retries = 5,
    [int]$TimeoutSec = 180
  )

  Invoke-WithRetry -Label $Label -Retries $Retries -RecoverMultipass -Action {
    Invoke-MultipassCommand -CmdArgs @("transfer","-r",$Source,$Destination) -TimeoutSec $TimeoutSec
  }
}

function Test-HostDockerAvailable {
  $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
  if (-not $dockerCmd) { return $false }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  docker version --format "{{.Server.Version}}" *> $null
  $ok = ($LASTEXITCODE -eq 0)
  $ErrorActionPreference = $prev
  return $ok
}

function Invoke-HostDockerBuildWithRetry {
  param(
    [string]$Image,
    [string]$ContextDir,
    [int]$Retries = 3
  )

  for ($i = 1; $i -le $Retries; $i++) {
    Write-Host "[host docker build] $Image attempt $i/$Retries..."
    docker build -t $Image $ContextDir
    if ($LASTEXITCODE -eq 0) { return }
    if ($i -lt $Retries) {
      Start-Sleep -Seconds 5
    }
  }
  throw "Host docker build failed for image: $Image"
}

function Build-ImagesOnHostAndExport {
  param(
    [string]$BackendImg,
    [string]$FrontendImg,
    [string]$BackendSrc,
    [string]$FrontendSrc,
    [string]$OutputDir
  )

  if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
  }

  $backendTar = Join-Path $OutputDir "backend.tar"
  $frontendTar = Join-Path $OutputDir "frontend.tar"

  Invoke-HostDockerBuildWithRetry -Image $BackendImg -ContextDir $BackendSrc
  Invoke-HostDockerBuildWithRetry -Image $FrontendImg -ContextDir $FrontendSrc

  Write-Host "[host docker save] Exporting images to tar..."
  docker save -o $backendTar $BackendImg
  if ($LASTEXITCODE -ne 0) { throw "Failed to docker save backend image." }
  docker save -o $frontendTar $FrontendImg
  if ($LASTEXITCODE -ne 0) { throw "Failed to docker save frontend image." }

  return @{
    backend_tar = $backendTar
    frontend_tar = $frontendTar
  }
}

$script:MultipassExe = Get-MultipassExe
Ensure-MultipassHealthy

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$k8sDir = Join-Path $repoRoot "deploy\k8s"
$backendDir = Join-Path $repoRoot "backend"
$frontendDir = Join-Path $repoRoot "frontend"

if (-not (Test-Path $k8sDir)) { throw "Missing directory: $k8sDir" }
if (-not $SkipBuild) {
  if (-not (Test-Path $backendDir)) { throw "Missing directory: $backendDir" }
  if (-not (Test-Path $frontendDir)) { throw "Missing directory: $frontendDir" }
}

$remoteRoot = "/tmp/flowboard-deploy"
$remoteScriptLocal = Join-Path $env:TEMP "flowboard-deploy-run.sh"
$remoteScriptVm = "$remoteRoot/run.sh"
$localImageBundleDir = Join-Path $env:TEMP ("flowboard-image-bundle-{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$localImageBundle = $null

$effectiveBuildMode = "vm"
if ($SkipBuild) {
  $effectiveBuildMode = "none"
} elseif ($BuildMode -eq "host") {
  if (-not (Test-HostDockerAvailable)) {
    throw "BuildMode=host requested, but Docker daemon is not available on this machine."
  }
  $effectiveBuildMode = "host"
} elseif ($BuildMode -eq "auto") {
  if (Test-HostDockerAvailable) {
    $effectiveBuildMode = "host"
  } else {
    $effectiveBuildMode = "vm"
  }
} else {
  $effectiveBuildMode = "vm"
}
Write-Host "Selected build mode: $effectiveBuildMode"

Write-Host "Ensuring VM is running and reachable..."
Invoke-WithRetry -Label "multipass start" -Retries 4 -RecoverMultipass -Action { Invoke-MultipassCommand -CmdArgs @("start",$VmName) -TimeoutSec 90 -SuppressOutput }
Mp-Exec-Bash -Vm $VmName -Label "multipass exec healthcheck" -Command "echo vm-ok && whoami"

Write-Host "Preparing VM workspace..."
Mp-Exec-Bash -Vm $VmName -Label "prepare VM workspace" -Command "set -euo pipefail; rm -rf $remoteRoot; mkdir -p $remoteRoot/src $remoteRoot/images"

Write-Host "Transferring Kubernetes manifests..."
Mp-TransferRecursive -Source $k8sDir -Destination "$VmName`:$remoteRoot" -Label "transfer k8s"

if ($effectiveBuildMode -eq "vm") {
  Write-Host "Transferring backend/frontend sources..."
  Mp-TransferRecursive -Source $backendDir -Destination "$VmName`:$remoteRoot/src/" -Label "transfer backend"
  Mp-TransferRecursive -Source $frontendDir -Destination "$VmName`:$remoteRoot/src/" -Label "transfer frontend"
} elseif ($effectiveBuildMode -eq "host") {
  $hostBuildSucceeded = $false
  try {
    Write-Host "Building images on host and transferring tar bundles..."
    $localImageBundle = Build-ImagesOnHostAndExport -BackendImg $BackendImage -FrontendImg $FrontendImage -BackendSrc $backendDir -FrontendSrc $frontendDir -OutputDir $localImageBundleDir
    Invoke-WithRetry -Label "transfer backend image tar" -Retries 3 -Action {
      Invoke-MultipassCommand -CmdArgs @("transfer",$localImageBundle.backend_tar,"$VmName`:$remoteRoot/images/backend.tar") -SuppressOutput
    }
    Invoke-WithRetry -Label "transfer frontend image tar" -Retries 3 -Action {
      Invoke-MultipassCommand -CmdArgs @("transfer",$localImageBundle.frontend_tar,"$VmName`:$remoteRoot/images/frontend.tar") -SuppressOutput
    }
    $hostBuildSucceeded = $true
  } catch {
    if ($BuildMode -eq "auto") {
      Write-Warning "Host build path failed in auto mode: $($_.Exception.Message)"
      Write-Warning "Falling back to VM build mode."
      $effectiveBuildMode = "vm"
    } else {
      throw
    }
  }

  if (-not $hostBuildSucceeded -and $effectiveBuildMode -eq "vm") {
    Write-Host "Transferring backend/frontend sources for VM build fallback..."
    Mp-TransferRecursive -Source $backendDir -Destination "$VmName`:$remoteRoot/src/" -Label "transfer backend"
    Mp-TransferRecursive -Source $frontendDir -Destination "$VmName`:$remoteRoot/src/" -Label "transfer frontend"
  }
}
Write-Host "Effective build mode for deploy phase: $effectiveBuildMode"

$doBuild = if ($SkipBuild) { "0" } else { "1" }
$doSmoke = if ($SkipSmokeTest) { "0" } else { "1" }

$remoteScript = @'
#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="__NAMESPACE__"
BACKEND_IMAGE="__BACKEND_IMAGE__"
FRONTEND_IMAGE="__FRONTEND_IMAGE__"
REMOTE_ROOT="__REMOTE_ROOT__"
DO_BUILD="__DO_BUILD__"
DO_SMOKE="__DO_SMOKE__"
BUILD_MODE="__BUILD_MODE__"

# Keep console alive during long image builds / rollouts.
(
  while true; do
    echo "[heartbeat] $(date -u +%H:%M:%S) deployment still running..."
    sleep 30
  done
) &
HEARTBEAT_PID=$!
cleanup_heartbeat() {
  kill "$HEARTBEAT_PID" >/dev/null 2>&1 || true
}
trap cleanup_heartbeat EXIT

run_docker_ctx() {
  if "$@"; then
    return 0
  fi
  if command -v sg >/dev/null 2>&1; then
    sg docker -c "$*"
    return $?
  fi
  return 1
}

retry_run_docker_ctx() {
  local attempts="$1"
  shift
  local delay_sec=15
  local i
  for i in $(seq 1 "$attempts"); do
    if run_docker_ctx "$@"; then
      return 0
    fi
    if [ "$i" -lt "$attempts" ]; then
      echo "Retry ${i}/${attempts} for: $*"
      sleep "$delay_sec"
    fi
  done
  return 1
}

build_image_with_retry() {
  local image="$1"
  local context="$2"
  local timeout_sec="$3"
  local attempts="$4"
  local i
  for i in $(seq 1 "$attempts"); do
    if command -v timeout >/dev/null 2>&1; then
      if run_docker_ctx timeout --foreground "${timeout_sec}s" docker build --pull --network=host -t "$image" "$context"; then
        return 0
      fi
    else
      if run_docker_ctx docker build --pull --network=host -t "$image" "$context"; then
        return 0
      fi
    fi
    if [ "$i" -lt "$attempts" ]; then
      echo "Build failed for $image. Retry ${i}/${attempts}..."
      sleep 20
    fi
  done
  return 1
}

if ! minikube status >/dev/null 2>&1; then
  mem_total_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  mem_mb="$((mem_total_mb - 256))"
  if [ "$mem_mb" -lt 1024 ]; then mem_mb=1024; fi
  if [ "$mem_mb" -gt 4096 ]; then mem_mb=4096; fi
  cpus="$(nproc)"
  if [ "$cpus" -gt 2 ]; then cpus=2; fi
  if [ "$cpus" -lt 1 ]; then cpus=1; fi
  run_docker_ctx minikube start --driver=docker --force --cpus="$cpus" --memory="$mem_mb"
fi

for _ in {1..60}; do
  if kubectl version --request-timeout=5s >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
kubectl version --request-timeout=10s >/dev/null 2>&1

if [ "$DO_BUILD" = "1" ]; then
  if [ "$BUILD_MODE" = "host" ]; then
    retry_run_docker_ctx 4 docker load -i "$REMOTE_ROOT/images/backend.tar"
    retry_run_docker_ctx 4 docker load -i "$REMOTE_ROOT/images/frontend.tar"
    retry_run_docker_ctx 4 minikube image load "$BACKEND_IMAGE"
    retry_run_docker_ctx 4 minikube image load "$FRONTEND_IMAGE"
  else
    if ! build_image_with_retry "$BACKEND_IMAGE" "$REMOTE_ROOT/src/backend" 1800 4; then
      echo "Backend build failed after retries."
      exit 1
    fi
    if ! build_image_with_retry "$FRONTEND_IMAGE" "$REMOTE_ROOT/src/frontend" 1800 4; then
      echo "Frontend build failed after retries."
      exit 1
    fi
    retry_run_docker_ctx 4 minikube image load "$BACKEND_IMAGE"
    retry_run_docker_ctx 4 minikube image load "$FRONTEND_IMAGE"
  fi
fi

kubectl apply --validate=false -f "$REMOTE_ROOT/k8s/namespace.yaml"
kubectl apply --validate=false -f "$REMOTE_ROOT/k8s/postgres.yaml"
kubectl apply --validate=false -f "$REMOTE_ROOT/k8s/backend.yaml"
kubectl apply --validate=false -f "$REMOTE_ROOT/k8s/frontend.yaml"
kubectl apply --validate=false -f "$REMOTE_ROOT/k8s/backend-hpa.yaml"
kubectl apply --validate=false -f "$REMOTE_ROOT/k8s/frontend-hpa.yaml"

kubectl -n "$NAMESPACE" set image deployment/backend backend="$BACKEND_IMAGE"
kubectl -n "$NAMESPACE" set image deployment/frontend frontend="$FRONTEND_IMAGE"

if ! run_docker_ctx minikube addons enable metrics-server; then
  echo "Warning: failed to enable metrics-server, continuing."
fi

kubectl -n "$NAMESPACE" rollout status deployment/postgres --timeout=600s
if ! kubectl -n "$NAMESPACE" rollout status deployment/backend --timeout=600s; then
  echo "Backend rollout diagnostics:"
  kubectl -n "$NAMESPACE" get pods -o wide || true
  kubectl -n "$NAMESPACE" describe deployment backend || true
  kubectl -n "$NAMESPACE" describe pods -l app=backend || true
  kubectl -n "$NAMESPACE" logs deployment/backend --tail=100 || true
  exit 1
fi
if ! kubectl -n "$NAMESPACE" rollout status deployment/frontend --timeout=600s; then
  echo "Frontend rollout diagnostics:"
  kubectl -n "$NAMESPACE" get pods -o wide || true
  kubectl -n "$NAMESPACE" describe deployment frontend || true
  kubectl -n "$NAMESPACE" describe pods -l app=frontend || true
  kubectl -n "$NAMESPACE" logs deployment/frontend --tail=100 || true
  exit 1
fi

kubectl -n "$NAMESPACE" get pods,svc,hpa

if [ "$DO_SMOKE" = "1" ]; then
  frontend_url="$(minikube service frontend -n "$NAMESPACE" --url | sed -n '1p')"
  curl -fsS -m 30 "${frontend_url}/api/insights" >/dev/null
  curl -fsS -m 30 "${frontend_url}/api/tasks" >/dev/null
  echo "Smoke test passed via: ${frontend_url}"
fi
'@

$remoteScript = $remoteScript.Replace("__NAMESPACE__", $Namespace)
$remoteScript = $remoteScript.Replace("__BACKEND_IMAGE__", $BackendImage)
$remoteScript = $remoteScript.Replace("__FRONTEND_IMAGE__", $FrontendImage)
$remoteScript = $remoteScript.Replace("__REMOTE_ROOT__", $remoteRoot)
$remoteScript = $remoteScript.Replace("__DO_BUILD__", $doBuild)
$remoteScript = $remoteScript.Replace("__DO_SMOKE__", $doSmoke)
$remoteScript = $remoteScript.Replace("__BUILD_MODE__", $effectiveBuildMode)

[System.IO.File]::WriteAllText($remoteScriptLocal, $remoteScript, [System.Text.UTF8Encoding]::new($false))

Write-Host "Transferring and running deployment script in VM..."
Invoke-WithRetry -Label "transfer run.sh" -Retries 5 -Action {
  Invoke-MultipassCommand -CmdArgs @("transfer",$remoteScriptLocal,"$VmName`:$remoteScriptVm") -TimeoutSec 180 -SuppressOutput
}
Mp-Exec-Bash -Vm $VmName -Label "chmod run.sh" -Command "chmod +x $remoteScriptVm"
Mp-Exec-Bash -Vm $VmName -Label "execute run.sh" -Command "$remoteScriptVm" -Retries 2 -TimeoutSec 7200

Write-Host ""
Write-Host "Done."
Write-Host "Quick check:"
Write-Host "  multipass exec $VmName -- kubectl -n $Namespace get pods,svc,hpa"
if (Test-Path $localImageBundleDir) {
  Remove-Item -LiteralPath $localImageBundleDir -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:TranscriptStarted) {
  Stop-Transcript | Out-Null
  Write-Host "Saved log: $script:LogPath"
}
