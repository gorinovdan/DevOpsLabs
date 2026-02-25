data "twc_configurator" "main" {
  location = var.location
}

data "twc_os" "main" {
  name    = var.os_name
  version = var.os_version
}

resource "twc_ssh_key" "main" {
  name = var.ssh_key_name
  body = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

resource "twc_server" "vm" {
  name    = var.server_name
  comment = var.server_comment

  os_id = tonumber(data.twc_os.main.id)

  project_id = var.project_id != "" ? tonumber(var.project_id) : null

  ssh_keys_ids = [tonumber(twc_ssh_key.main.id)]

  configuration {
    configurator_id = tonumber(data.twc_configurator.main.id)
    cpu             = var.cpu
    ram             = var.ram_mb
    disk            = var.disk_mb
  }
}

resource "twc_server_ip" "public_ipv4" {
  source_server_id = tonumber(twc_server.vm.id)
  type             = "ipv4"
}
