variable "network" {
  description = "VLAN du cluster côté UniFi (réseau « corporate » avec DHCP)."
  type = object({
    name = string
    # 1-4094, doit être égal à proxmox.vlan_tag dans clusters/<name>/terraform.tfvars.
    vlan_id = number
    # IP de la passerelle UniFi + masque : 192.168.20.1/24 définit le sous-réseau 192.168.20.0/24.
    gateway_cidr = string
    # Plage DHCP des VM ; tout ce qui est hors plage (VIP API, pool MetalLB) reste statique.
    dhcp_start = string
    dhcp_stop  = string
  })
}

variable "root_domain" {
  description = "Domaine racine publié par Cozystack (publishing.host)."
  type        = string
}

variable "ingress_ip" {
  description = "IP de l'ingress de tenant-root (1re IP du pool MetalLB)."
  type        = string
}

variable "hostnames" {
  description = "Sous-domaines de root_domain résolus vers ingress_ip. \"\" = le domaine racine lui-même."
  type        = list(string)
  default     = ["", "dashboard", "api", "grafana", "argocd"]
}
