param(
  [string]$VmName = "flowboard-lab-vm",
  [string]$WslDistro = "Ubuntu",
  [switch]$RecoverMultipass,
  [switch]$SkipTerraform,
  [switch]$InstallDeps
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

function Write-Step([string]$Title) {
  $ts = Get-Date -Format "HH:mm:ss"
  Write-Host ""
  Write-Host "=== [$ts] $Title ==="
}

function Invoke-Step([string]$Title, [scriptblock]$Action) {
  Write-Step $Title
  & $Action
  if ($LASTEXITCODE -ne 0) {
    throw "Step failed: $Title (exit code $LASTEXITCODE)"
  }
}

function Assert-LastExit([string]$Label) {
  if ($LASTEXITCODE -ne 0) {
    throw "$Label failed (exit code $LASTEXITCODE)"
  }
}

function Resolve-MultipassPath {
  $cmd = Get-Command multipass -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $fallback = "C:\Program Files\Multipass\bin\multipass.exe"
  if (Test-Path $fallback) { return $fallback }
  throw "multipass executable not found in PATH and fallback path."
}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($id)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$tfScript = Join-Path $repoRoot "scripts\tf_vm.ps1"
$ansibleScript = Join-Path $repoRoot "scripts\ansible_install_minikube.ps1"
$multipass = Resolve-MultipassPath

Write-Host "run_vm_minikube_pipeline.ps1 version: 2026-04-08.1"
Write-Host "VM: $VmName"
Write-Host "WSL distro: $WslDistro"
Write-Host "SkipTerraform: $SkipTerraform"
Write-Host "InstallDeps for tf_vm.ps1: $InstallDeps"

if ($RecoverMultipass) {
  Write-Step "Recover Multipass service (best effort)"
  if (-not (Test-IsAdmin)) {
    Write-Warning "Skipping recover step: not running as Administrator."
    Write-Warning "Tip: run elevated PowerShell if you want automatic Multipass service recovery."
  } else {
    try {
      powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot "scripts\recover_multipass.ps1")
      if ($LASTEXITCODE -ne 0) {
        Write-Warning "recover_multipass.ps1 exited with code $LASTEXITCODE. Continuing pipeline."
      }
    } catch {
      Write-Warning "Recover step failed: $($_.Exception.Message)"
      Write-Warning "Continuing pipeline: Terraform step can recreate broken VM."
    }
  }
}

if (-not $SkipTerraform) {
  Invoke-Step -Title "Terraform apply (create/update VM)" -Action {
    $installDepsValue = "false"
    if ($InstallDeps.IsPresent) { $installDepsValue = "true" }

    $args = @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", $tfScript,
      "-Action", "apply",
      "-AutoApprove",
      "-InstallDeps", $installDepsValue
    )
    & powershell @args
  }
}

Invoke-Step -Title "VM health check via multipass exec" -Action {
  & $multipass exec $VmName -- bash -lc "echo vm-ok && whoami && uptime"
  Assert-LastExit "VM health check"
}

Invoke-Step -Title "Install Docker + Minikube via Ansible (from local machine)" -Action {
  $args = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $ansibleScript,
    "-SkipTerraform",
    "-WslDistro", $WslDistro
  )
  & powershell @args
  Assert-LastExit "Ansible install step"
}

Invoke-Step -Title "Verify Docker/Minikube/Kubernetes in VM" -Action {
  & $multipass exec $VmName -- docker --version
  Assert-LastExit "docker --version check"
  & $multipass exec $VmName -- minikube version
  Assert-LastExit "minikube version check"
  & $multipass exec $VmName -- bash -lc "minikube status || true"
  Assert-LastExit "minikube status check"
  & $multipass exec $VmName -- bash -lc "kubectl get nodes"
  Assert-LastExit "kubectl get nodes check"
}

Write-Host ""
Write-Host "Pipeline completed successfully."
Write-Host "Quick check command:"
Write-Host "  `"$multipass`" exec $VmName -- kubectl get nodes"
