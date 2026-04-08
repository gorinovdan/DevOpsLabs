locals {
  vm_info = try(jsondecode(file("${path.module}/vm-info.generated.json")), null)
  vm_ip   = try(local.vm_info.ip, null)
}

output "server_id" {
  description = "Created local VM ID"
  value       = try(local.vm_info.id, var.server_name)
}

output "server_name" {
  description = "Created local VM name"
  value       = try(local.vm_info.name, var.server_name)
}

output "server_status" {
  description = "Current local VM status"
  value       = try(lower(local.vm_info.status), null)
}

output "server_main_ipv4" {
  description = "Main IPv4 for SSH"
  value       = local.vm_ip
}

output "server_additional_ipv4" {
  description = "Additional IPv4 (not used for local VM)"
  value       = null
}

output "ssh_command" {
  description = "SSH command to created VM"
  value       = local.vm_ip != null && local.vm_ip != "" ? "ssh ${var.ssh_user}@${local.vm_ip}" : null
}
