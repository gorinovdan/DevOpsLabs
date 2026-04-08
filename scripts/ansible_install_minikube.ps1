param(
  [string]$WslDistro = "Ubuntu",
  [string]$SshUser = "ubuntu",
  [string]$SshPrivateKeyPath = "",
  [switch]$SkipTerraform
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

function Resolve-IacCli {
  if (Get-Command terraform -ErrorAction SilentlyContinue) {
    return "terraform"
  }
  if (Get-Command tofu -ErrorAction SilentlyContinue) {
    return "tofu"
  }
  throw "Neither terraform nor tofu is available in PATH."
}

function Convert-WindowsPathToWsl([string]$pathValue) {
  if (-not $pathValue) { return "" }
  $normalized = $pathValue -replace "\\", "/"
  if ($normalized -match "^([A-Za-z]):/(.*)$") {
    $drive = $matches[1].ToLowerInvariant()
    $rest = $matches[2]
    return "/mnt/$drive/$rest"
  }
  return $normalized
}

function Get-PrivateKeyPathFromTfvars([string]$tfvarsPath) {
  if (-not (Test-Path $tfvarsPath)) { return $null }
  $raw = Get-Content -Raw -Path $tfvarsPath
  if ($raw -match '(?m)^\s*ssh_public_key_path\s*=\s*"([^"]+)"') {
    $pub = $matches[1]
    if ($pub.EndsWith(".pub")) {
      return $pub.Substring(0, $pub.Length - 4)
    }
  }
  return $null
}

function Write-Utf8NoBomFile([string]$pathValue, [string]$content) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($pathValue, $content, $utf8NoBom)
}

function Test-ValidIpv4([string]$value) {
  if ([string]::IsNullOrWhiteSpace($value)) { return $false }
  $trimmed = $value.Trim()
  if ($trimmed -eq "N/A") { return $false }
  return $trimmed -match '^\d{1,3}(\.\d{1,3}){3}$'
}

function Test-IsExcludedVmIp([string]$ip) {
  if (-not (Test-ValidIpv4 $ip)) { return $true }
  $v = $ip.Trim()
  return (
    $v -match '^127\.' -or
    $v -match '^169\.254\.' -or
    $v -match '^172\.17\.' -or
    $v -match '^172\.18\.' -or
    $v -match '^192\.168\.49\.'
  )
}

function Select-PreferredVmIp([string[]]$ips) {
  $valid = @($ips | Where-Object { Test-ValidIpv4 $_ } | ForEach-Object { "$_".Trim() } | Select-Object -Unique)
  if (-not $valid -or $valid.Count -eq 0) { return $null }

  $preferred = @($valid | Where-Object { -not (Test-IsExcludedVmIp $_) })
  if ($preferred.Count -gt 0) { return $preferred[0] }
  return $valid[0]
}

function Get-TerraformOutput([string]$iacCliPath, [string]$tfDirPath, [string]$outputName) {
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $raw = cmd /c "`"$iacCliPath`" -chdir=`"$tfDirPath`" output -raw $outputName" 2>$null
  $exitCode = $LASTEXITCODE
  $ErrorActionPreference = $prevEap

  if ($exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
    return $null
  }
  return $raw.Trim()
}

function Resolve-MultipassPath {
  $mp = Get-Command multipass -ErrorAction SilentlyContinue
  if ($mp) { return $mp.Source }

  $fallback = "C:\Program Files\Multipass\bin\multipass.exe"
  if (Test-Path $fallback) { return $fallback }

  throw "multipass executable not found in PATH and fallback path."
}

