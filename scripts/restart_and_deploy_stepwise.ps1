param(
  [string]$VmName = "flowboard-lab-vm",
  [string]$Namespace = "flowboard",
  [switch]$NoRecreateVm,
  [switch]$BuildInVm
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

$scriptVersion = "2026-04-08.1"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$mpExe = "C:\Program Files\Multipass\bin\multipass.exe"
if (-not (Test-Path $mpExe)) {
  $mpCmd = Get-Command multipass -ErrorAction SilentlyContinue
  if ($mpCmd) { $mpExe = $mpCmd.Source } else { throw "multipass.exe not found." }
}

$logPath = Join-Path $env:TEMP ("restart_and_deploy_stepwise_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Start-Transcript -Path $logPath -Force | Out-Null
Write-Host "restart_and_deploy_stepwise.ps1 version: $scriptVersion"
Write-Host "Log file: $logPath"

function Write-Step([string]$Title) {
  $ts = Get-Date -Format "HH:mm:ss"
  Write-Host ""
  Write-Host "=== [$ts] $Title ===" -ForegroundColor Cyan
}

function Invoke-Step {
  param(
    [string]$Title,
    [scriptblock]$Action
  )
  Write-Step $Title
  & $Action
  if ($LASTEXITCODE -ne 0) {
    throw "Step failed: $Title (exit code $LASTEXITCODE)"
  }
}

function Exec-VmStep {
  param(
    [string]$Title,
    [string]$Command
  )
  Invoke-Step -Title $Title -Action {
    & $mpExe exec $VmName -- bash -lc $Command
  }
}

function Restart-MultipassService {
  Write-Step "Restart Multipass Service"
  cmd /c "sc.exe stop Multipass" *> $null
  Get-Process multipass,multipassd -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  for ($i = 1; $i -le 10; $i++) {
    $q = cmd /c "sc.exe query Multipass" 2>$null
    if (($q | Out-String) -match "STATE\s*:\s*1\s+STOPPED") { break }
    Start-Sleep -Seconds 1
  }
  cmd /c "sc.exe start Multipass" *> $null
  Start-Sleep -Seconds 2
  & $mpExe list
  if ($LASTEXITCODE -ne 0) {
    throw "Multipass service did not come up cleanly."
  }
}

try {
  Restart-MultipassService

  if (-not $NoRecreateVm) {
    Invoke-Step -Title "Recreate VM ($VmName)" -Action {
      & $mpExe stop $VmName 2>$null
      & $mpExe delete $VmName 2>$null
      & $mpExe purge 2>$null
    }
  }

  Invoke-Step -Title "Terraform apply (create/update VM)" -Action {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "scripts\tf_vm.ps1") -Action apply -AutoApprove -InstallDeps false
  }

  Exec-VmStep -Title "VM health check" -Command "echo vm-ok && whoami"

  Invoke-Step -Title "Ansible install Docker + Minikube" -Action {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "scripts\ansible_install_minikube.ps1") -SkipTerraform
  }

  Exec-VmStep -Title "Prepare deployment directory in VM" -Command "rm -rf /tmp/flowboard-deploy && mkdir -p /tmp/flowboard-deploy"

  Invoke-Step -Title "Transfer k8s manifests into VM" -Action {
    & $mpExe transfer -r (Join-Path $repoRoot "deploy\k8s") "$VmName`:/tmp/flowboard-deploy/"
  }

  Exec-VmStep -Title "Verify k8s manifests in VM" -Command "ls -la /tmp/flowboard-deploy/k8s"

  if ($BuildInVm) {
    Invoke-Step -Title "Transfer backend/frontend sources for VM build" -Action {
      & $mpExe transfer -r (Join-Path $repoRoot "backend") "$VmName`:/tmp/flowboard-deploy/"
      & $mpExe transfer -r (Join-Path $repoRoot "frontend") "$VmName`:/tmp/flowboard-deploy/"
    }

    Exec-VmStep -Title "Build backend image in VM" -Command "docker build -t flowboard-backend:local /tmp/flowboard-deploy/backend"
    Exec-VmStep -Title "Build frontend image in VM" -Command "docker build -t flowboard-frontend:local /tmp/flowboard-deploy/frontend"
    Exec-VmStep -Title "Load images into minikube" -Command "minikube image load flowboard-backend:local && minikube image load flowboard-frontend:local"
  } else {
    Exec-VmStep -Title "Check required local images in VM" -Command "docker image inspect flowboard-backend:local >/dev/null 2>&1 && echo backend-image:ok || (echo backend-image:missing; exit 1)"
    Exec-VmStep -Title "Check required frontend image in VM" -Command "docker image inspect flowboard-frontend:local >/dev/null 2>&1 && echo frontend-image:ok || (echo frontend-image:missing; exit 1)"
  }

  Exec-VmStep -Title "Step 1: Apply namespace" -Command "kubectl apply --validate=false -f /tmp/flowboard-deploy/k8s/namespace.yaml"
  Exec-VmStep -Title "Step 2: Apply postgres" -Command "kubectl apply --validate=false -f /tmp/flowboard-deploy/k8s/postgres.yaml"
  Exec-VmStep -Title "Step 3: Apply backend" -Command "kubectl apply --validate=false -f /tmp/flowboard-deploy/k8s/backend.yaml"
  Exec-VmStep -Title "Step 4: Apply frontend" -Command "kubectl apply --validate=false -f /tmp/flowboard-deploy/k8s/frontend.yaml"
  Exec-VmStep -Title "Step 5: Apply HPA" -Command "kubectl apply --validate=false -f /tmp/flowboard-deploy/k8s/backend-hpa.yaml && kubectl apply --validate=false -f /tmp/flowboard-deploy/k8s/frontend-hpa.yaml"
  Exec-VmStep -Title "Step 6: Set backend image" -Command "kubectl -n $Namespace set image deployment/backend backend=flowboard-backend:local"
  Exec-VmStep -Title "Step 7: Set frontend image" -Command "kubectl -n $Namespace set image deployment/frontend frontend=flowboard-frontend:local"
  Exec-VmStep -Title "Step 8: Enable metrics-server addon" -Command "minikube addons enable metrics-server || true"
  Exec-VmStep -Title "Step 9: Wait postgres rollout" -Command "kubectl -n $Namespace rollout status deployment/postgres --timeout=600s"
  Exec-VmStep -Title "Step 10: Wait backend rollout" -Command "kubectl -n $Namespace rollout status deployment/backend --timeout=600s"
  Exec-VmStep -Title "Step 11: Wait frontend rollout" -Command "kubectl -n $Namespace rollout status deployment/frontend --timeout=600s"
  Exec-VmStep -Title "Step 12: Final status" -Command "kubectl -n $Namespace get pods,svc,hpa"

  Write-Host ""
  Write-Host "Completed successfully." -ForegroundColor Green
} catch {
  Write-Host ""
  Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
  throw
} finally {
  Stop-Transcript | Out-Null
  Write-Host "Saved log: $logPath"
}
