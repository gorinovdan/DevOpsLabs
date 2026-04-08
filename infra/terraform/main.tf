locals {
  cloud_init_content = templatefile("${path.module}/cloud-init.tftpl", {
    ssh_user       = var.ssh_user
    ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  })
}

resource "terraform_data" "vm" {
  input = {
    server_name           = var.server_name
    cpu                   = var.cpu
    ram_mb                = var.ram_mb
    disk_mb               = var.disk_mb
    ssh_user              = var.ssh_user
    multipass_executable  = var.multipass_executable
    multipass_driver      = var.multipass_driver
    cloud_init_content    = local.cloud_init_content
    vm_info_path          = "${path.module}/vm-info.generated.json"
    cloud_init_file_path  = "${path.module}/cloud-init.generated.yaml"
  }

  triggers_replace = [
    var.server_name,
    tostring(var.cpu),
    tostring(var.ram_mb),
    tostring(var.disk_mb),
    var.ssh_user,
    var.multipass_executable,
    var.multipass_driver,
    sha256(local.cloud_init_content),
  ]

  provisioner "local-exec" {
    interpreter = ["powershell.exe", "-NoProfile", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = 'Stop'
      $name = '${var.server_name}'
      $multipass = '${replace(var.multipass_executable, "\\", "\\\\")}'
      $driver = '${var.multipass_driver}'
      $cloudInitPath = '${replace(path.module, "\\", "\\\\")}\\cloud-init.generated.yaml'
      $vmInfoPath = '${replace(path.module, "\\", "\\\\")}\\vm-info.generated.json'

      if ($driver -and $driver -ne 'auto') {
        & $multipass set "local.driver=$driver"
      }

      @'
${replace(local.cloud_init_content, "\r", "")}
'@ | Set-Content -Path $cloudInitPath -Encoding UTF8

      $raw = & $multipass list --format json | ConvertFrom-Json
      $exists = $raw.list | Where-Object { $_.name -eq $name } | Select-Object -First 1
      if ($null -eq $exists) {
        & $multipass launch --name $name --cpus ${var.cpu} --memory ${var.ram_mb}M --disk ${var.disk_mb}M --cloud-init $cloudInitPath
      } else {
        Write-Host "Multipass VM '$name' already exists, skipping launch."
      }

      $rawAfter = & $multipass list --format json | ConvertFrom-Json
      $entry = $rawAfter.list | Where-Object { $_.name -eq $name } | Select-Object -First 1
      if ($null -eq $entry) {
        throw "Multipass VM '$name' not found after apply"
      }

      $ip = $null
      if ($entry.ipv4 -and $entry.ipv4.Count -gt 0) {
        $ip = $entry.ipv4[0]
      }

      @{
        id     = $name
        name   = $name
        status = $entry.state
        ip     = $ip
      } | ConvertTo-Json -Compress | Set-Content -Path $vmInfoPath -Encoding UTF8
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["powershell.exe", "-NoProfile", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = 'Stop'
      $name = '${self.input.server_name}'
      $multipass = '${replace(self.input.multipass_executable, "\\", "\\\\")}'
      $driver = '${self.input.multipass_driver}'
      $vmInfoPath = '${replace(path.module, "\\", "\\\\")}\\vm-info.generated.json'
      $cloudInitPath = '${replace(path.module, "\\", "\\\\")}\\cloud-init.generated.yaml'

      if ($driver -and $driver -ne 'auto') {
        & $multipass set "local.driver=$driver"
      }

      $raw = & $multipass list --format json | ConvertFrom-Json
      $exists = $raw.list | Where-Object { $_.name -eq $name } | Select-Object -First 1
      if ($null -ne $exists) {
        & $multipass stop $name
        & $multipass delete $name
        & $multipass purge
      } else {
        Write-Host "Multipass VM '$name' not found, nothing to destroy."
      }

      if (Test-Path $vmInfoPath) {
        Remove-Item -Path $vmInfoPath -Force
      }
      if (Test-Path $cloudInitPath) {
        Remove-Item -Path $cloudInitPath -Force
      }
    EOT
  }
}