function Get-VmIpFromMultipass([string]$multipassPath, [string]$vmName) {
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $rawInfo = & $multipassPath info $vmName --format json 2>$null
  $infoExit = $LASTEXITCODE
  $ErrorActionPreference = $prevEap
  if ($infoExit -eq 0 -and $rawInfo) {
    try {
      $parsedInfo = $rawInfo | ConvertFrom-Json
      if ($parsedInfo.PSObject.Properties.Name -contains 'info') {
        $entry = $parsedInfo.info.$vmName
        if ($entry -and $entry.ipv4 -and $entry.ipv4.Count -gt 0) {
          $candidate = Select-PreferredVmIp -ips $entry.ipv4
          if (Test-ValidIpv4 $candidate) { return $candidate }
        }
      }
    } catch {}
  }

  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $rawList = & $multipassPath list --format json 2>$null
  $listExit = $LASTEXITCODE
  $ErrorActionPreference = $prevEap
  if ($listExit -eq 0 -and $rawList) {
    try {
      $parsedList = $rawList | ConvertFrom-Json
      $entryList = $parsedList.list | Where-Object { $_.name -eq $vmName } | Select-Object -First 1
      if ($entryList -and $entryList.ipv4 -and $entryList.ipv4.Count -gt 0) {
        $candidateList = Select-PreferredVmIp -ips $entryList.ipv4
        if (Test-ValidIpv4 $candidateList) { return $candidateList }
      }
    } catch {}
  }

  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $rawExecRouteIp = & $multipassPath exec $vmName -- sh -lc "ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if(`$i==\"src\") {print `$(i+1); exit}}'" 2>$null
  $routeExit = $LASTEXITCODE
  $ErrorActionPreference = $prevEap
  if ($routeExit -eq 0 -and $rawExecRouteIp) {
    $candidateRoute = "$rawExecRouteIp".Trim()
    if (Test-ValidIpv4 $candidateRoute -and -not (Test-IsExcludedVmIp $candidateRoute)) { return $candidateRoute }
  }

  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $rawExecIps = & $multipassPath exec $vmName -- sh -lc "hostname -I" 2>$null
  $ipsExit = $LASTEXITCODE
  $ErrorActionPreference = $prevEap
  if ($ipsExit -eq 0 -and $rawExecIps) {
    $ips = @("$rawExecIps".Trim().Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries))
    $candidateExec = Select-PreferredVmIp -ips $ips
    if (Test-ValidIpv4 $candidateExec) { return $candidateExec }
  }

  return $null
}

function Get-VmInfoFromMultipass([string]$multipassPath, [string]$vmName) {
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $rawInfo = & $multipassPath info $vmName --format json 2>$null
  $infoExit = $LASTEXITCODE
  $ErrorActionPreference = $prevEap
  if ($infoExit -ne 0 -or -not $rawInfo) { return $null }
  try {
    $parsedInfo = $rawInfo | ConvertFrom-Json
    if ($parsedInfo.PSObject.Properties.Name -contains 'info') {
      return $parsedInfo.info.$vmName
    }
  } catch {}
  return $null
}

function Test-SshReachableFromWsl([string]$wslDistro, [string]$ipAddress, [string]$sshUser, [string]$privateKeyWslPath) {
  if (-not (Test-ValidIpv4 $ipAddress)) { return $false }
  $testCmd = "set -euo pipefail; ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i $privateKeyWslPath $sshUser@$ipAddress 'echo ok' >/dev/null 2>&1"
  wsl -d $wslDistro -- bash -lc $testCmd
  return ($LASTEXITCODE -eq 0)
}

function Test-SshReachableFromWslHostPort(
  [string]$wslDistro,
  [string]$hostName,
  [int]$port,
  [string]$sshUser,
  [string]$privateKeyWslPath
) {
  $testCmd = "set -euo pipefail; ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p $port -i $privateKeyWslPath $sshUser@$hostName 'echo ok' >/dev/null 2>&1"
  wsl -d $wslDistro -- bash -lc $testCmd
  return ($LASTEXITCODE -eq 0)
}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($id)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WslWindowsHostIp([string]$wslDistro) {
  $raw = wsl -d $wslDistro -- bash -lc "ip route show default | cut -d ' ' -f3 | head -n1" 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
  $ip = "$raw".Trim()
  if (Test-ValidIpv4 $ip) { return $ip }
  return $null
}

