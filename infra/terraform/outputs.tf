output "server_id" {
  description = "Created VM ID"
  value       = twc_server.vm.id
}

output "server_name" {
  description = "Created VM name"
  value       = twc_server.vm.name
}

output "server_status" {
  description = "Current VM status"
  value       = twc_server.vm.status
}

output "server_main_ipv4" {
  description = "Main public IPv4 for SSH"
  value       = try(twc_server.vm.main_ipv4, twc_server_ip.public_ipv4.ip)
}

output "server_additional_ipv4" {
  description = "Additional public IPv4 allocated for VM"
  value       = twc_server_ip.public_ipv4.ip
}

output "ssh_command" {
  description = "SSH command to created VM"
  value       = try(twc_server_ip.public_ipv4.ip, null) != null ? "ssh root@${twc_server_ip.public_ipv4.ip}" : (twc_server.vm.main_ipv4 != null ? "ssh root@${twc_server.vm.main_ipv4}" : null)
}
