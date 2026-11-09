# Réseau et DNS de cozy-01 côté UniFi (make CLUSTER=cozy-01 unifi-plan / unifi-apply).
# Sans secret : UNIFI_API / UNIFI_API_KEY viennent de cluster.env.

network = {
  name         = "cozy-01"
  vlan_id      = 20 # = proxmox.vlan_tag dans terraform.tfvars
  gateway_cidr = "192.168.20.1/24"
  dhcp_start   = "192.168.20.100"
  dhcp_stop    = "192.168.20.199"
}

root_domain = "cozy-01.alexetnico.com"
# 1re IP du pool COZY_EXTERNAL_IP_RANGE (cluster.env).
ingress_ip = "192.168.20.60"
hostnames  = ["", "dashboard", "api", "grafana", "argocd", "harbor.lab"]
