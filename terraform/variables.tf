variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "server_type" {
  description = "Hetzner server type"
  type        = string
  default     = "cx23"
}

variable "location" {
  description = "Hetzner location"
  type        = string
  default     = "fsn1"
}

variable "os_type" {
  description = "OS image to use"
  type        = string
  default     = "ubuntu-24.04"
}

variable "server_name" {
  description = "Server hostname"
  type        = string
  default     = "hermes"
}

variable "ssh_public_key" {
  description = "Public SSH key for initial access"
  type        = string
}

variable "cloud_firewall_enabled" {
  description = "Create Hetzner Cloud Firewall allowing SSH only from deployer IP"
  type        = bool
  default     = false
}

variable "deployer_ip" {
  description = "Deployer IP for cloud firewall SSH rule (required if cloud_firewall_enabled)"
  type        = string
  default     = ""
}
