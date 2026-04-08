param(
  [string]$VmName = "flowboard-lab-vm"
)

$ErrorActionPreference = "Stop"
$scriptVersion = "2026-04-07.2"
Write-Host "recover_multipass.ps1 version: $scriptVersion"

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

if (-not (Test-IsAdmin)) {
  throw "Run this script from Administrator PowerShell."
}

$multipassExe = Get-MultipassExe

Write-Host "Stopping Multipass service/processes..."
cmd /c "sc.exe stop Multipass" *> $null
Get-Process multipass,multipassd -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
for ($i = 1; $i -le 8; $i++) {
  $status = cmd /c "sc.exe query Multipass" 2>$null
  if (($status | Out-String) -match "STATE\s*:\s*1\s+STOPPED") { break }
  Start-Sleep -Seconds 1
}

Write-Host "Starting Multipass service..."
cmd /c "sc.exe start Multipass" *> $null

$healthy = $false
for ($i = 1; $i -le 15; $i++) {
  & $multipassExe list --format json *> $null
  if ($LASTEXITCODE -eq 0) {
    $healthy = $true
    break
  }
  Write-Host "Waiting for multipass socket... ($i/15)"
  Start-Sleep -Seconds 2
}

if (-not $healthy) {
  throw "Multipass daemon still unreachable. Reboot Windows and retry."
}

Write-Host "Multipass service is healthy."
Write-Host "Trying VM start + exec check..."
& $multipassExe start $VmName
& $multipassExe exec $VmName -- bash -lc "echo ok && whoami"

if ($LASTEXITCODE -ne 0) {
  throw "VM exec check failed for '$VmName'."
}

Write-Host ""
Write-Host "Recovery done."
