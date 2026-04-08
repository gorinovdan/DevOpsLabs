variable "server_name" {
  description = "Local VM name"
  type        = string
  default     = "flowboard-lab-vm"
}

variable "cpu" {
  description = "Number of vCPU"
  type        = number
  default     = 2
}

variable "ram_mb" {
  description = "RAM in MB"
  type        = number
  default     = 2048
}

variable "disk_mb" {
  description = "Disk size in MB"
  type        = number
  default     = 20480
}

variable "ssh_user" {
  description = "SSH user for local VM"
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key_path" {
  description = "Path to local public SSH key"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "multipass_executable" {
  description = "Path to multipass executable on local machine"
  type        = string
  default     = "multipass"
}

variable "multipass_driver" {
  description = "Multipass driver to use (auto, hyperv, virtualbox)"
  type        = string
  default     = "auto"
}
