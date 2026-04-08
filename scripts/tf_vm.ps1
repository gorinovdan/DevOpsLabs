param(
  [ValidateSet('init','validate','plan','apply','destroy')]
  [string]$Action = 'apply',
  [switch]$AutoApprove,
  [object]$InstallDeps = $true
)

$ErrorActionPreference = 'Stop'
$script:IacCmd = $null
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

function Convert-ToBool([object]$Value, [string]$ParamName) {
  if ($Value -is [bool]) { return $Value }
  if ($Value -is [int]) { return [bool]$Value }
  if ($null -eq $Value) { return $false }

  $text = "$Value".Trim().ToLowerInvariant()
  if ($text -in @('1','true','$true','yes','y','on')) { return $true }
  if ($text -in @('0','false','$false','no','n','off')) { return $false }

  throw "Invalid value for -${ParamName}: '$Value'. Use true/false or 1/0."
}

function Refresh-UserPath {
  $userPath = [Environment]::GetEnvironmentVariable('Path','User')
  if ($userPath) {
    $env:Path = "$userPath;$env:Path"
  }
}

function Convert-ToTerraformPath([string]$PathValue) {
  return ($PathValue -replace '\\','/')
}

function Get-DefaultSshPublicKeyPath {
  $candidates = @(
    "$env:USERPROFILE\.ssh\id_ed25519.pub",
    "$env:USERPROFILE\.ssh\id_rsa.pub"
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path $candidate)) {
      return (Resolve-Path $candidate).Path
    }
  }
  return $null
}

function Ensure-LocalSshKey {
  $sshDir = Join-Path $env:USERPROFILE '.ssh'
  if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
  }

  $pubPath = Get-DefaultSshPublicKeyPath
  if ($pubPath) { return $pubPath }

  if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    throw "SSH public key not found in $sshDir and ssh-keygen is unavailable. Generate key manually and retry."
  }

  $privateKey = Join-Path $sshDir 'id_ed25519'
  Write-Host "Generating SSH key pair at $privateKey ..."
  cmd /c "ssh-keygen -t ed25519 -N `"`" -f `"$privateKey`"" | Out-Null

  $generatedPub = "$privateKey.pub"
  if (-not (Test-Path $generatedPub)) {
    throw "Failed to generate SSH public key: $generatedPub"
  }

  return (Resolve-Path $generatedPub).Path
}

function Ensure-Winget {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget is required for dependency auto-install and is not available.'
  }
}

function Ensure-Multipass {
  if (Get-Command multipass -ErrorAction SilentlyContinue) { return }
  Ensure-Winget
  Write-Host 'Installing Multipass via winget...'
  winget install -e --id Canonical.Multipass --accept-package-agreements --accept-source-agreements
  Refresh-UserPath
  if (-not (Get-Command multipass -ErrorAction SilentlyContinue)) {
    $fallback = 'C:\Program Files\Multipass\bin\multipass.exe'
    if (-not (Test-Path $fallback)) {
      throw 'multipass installation did not expose command in PATH and fallback binary path does not exist.'
    }
  }
}

function Get-MultipassExecutablePath {
  $cmd = Get-Command multipass -ErrorAction SilentlyContinue
  if ($cmd) {
    return $cmd.Source
  }

  $fallback = 'C:\Program Files\Multipass\bin\multipass.exe'
  if (Test-Path $fallback) {
    return $fallback
  }

  throw 'multipass executable not found. Install Multipass and retry.'
}

function Get-RecommendedMultipassDriver {
  $hyperV = Get-CimInstance Win32_OptionalFeature -Filter "Name='Microsoft-Hyper-V-All'" -ErrorAction SilentlyContinue
  if ($hyperV -and $hyperV.InstallState -eq 1) {
    return 'hyperv'
  }

  $vboxManage = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
  if (Test-Path $vboxManage) {
    return 'virtualbox'
  }

  return 'auto'
}

