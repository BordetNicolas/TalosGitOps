resource "unifi_network" "cluster" {
  name    = var.network.name
  purpose = "corporate"

  subnet  = var.network.gateway_cidr
  vlan_id = var.network.vlan_id

  dhcp_enabled = true
  dhcp_start   = var.network.dhcp_start
  dhcp_stop    = var.network.dhcp_stop
}

locals {
  fqdns = {
    for h in var.hostnames :
    (h == "" ? var.root_domain : "${h}.${var.root_domain}") => var.ingress_ip
  }
}

resource "unifi_dns_record" "cluster" {
  for_each = local.fqdns

  name   = each.key
  type   = "A"
  record = each.value
}
