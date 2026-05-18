terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_ssh_key" "deployer" {
  name       = "${var.server_name}-deployer"
  public_key = var.ssh_public_key
}

resource "hcloud_firewall" "provisioning" {
  count = var.cloud_firewall_enabled ? 1 : 0
  name  = "${var.server_name}-provisioning"

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = var.deployer_ip != "" ? ["${var.deployer_ip}/32"] : []
  }
}

resource "hcloud_server" "hermes" {
  name        = var.server_name
  server_type = var.server_type
  location    = var.location
  image       = var.os_type
  ssh_keys    = [hcloud_ssh_key.deployer.id]

  dynamic "firewall_ids" {
    for_each = var.cloud_firewall_enabled ? [hcloud_firewall.provisioning[0].id] : []
    content {
      id = firewall_ids.value
    }
  }
}