function Ensure-IacCli {
  if (Get-Command terraform -ErrorAction SilentlyContinue) {
    $script:IacCmd = 'terraform'
    return
  }

  if (Get-Command tofu -ErrorAction SilentlyContinue) {
    $script:IacCmd = 'tofu'
    return
  }

  Ensure-Winget
  Write-Host 'Installing Terraform via winget...'
  try {
    winget install -e --id Hashicorp.Terraform --accept-package-agreements --accept-source-agreements
  } catch {
    Write-Warning "winget Terraform install failed: $($_.Exception.Message)"
  }

  Refresh-UserPath
  if (Get-Command terraform -ErrorAction SilentlyContinue) {
    $script:IacCmd = 'terraform'
    return
  }

  Write-Warning 'Terraform is unavailable. Trying OpenTofu fallback...'
  try {
    winget install -e --id OpenTofu.Tofu --accept-package-agreements --accept-source-agreements
  } catch {
    Write-Warning "winget OpenTofu install failed: $($_.Exception.Message)"
  }

  Refresh-UserPath
  if (Get-Command tofu -ErrorAction SilentlyContinue) {
    $script:IacCmd = 'tofu'
    return
  }

  throw 'Neither terraform nor tofu is available. Install one of them manually and re-run.'
}

function Assert-MultipassReachable([string]$MultipassPath) {
  $probeOutput = cmd /c "`"$MultipassPath`" list --format json 2>&1"
  $probeExitCode = $LASTEXITCODE

  if ($probeExitCode -eq 0) { return }

  $probeText = ($probeOutput | Out-String).Trim()
  throw @"
Multipass daemon is not reachable from this shell.
Executable: $MultipassPath
Output: $probeText

Open an elevated PowerShell (Run as Administrator) and verify:
  "$MultipassPath" list

If it still fails, restart Multipass service or sign out/in after installation.
"@
}

function Get-MultipassCurrentDriver([string]$MultipassPath) {
  $driverOut = cmd /c "`"$MultipassPath`" get local.driver 2>&1"
  if ($LASTEXITCODE -ne 0) {
    return $null
  }
  return "$driverOut".Trim().ToLowerInvariant()
}

function Assert-MultipassBackendReady([string]$MultipassPath, [string]$ConfiguredDriver) {
  $currentDriver = Get-MultipassCurrentDriver -MultipassPath $MultipassPath
  if (-not $currentDriver) { return }

  if ($ConfiguredDriver -and $ConfiguredDriver -ne 'auto' -and $currentDriver -ne $ConfiguredDriver) {
    Write-Warning "Configured multipass_driver='$ConfiguredDriver' but current Multipass driver is '$currentDriver'."
  }

  switch ($currentDriver) {
    'virtualbox' {
      $vboxManage = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
      if (-not (Test-Path $vboxManage)) {
        throw @"
Multipass driver is 'virtualbox', but VBoxManage.exe was not found:
  $vboxManage

Fix options:
1) Install VirtualBox:
   winget install -e --id Oracle.VirtualBox
2) Or switch driver to Hyper-V (if installed):
   "$MultipassPath" set local.driver=hyperv
"@
      }
    }
    'hyperv' {
      $feature = Get-CimInstance Win32_OptionalFeature -Filter "Name='Microsoft-Hyper-V-All'" -ErrorAction SilentlyContinue
      if ($null -eq $feature -or $feature.InstallState -ne 1) {
        throw @"
Multipass driver is 'hyperv', but Hyper-V is not enabled.

Enable Hyper-V (Administrator shell), reboot, then retry:
  dism /online /enable-feature /featurename:Microsoft-Hyper-V-All /all /norestart
"@
      }
    }
    default {
      Write-Host "Multipass driver: $currentDriver"
    }
  }
}

