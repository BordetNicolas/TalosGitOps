output "network_id" {
  value = unifi_network.cluster.id
}

output "dns_records" {
  value = local.fqdns
}