function Get-VmPrimaryRouteIp([string]$multipassPath, [string]$vmName) {
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $raw = & $multipassPath exec $vmName -- sh -lc "ip -4 route get 1.1.1.1" 2>$null
  $routeExit = $LASTEXITCODE
  $ErrorActionPreference = $prevEap
  if ($routeExit -ne 0 -or -not $raw) { return $null }
  $text = ($raw | Out-String).Trim()
  $m = [regex]::Match($text, '\bsrc\s+(\d{1,3}(?:\.\d{1,3}){3})\b')
  if (-not $m.Success) { return $null }
  $ip = $m.Groups[1].Value
  if (Test-ValidIpv4 $ip -and -not (Test-IsExcludedVmIp $ip)) { return $ip }
  return $null
}

function Try-ConfigureWindowsPortProxy([string]$vmIp) {
  if (-not (Test-ValidIpv4 $vmIp)) { return $null }
  if (-not (Test-IsAdmin)) {
    Write-Warning "Skipping Windows portproxy fallback: script is not running as Administrator."
    return $null
  }

  cmd /c "sc.exe start iphlpsvc" *> $null
  foreach ($port in 2222..2232) {
    $inUse = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
    if ($inUse) { continue }

    $delCmdLoopback = "netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=$port"
    cmd /c $delCmdLoopback *> $null
    $delCmdAny = "netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$port"
    cmd /c $delCmdAny *> $null
    $addCmd = "netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$port connectaddress=$vmIp connectport=22"
    cmd /c $addCmd *> $null
    if ($LASTEXITCODE -eq 0) {
      return $port
    }
  }

  return $null
}

function Resolve-VBoxManagePath {
  $candidate = Join-Path $env:ProgramFiles "Oracle\VirtualBox\VBoxManage.exe"
  if (Test-Path $candidate) { return $candidate }
  $cmd = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  return $null
}