function Get-MultipassVmInfo([string]$MultipassPath, [string]$VmName, [int]$WaitIpSeconds = 60) {
  $attempts = [Math]::Max(1, [int][Math]::Ceiling($WaitIpSeconds / 2.0))
  for ($attempt = 1; $attempt -le $attempts; $attempt++) {
    $raw = cmd /c "`"$MultipassPath`" list --format json"
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to get VM list from Multipass."
    }

    $parsed = $raw | ConvertFrom-Json
    $entry = $parsed.list | Where-Object { $_.name -eq $VmName } | Select-Object -First 1
    if ($null -eq $entry) {
      throw "VM '$VmName' not found in Multipass list."
    }

    $ip = $null
    if ($entry.ipv4 -and $entry.ipv4.Count -gt 0) {
      $ip = $entry.ipv4[0]
    }

    if ($ip -or $attempt -eq $attempts) {
      return @{
        name   = $entry.name
        status = $entry.state
        ip     = $ip
      }
    }

    Start-Sleep -Seconds 2
  }
}

function Test-MultipassVmPresent([string]$MultipassPath, [string]$VmName) {
  $raw = cmd /c "`"$MultipassPath`" list --format json 2>&1"
  if ($LASTEXITCODE -ne 0) { return $false }

  try {
    $parsed = $raw | ConvertFrom-Json
  } catch {
    return $false
  }

  $entry = $parsed.list | Where-Object { $_.name -eq $VmName } | Select-Object -First 1
  return ($null -ne $entry)
}

function Test-MultipassVmExec([string]$MultipassPath, [string]$VmName, [int]$Retries = 4) {
  for ($attempt = 1; $attempt -le $Retries; $attempt++) {
    $startOut = cmd /c "`"$MultipassPath`" start `"$VmName`" 2>&1"
    $startExit = $LASTEXITCODE

    $execOut = cmd /c "`"$MultipassPath`" exec `"$VmName`" -- bash -lc `"echo vm-ok`" 2>&1"
    $execExit = $LASTEXITCODE

    if ($startExit -eq 0 -and $execExit -eq 0) {
      return $true
    }

    if ($attempt -eq $Retries) {
      $startText = ($startOut | Out-String).Trim()
      $execText = ($execOut | Out-String).Trim()
      Write-Warning "Multipass exec probe failed for '$VmName'. start_exit=$startExit exec_exit=$execExit"
      if ($startText) { Write-Warning "start output: $startText" }
      if ($execText) { Write-Warning "exec output: $execText" }
    }

    Start-Sleep -Seconds 3
  }
  return $false
}

function Repair-LegacyTfvars([string]$TfVarsPath, [string]$SshPubKeyPath) {
  if (-not (Test-Path $TfVarsPath)) { return }

  $content = Get-Content -Path $TfVarsPath -Raw
  $legacyKeys = @(
    'server_comment',
    'location',
    'os_name',
    'os_version',
    'project_id',
    'ssh_key_name'
  )

  $hasLegacy = $false
  foreach ($legacyKey in $legacyKeys) {
    if ($content -match "(?m)^\s*$legacyKey\s*=") {
      $hasLegacy = $true
      break
    }
  }

  if (-not $hasLegacy) { return }

  $backup = "$TfVarsPath.legacy.bak"
  Copy-Item -Path $TfVarsPath -Destination $backup -Force
  Write-Warning "Detected legacy cloud tfvars in $TfVarsPath. Backup saved to $backup"

  $serverName = 'flowboard-lab-vm'
  if ($content -match '(?m)^\s*server_name\s*=\s*"([^"]+)"') { $serverName = $Matches[1] }

  $cpu = 2
  if ($content -match '(?m)^\s*cpu\s*=\s*([0-9]+)') { $cpu = [int]$Matches[1] }

  $ram = 2048
  if ($content -match '(?m)^\s*ram_mb\s*=\s*([0-9]+)') { $ram = [int]$Matches[1] }

  $disk = 20480
  if ($content -match '(?m)^\s*disk_mb\s*=\s*([0-9]+)') { $disk = [int]$Matches[1] }

  $sshUser = 'ubuntu'
  if ($content -match '(?m)^\s*ssh_user\s*=\s*"([^"]+)"') { $sshUser = $Matches[1] }

  $normalizedPub = Convert-ToTerraformPath $SshPubKeyPath
  @"
server_name = "$serverName"
cpu = $cpu
ram_mb = $ram
disk_mb = $disk
ssh_user = "$sshUser"
ssh_public_key_path = "$normalizedPub"
"@ | Set-Content -Path $TfVarsPath -Encoding UTF8
}

function Disable-AutoTfvars([string]$TfAutoVarsPath) {
  if (-not (Test-Path $TfAutoVarsPath)) { return }

  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup = "$TfAutoVarsPath.disabled.$timestamp.bak"
  Move-Item -Path $TfAutoVarsPath -Destination $backup -Force
  Write-Warning "Disabled terraform.auto.tfvars to avoid hidden overrides. Backup saved to $backup"
}

function Ensure-CurrentTfvars([string]$TfVarsPath, [string]$SshPubKeyPath, [string]$MultipassPath, [string]$MultipassDriver) {
  $normalizedPub = Convert-ToTerraformPath $SshPubKeyPath
  $normalizedMultipass = Convert-ToTerraformPath $MultipassPath
  $expectedLine = "ssh_public_key_path = `"$normalizedPub`""
  $expectedMultipassLine = "multipass_executable = `"$normalizedMultipass`""
  $expectedDriverLine = "multipass_driver = `"$MultipassDriver`""

  if (-not (Test-Path $TfVarsPath)) {
    @"
server_name = "flowboard-lab-vm"
cpu = 2
ram_mb = 2048
disk_mb = 20480
ssh_user = "ubuntu"
$expectedLine
$expectedMultipassLine
$expectedDriverLine
"@ | Set-Content -Path $TfVarsPath -Encoding UTF8
    return
  }

  $content = Get-Content -Path $TfVarsPath -Raw
  if ($content -notmatch '(?m)^\s*ssh_public_key_path\s*=') {
    $content = "$content`r`n$expectedLine`r`n"
  } else {
    $content = [regex]::Replace(
      $content,
      '(?m)^\s*ssh_public_key_path\s*=.*$',
      $expectedLine
    )
  }
  $updated = $content
  if ($updated -notmatch '(?m)^\s*multipass_executable\s*=') {
    $updated = "$updated`r`n$expectedMultipassLine`r`n"
  } else {
    $updated = [regex]::Replace(
      $updated,
      '(?m)^\s*multipass_executable\s*=.*$',
      $expectedMultipassLine
    )
  }
  if ($updated -notmatch '(?m)^\s*multipass_driver\s*=') {
    $updated = "$updated`r`n$expectedDriverLine`r`n"
  }
  if ($updated -ne $content) {
    Set-Content -Path $TfVarsPath -Value $updated -Encoding UTF8
  }
}

function Cleanup-LegacyState([string]$TfDir) {
  $stateFile = Join-Path $TfDir 'terraform.tfstate'
  if (-not (Test-Path $stateFile)) { return }

  $stateContent = Get-Content -Path $stateFile -Raw
  $hasLegacyProviders = (
    $stateContent -match 'tf\.timeweb\.cloud' -or
    $stateContent -match '"type":"null_resource"' -or
    $stateContent -match '"type":"local_file"' -or
    $stateContent -match '"type":"external"' -or
    $stateContent -match 'registry\.opentofu\.org/hashicorp/(null|local|external)' -or
    $stateContent -match 'registry\.terraform\.io/hashicorp/(null|local|external)'
  )

  if (-not $hasLegacyProviders) { return }

  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $stateBackup = Join-Path $TfDir "terraform.tfstate.legacy.$timestamp.bak"
  Move-Item -Path $stateFile -Destination $stateBackup -Force
  Write-Warning "Moved legacy provider-based state to $stateBackup"

  $stateBackupFile = Join-Path $TfDir 'terraform.tfstate.backup'
  if (Test-Path $stateBackupFile) {
    Move-Item -Path $stateBackupFile -Destination "$stateBackupFile.legacy.$timestamp.bak" -Force
  }

  $tfCache = Join-Path $TfDir '.terraform'
  if (Test-Path $tfCache) {
    Remove-Item -Path $tfCache -Recurse -Force
  }

  $lockFile = Join-Path $TfDir '.terraform.lock.hcl'
  if (Test-Path $lockFile) {
    Remove-Item -Path $lockFile -Force
  }
}

$installDepsEnabled = Convert-ToBool -Value $InstallDeps -ParamName 'InstallDeps'
Refresh-UserPath

if ($installDepsEnabled) {
  Ensure-Multipass
  Ensure-IacCli
}

$null = Get-MultipassExecutablePath
if (-not $script:IacCmd) {
  if (Get-Command terraform -ErrorAction SilentlyContinue) {
    $script:IacCmd = 'terraform'
  } elseif (Get-Command tofu -ErrorAction SilentlyContinue) {
    $script:IacCmd = 'tofu'
  }
}
if (-not $script:IacCmd) {
  throw 'terraform/tofu is not installed or not in PATH.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tfDir = Join-Path $repoRoot 'infra\terraform'
$tfvars = Join-Path $tfDir 'terraform.tfvars'
$tfvarsExample = Join-Path $tfDir 'terraform.tfvars.example'
$tfAutoVars = Join-Path $tfDir 'terraform.auto.tfvars'

if (-not (Test-Path $tfvars) -and (Test-Path $tfvarsExample)) {
  Copy-Item $tfvarsExample $tfvars
  Write-Warning 'terraform.tfvars was missing. Created from terraform.tfvars.example. Review values before apply.'
}

$sshPubPath = Ensure-LocalSshKey
$multipassExePath = Get-MultipassExecutablePath
$recommendedMultipassDriver = Get-RecommendedMultipassDriver
Repair-LegacyTfvars -TfVarsPath $tfvars -SshPubKeyPath $sshPubPath
Disable-AutoTfvars -TfAutoVarsPath $tfAutoVars
Ensure-CurrentTfvars -TfVarsPath $tfvars -SshPubKeyPath $sshPubPath -MultipassPath $multipassExePath -MultipassDriver $recommendedMultipassDriver
Cleanup-LegacyState -TfDir $tfDir

$vmName = 'flowboard-lab-vm'
$sshUser = 'ubuntu'
$multipassDriver = 'auto'
$tfvarsContent = Get-Content -Path $tfvars -Raw
if ($tfvarsContent -match '(?m)^\s*server_name\s*=\s*"([^"]+)"') {
  $vmName = $Matches[1]
}
if ($tfvarsContent -match '(?m)^\s*ssh_user\s*=\s*"([^"]+)"') {
  $sshUser = $Matches[1]
}
if ($tfvarsContent -match '(?m)^\s*multipass_driver\s*=\s*"([^"]+)"') {
  $multipassDriver = $Matches[1].ToLowerInvariant()
}

function Invoke-Iac([string[]]$cliArgs) {
  & $script:IacCmd ("-chdir=" + $tfDir) @cliArgs
  if ($LASTEXITCODE -ne 0) { throw "IaC command failed: $script:IacCmd $($cliArgs -join ' ')" }
}

Write-Host "Using IaC CLI: $script:IacCmd"
Invoke-Iac @('init','-input=false')

switch ($Action) {
  'init' { return }
  'validate' {
    Invoke-Iac @('validate')
    return
  }
  'plan' {
    Invoke-Iac @('validate')
    Invoke-Iac @('plan','-input=false')
    return
  }
  'apply' {
    Assert-MultipassReachable -MultipassPath $multipassExePath
    Assert-MultipassBackendReady -MultipassPath $multipassExePath -ConfiguredDriver $multipassDriver

    $mustReplaceVm = $false
    if (-not (Test-MultipassVmPresent -MultipassPath $multipassExePath -VmName $vmName)) {
      Write-Warning "VM '$vmName' is missing in Multipass list, forcing recreation."
      $mustReplaceVm = $true
    } elseif (-not (Test-MultipassVmExec -MultipassPath $multipassExePath -VmName $vmName)) {
      Write-Warning "VM '$vmName' exists but multipass exec is unreachable, forcing recreation."
      $mustReplaceVm = $true
    }

    Invoke-Iac @('validate')

    $applyArgs = @('apply','-input=false')
    if ($AutoApprove) {
      $applyArgs += '-auto-approve'
    }
    if ($mustReplaceVm) {
      $applyArgs += '-replace=terraform_data.vm'
      Write-Host "Applying with forced replacement: terraform_data.vm"
    }

    Invoke-Iac $applyArgs
    if (-not (Test-MultipassVmExec -MultipassPath $multipassExePath -VmName $vmName -Retries 6)) {
      throw "VM '$vmName' was applied but multipass exec is still unreachable."
    }

    $vmInfo = Get-MultipassVmInfo -MultipassPath $multipassExePath -VmName $vmName
    $ip = $vmInfo.ip
    $status = $vmInfo.status
    $ssh = $null
    if ($ip) { $ssh = "ssh ${sshUser}@${ip}" }
    Write-Host "VM name: $($vmInfo.name)"
    Write-Host "VM status: $status"
    Write-Host "VM IP: $ip"
    if ($ssh) {
      Write-Host "SSH: $ssh"
    }
    return
  }
  'destroy' {
    Assert-MultipassReachable -MultipassPath $multipassExePath
    Assert-MultipassBackendReady -MultipassPath $multipassExePath -ConfiguredDriver $multipassDriver
    if ($AutoApprove) {
      Invoke-Iac @('destroy','-input=false','-auto-approve')
    } else {
      Invoke-Iac @('destroy','-input=false')
    }
    return
  }
}


