output "server_ipv4" {
  description = "Public IPv4 of the provisioned server"
  value       = hcloud_server.hermes.ipv4_address
}

output "server_name" {
  description = "Server hostname"
  value       = hcloud_server.hermes.name
}