function Get-VBoxVmNames([string]$vboxManage, [switch]$RunningOnly) {
  $mode = if ($RunningOnly) { "runningvms" } else { "vms" }
  $queryCmd = "`"$vboxManage`" list $mode 2>nul"
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $raw = cmd /c $queryCmd
  $ErrorActionPreference = $prevEap
  if ($LASTEXITCODE -ne 0 -or -not $raw) { return @() }

  $names = @()
  foreach ($line in $raw) {
    $text = "$line".Trim()
    if ($text -match '^"([^"]+)"\s+\{[0-9a-fA-F-]+\}$') {
      $names += $Matches[1]
    }
  }
  return $names
}

function Resolve-VBoxVmName([string]$vboxManage, [string]$preferredName) {
  $running = @(Get-VBoxVmNames -vboxManage $vboxManage -RunningOnly)
  if ($running -contains $preferredName) { return $preferredName }
  if ($running.Count -eq 1) { return $running[0] }

  $all = @(Get-VBoxVmNames -vboxManage $vboxManage)
  if ($all -contains $preferredName) { return $preferredName }

  $contains = @($all | Where-Object { $_ -like "*$preferredName*" })
  if ($contains.Count -eq 1) { return $contains[0] }
  if ($all.Count -eq 1) { return $all[0] }

  return $null
}

function Try-ConfigureVBoxSshForward([string]$vmName) {
  $vboxManage = Resolve-VBoxManagePath
  if (-not $vboxManage) { return $null }
  $targetVm = Resolve-VBoxVmName -vboxManage $vboxManage -preferredName $vmName
  if (-not $targetVm) { return $null }
  Write-Host "Using VirtualBox VM '$targetVm' for SSH port-forward."

  $deleteCmd = "`"$vboxManage`" controlvm `"$targetVm`" natpf1 delete ansible-ssh 2>nul"
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  cmd /c $deleteCmd | Out-Null
  $ErrorActionPreference = $prevEap
  foreach ($port in 2222..2232) {
    $inUse = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
    if ($inUse) { continue }
    $addRule = "ansible-ssh,tcp,127.0.0.1,$port,,22"
    $addCmd = "`"$vboxManage`" controlvm `"$targetVm`" natpf1 `"$addRule`" 2>nul"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    cmd /c $addCmd | Out-Null
    $ErrorActionPreference = $prevEap
    if ($LASTEXITCODE -eq 0) {
      return $port
    }
  }
  return $null
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$tfDir = Join-Path $repoRoot "infra\terraform"
$ansibleDir = Join-Path $repoRoot "infra\ansible"
$tfvarsPath = Join-Path $tfDir "terraform.tfvars"
$inventoryPath = Join-Path $ansibleDir "inventory.local.ini"

if (-not $SkipTerraform) {
  Write-Host "Step 1/2: terraform apply (local VM)..."
  powershell -ExecutionPolicy Bypass -File (Join-Path $repoRoot "scripts\tf_vm.ps1") -Action apply -AutoApprove -InstallDeps false
  if ($LASTEXITCODE -ne 0) {
    throw "terraform apply step failed."
  }
}

$iacCli = Resolve-IacCli
$iacCliPath = (Get-Command $iacCli -ErrorAction Stop).Source
$vmName = Get-TerraformOutput -iacCliPath $iacCliPath -tfDirPath $tfDir -outputName "server_name"
if (-not $vmName) { $vmName = "flowboard-lab-vm" }

$vmIpRaw = Get-TerraformOutput -iacCliPath $iacCliPath -tfDirPath $tfDir -outputName "server_main_ipv4"
if ((Test-ValidIpv4 $vmIpRaw) -and (-not (Test-IsExcludedVmIp $vmIpRaw))) {
  $vmIp = $vmIpRaw.Trim()
} else {
  $multipassPath = Resolve-MultipassPath
  $vmIp = $null
  for ($i = 1; $i -le 30; $i++) {
    $vmIp = Get-VmIpFromMultipass -multipassPath $multipassPath -vmName $vmName
    if (Test-ValidIpv4 $vmIp) { break }
    Start-Sleep -Seconds 2
  }

if (-not (Test-ValidIpv4 $vmIp)) {
    throw "Cannot resolve VM IP from Terraform output or Multipass for '$vmName'."
  }
}

if (-not $SshPrivateKeyPath) {
  $fromTfvars = Get-PrivateKeyPathFromTfvars -tfvarsPath $tfvarsPath
  if ($fromTfvars) {
    $SshPrivateKeyPath = $fromTfvars
  }
}

if (-not $SshPrivateKeyPath) {
  $defaultEd25519 = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
  $defaultRsa = Join-Path $env:USERPROFILE ".ssh\id_rsa"
  if (Test-Path $defaultEd25519) {
    $SshPrivateKeyPath = $defaultEd25519
  } elseif (Test-Path $defaultRsa) {
    $SshPrivateKeyPath = $defaultRsa
  }
}

if (-not $SshPrivateKeyPath -or -not (Test-Path $SshPrivateKeyPath)) {
  throw "SSH private key not found. Set -SshPrivateKeyPath explicitly."
}

$inventoryWsl = Convert-WindowsPathToWsl $inventoryPath
$playbookWsl = Convert-WindowsPathToWsl (Join-Path $ansibleDir "playbooks\install_docker.yml")
$playbookViaMultipassWsl = Convert-WindowsPathToWsl (Join-Path $ansibleDir "playbooks\install_docker_via_multipass.yml")
$ansibleCfgWsl = Convert-WindowsPathToWsl (Join-Path $ansibleDir "ansible.cfg")
$winKeyWsl = Convert-WindowsPathToWsl $SshPrivateKeyPath
$wslKeyPath = "~/.ssh/flowboard_vm_key"
$multipassPath = Resolve-MultipassPath
$multipassWsl = Convert-WindowsPathToWsl $multipassPath

Write-Host "Step 2/2: ansible install docker + minikube..."

wsl -d $WslDistro -- bash -lc "command -v ansible-playbook >/dev/null 2>&1"
if ($LASTEXITCODE -ne 0) {
  throw "ansible-playbook not found in WSL distro '$WslDistro'."
}

$vmInfo = Get-VmInfoFromMultipass -multipassPath $multipassPath -vmName $vmName
$directVmIp = $null
if ($vmInfo -and $vmInfo.ipv4 -and $vmInfo.ipv4.Count -gt 0) {
  $candidateIp = Select-PreferredVmIp -ips $vmInfo.ipv4
  if (Test-ValidIpv4 $candidateIp -and -not (Test-IsExcludedVmIp $candidateIp)) {
    $directVmIp = $candidateIp
  }
}

$routeVmIp = Get-VmPrimaryRouteIp -multipassPath $multipassPath -vmName $vmName
if ($routeVmIp) {
  $vmIp = $routeVmIp
  if (-not $directVmIp) { $directVmIp = $routeVmIp }
}

wsl -d $WslDistro -- bash -lc "set -euo pipefail; install -m 700 -d ~/.ssh; cp '$winKeyWsl' $wslKeyPath; chmod 600 $wslKeyPath"
if ($LASTEXITCODE -ne 0) {
  throw "Failed to prepare SSH key inside WSL."
}

$sshHost = $null
$sshPort = 22
$candidateIps = @()
if ($directVmIp) { $candidateIps += $directVmIp }
if ($vmIp -and $vmIp -ne $directVmIp) { $candidateIps += $vmIp }

foreach ($candidate in $candidateIps) {
  if (Test-SshReachableFromWsl -wslDistro $WslDistro -ipAddress $candidate -sshUser $SshUser -privateKeyWslPath $wslKeyPath) {
    $sshHost = $candidate
    $sshPort = 22
    break
  }
}

if (-not $sshHost) {
  if (Test-ValidIpv4 $vmIp) {
    Write-Host "Trying Windows portproxy fallback for SSH..."
    $wslHostIp = Get-WslWindowsHostIp -wslDistro $WslDistro
    $proxyPort = Try-ConfigureWindowsPortProxy -vmIp $vmIp
    if ($proxyPort -and $wslHostIp -and (Test-SshReachableFromWslHostPort -wslDistro $WslDistro -hostName $wslHostIp -port $proxyPort -sshUser $SshUser -privateKeyWslPath $wslKeyPath)) {
      $sshHost = $wslHostIp
      $sshPort = $proxyPort
    }
  }
}

if (-not $sshHost) {
  $driverRaw = & $multipassPath get local.driver 2>$null
  $driver = if ($LASTEXITCODE -eq 0) { "$driverRaw".Trim().ToLowerInvariant() } else { "" }
  if ($driver -eq "virtualbox") {
    Write-Host "Direct SSH is not reachable, trying VirtualBox NAT port-forward for SSH..."
    $forwardPort = Try-ConfigureVBoxSshForward -vmName $vmName
    if ($forwardPort -and (Test-SshReachableFromWslHostPort -wslDistro $WslDistro -hostName "127.0.0.1" -port $forwardPort -sshUser $SshUser -privateKeyWslPath $wslKeyPath)) {
      $sshHost = "127.0.0.1"
      $sshPort = $forwardPort
    }
  }
}

if (-not $sshHost) {
  Write-Host "SSH path is not reachable. Switching to local Ansible + multipass exec mode..."
  wsl -d $WslDistro -- bash -lc "set -euo pipefail; FLOWBOARD_VM_NAME='$vmName' FLOWBOARD_VM_USER='$SshUser' FLOWBOARD_MULTIPASS_BIN='$multipassWsl' ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i 'localhost,' '$playbookViaMultipassWsl'"
  if ($LASTEXITCODE -ne 0) {
    throw "Ansible playbook failed in local-multipass mode."
  }
  Write-Utf8NoBomFile -pathValue $inventoryPath -content "[app]`nlocalhost ansible_connection=local ansible_user=$SshUser`n"
  Write-Host ""
  Write-Host "Completed successfully."
  Write-Host "VM IP: $vmIp"
  Write-Host "Inventory: $inventoryPath"
  return
}

Write-Utf8NoBomFile -pathValue $inventoryPath -content "[app]`n$sshHost ansible_user=$SshUser ansible_port=$sshPort`n"
wsl -d $WslDistro -- bash -lc "set -euo pipefail; ANSIBLE_CONFIG='$ansibleCfgWsl' ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i '$inventoryWsl' '$playbookWsl' --private-key $wslKeyPath"
if ($LASTEXITCODE -ne 0) {
  throw "Ansible playbook failed via host-side SSH mode."
}

Write-Host ""
Write-Host "Completed successfully."
Write-Host "VM IP: $vmIp"
Write-Host "Inventory: $inventoryPath"
