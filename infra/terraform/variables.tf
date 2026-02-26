variable "twc_token" {
  description = "Timeweb Cloud API token. If empty, provider uses TWC_TOKEN from environment."
  type        = string
  sensitive   = true
  default     = ""
}

variable "server_name" {
  description = "VM name in Timeweb Cloud"
  type        = string
  default     = "flowboard-lab-vm"
}

variable "server_comment" {
  description = "VM comment in Timeweb Cloud"
  type        = string
  default     = "Created by Terraform for DevOps Lab"
}

variable "location" {
  description = "Server location"
  type        = string
  default     = "ru-1"
}

variable "os_name" {
  description = "OS name filter for VM"
  type        = string
  default     = "ubuntu"
}

variable "os_version" {
  description = "OS version filter for VM"
  type        = string
  default     = "24.04"
}

variable "cpu" {
  description = "Number of vCPU"
  type        = number
  default     = 1
}

variable "ram_mb" {
  description = "RAM in MB"
  type        = number
  default     = 1024
}

variable "disk_mb" {
  description = "Root disk in MB"
  type        = number
  default     = 15360
}

variable "project_id" {
  description = "Optional existing Timeweb project ID"
  type        = string
  default     = ""
}

variable "ssh_key_name" {
  description = "Name for SSH key resource in Timeweb"
  type        = string
  default     = "flowboard-lab-key"
}

variable "ssh_public_key_path" {
  description = "Path to local public SSH key"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}
