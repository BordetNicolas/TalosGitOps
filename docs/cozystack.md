# Cluster Cozystack (cozy-01)

Cluster Kubernetes Talos (3 CP + 5 workers) sur Proxmox avec la plateforme
[Cozystack](https://cozystack.io) v1.7.0, piloté par le même modèle GitOps que `talos-02`
(`PLATFORM_FLAVOR=cozystack` dans `cluster.env`).

## Ce qui change par rapport à `talos-02`

| Sujet | `talos-02` (standard) | `cozy-01` (cozystack) |
|---|---|---|
| CNI | Cilium inline Talos | Cilium + Kube-OVN installés par Cozystack |
| LB / ingress / stockage / monitoring | MetalLB, ingress-nginx, Longhorn, kube-prometheus… via ArgoCD | Fournis par Cozystack (Flux) : MetalLB, ingress-nginx, LINSTOR/DRBD, VictoriaMetrics… |
| Rôle d'ArgoCD | Gère toute la plateforme | Gère ArgoCD, l'opérateur Cozystack, le Package `cozystack-platform`, le pool MetalLB, les StorageClasses, le Tenant `root`, l'Ingress ArgoCD |
| Talos | v1.13.2, installer Image Factory | v1.14.2, installer Image Factory avec `drbd` + `zfs` + `qemu-guest-agent` |
| API Kubernetes | IP DHCP du 1er CP | VIP Talos `192.168.20.10` |
| Réseau | VLAN 15 | VLAN 20 (`192.168.20.0/24`), créé par OpenTofu sur UniFi |
| Secrets | Doppler | `cluster.env` (jeton Cloudflare appliqué par `make cozystack-secrets`) |
| Fichiers Talos générés | `talos/` (partagé) | `clusters/cozy-01/talos/` (par cluster, gitignoré) |

Cozystack se gère lui-même avec Flux : ArgoCD ne déploie **que** les objets listés ci-dessus.
Ne pas recréer sous ArgoCD des composants que Cozystack installe déjà (cert-manager, MetalLB,
monitoring…).

## Plan réseau

| Élément | Valeur | Où |
|---|---|---|
| VLAN | 20 | `unifi.tfvars` (`vlan_id`) et `terraform.tfvars` (`proxmox.vlan_tag`) — doivent être égaux |
| Sous-réseau | `192.168.20.0/24`, passerelle `.1` | `unifi.tfvars`, `NODE_SUBNET` |
| DHCP des VM | `.100` – `.199` | `unifi.tfvars` |
| VIP API Talos | `192.168.20.10` | `K8S_API_VIP` (cluster.env) **et** `cluster.kubernetes_api_host` (terraform.tfvars) |
| Pool MetalLB / `externalIPs` | `192.168.20.60` – `.79` | `COZY_EXTERNAL_IP_RANGE` |
| IP ingress `tenant-root` | `192.168.20.60` (1re du pool) | `ingress_ip` dans `unifi.tfvars` |
| Domaine racine | `cozy-01.alexetnico.com` | `COZY_ROOT_HOST`, `unifi.tfvars` |

DNS créé par `tofu/unifi` (enregistrements A vers l'ingress) : `cozy-01.alexetnico.com`,
`dashboard.`, `api.`, `grafana.`, `argocd.`. Ajouter un service exposé (Keycloak, Harbor…) =
ajouter son sous-domaine à `hostnames` dans `unifi.tfvars`.

## Prérequis

1. **UniFi** : clé API (UniFi OS ≥ 9.0.108 : *Control Plane → Admins & Users → Create API Key*),
   à mettre dans `UNIFI_API_KEY` (cluster.env). Le routage inter-VLAN doit autoriser votre poste
   vers `192.168.20.0/24` (ports 6443, 50000 notamment).
2. **Cloudflare** : jeton `Zone:Read` + `Zone:DNS:Edit`, dans `CLOUDFLARE_API_TOKEN`. Le domaine
   n'est joignable qu'en LAN : les certificats passent en DNS-01 (HTTP-01 ne peut pas valider).
3. **Proxmox — virtualisation imbriquée** (KubeVirt lance des VM dans les VM Talos). Sur `pve1`
   (AMD EPYC) : `cat /sys/module/kvm_amd/parameters/nested` doit afficher `1` ou `Y`. Les VM
   utilisent déjà `cpu.type = host`.
4. **Capacité `pve1`** : cozy-01 réserve 3×(4 vCPU, 8 Go) + 5×(8 vCPU, 24 Go) = 52 vCPU et
   144 Go de RAM, plus 5×200 Go de disque de données sur `nvme4t`. Avec `talos-02`
   (≈ 104 Go) on atteint ≈ 248 Go alloués sur 252 Go : aucune marge pour l'hôte. Arrêter
   `talos-02` ou réduire les workers avant de lancer les deux clusters ensemble.
5. Outils : `tofu`, `talhelper`, `talosctl`, `helm`, `kubectl`, `mc`, `jq`, `yq`, `envsubst`.

## Mise en place

```bash
# 0. Fichiers (déjà créés dans la branche) :
#    clusters/cozy-01/cluster.env       (gitignoré — compléter UNIFI_API_KEY, CLOUDFLARE_API_TOKEN)
#    clusters/cozy-01/terraform.tfvars  (gitignoré — contient le token Proxmox)
#    clusters/cozy-01/unifi.tfvars

# 1. Rendre les manifestes ArgoCD, committer ET pousser la branche (ArgoCD lit Git)
make CLUSTER=cozy-01 gitops-render
git add clusters/cozy-01/gitops && git commit -m "chore(cozy-01): render gitops" && git push -u origin feat/cozy-01

# 2. Prévisualiser le réseau UniFi, puis tout lancer
make CLUSTER=cozy-01 unifi-plan
make CLUSTER=cozy-01 up
```

`make CLUSTER=cozy-01 up` enchaîne :

| # | Cible | Effet |
|---|---|---|
| 1 | `unifi-apply` | VLAN 20 + DHCP + enregistrements DNS sur UniFi (state `cozy-01/unifi.tfstate`) |
| 2 | `tofu-init`, `tofu-apply` | ISO Image Factory (Talos 1.14.2 + drbd/zfs/guest agent) + 8 VM (VMID 9500+) |
| 3 | `talos-config` | machineconfigs (talhelper) appliquées, nœuds redémarrés |
| 4 | `talos-bootstrap` | `talosctl bootstrap`, kubeconfig ; attend etcd + API (les nœuds restent NotReady : pas de CNI) |
| 5 | `cozystack-bootstrap` | `helm install cozy-installer` + `kubectl apply` du Package ; attend les nœuds Ready (CNI Cozystack) |
| 6 | `argocd-bootstrap` | ArgoCD + app-of-apps ; adopte l'opérateur et le Package depuis Git |
| 7 | `upload-kubeconfig`, `tofu-publish` | kubeconfig dans MinIO |
| 8 | `cozystack-secrets` | Secret Cloudflare dans `cozy-cert-manager` |
| 9 | `cozystack-storage` | pools LINSTOR ZFS `data` sur `/dev/sdb` de chaque worker |

Pourquoi l'opérateur est installé avant ArgoCD : Talos est en `cni: none`, aucun pod (donc pas
ArgoCD) ne démarre tant que Cozystack n'a pas installé son CNI.

### Après l'installation

```bash
export KUBECONFIG=clusters/cozy-01/kubeconfig
kubectl get hr -A                       # toutes les HelmReleases Cozystack doivent passer Ready
kubectl -n argocd get applications
kubectl get svc -n tenant-root root-ingress-controller   # EXTERNAL-IP = 192.168.20.60
kubectl get secret -n tenant-root tenant-root -o go-template='{{ printf "%s\n" (index .data "token" | base64decode) }}'
```

Dashboard : `https://dashboard.cozy-01.alexetnico.com` (jeton ci-dessus). Grafana :
`https://grafana.cozy-01.alexetnico.com`. ArgoCD : `https://argocd.cozy-01.alexetnico.com`
(`make CLUSTER=cozy-01 argo-pwd`).

## Choix et points à valider au premier déploiement

Ces points reposent sur la documentation Cozystack v1.7 mais n'ont pas pu être testés sans
cluster ; les vérifier au premier `make up`.

- **Image Talos** : l'installer officiel Cozystack (`ghcr.io/cozystack/cozystack/talos:v1.14.2`)
  n'inclut pas `qemu-guest-agent`, dont OpenTofu a besoin pour lire les IP des VM. Le cluster
  utilise donc Image Factory avec les mêmes extensions Cozystack (`drbd`, `zfs`) + le guest agent.
  Si Cozystack exige un jour son image, remplacer `machine.install.image` après coup
  (`talosctl upgrade --image …`) en gardant à l'esprit que l'IP ne remontera plus dans OpenTofu.
- **Config Talos 1.14** : réseau, proxy, discovery, apiserver, controller-manager et scheduler
  sont des documents dédiés (`KubeNetworkConfig`, `KubeProxyConfig`…), pas des champs
  `cluster.*`. Les patches `talos/cozystack/patches/` ont été validés avec `talhelper genconfig`
  et `talosctl validate --mode metal` (v1.14.2). `machine.files` est déprécié mais encore accepté
  (avertissement).
- **Interface réseau** : sélection `deviceSelector.physical` (l'interface est `ens18`, pas `eth0`).
- **Adoption par ArgoCD** : le chart `cozy-installer` est installé par `helm` puis adopté par
  l'Application `cozystack-operator` (ServerSideApply). Si l'adoption pose problème (hooks
  `pre-install`, `lookup`), retirer `10-cozystack-operator.yaml` : l'opérateur continue de tourner,
  seule sa version n'est plus épinglée par Git.
- **Tenant `root`** : `apps.cozystack.io/v1alpha1` / `Tenant` est appliqué en server-side apply
  avec retry (le tenant n'existe qu'après l'installation de la plateforme). Si la version d'API
  diffère, `kubectl api-resources | grep -i tenant`.
- **Secret Cloudflare** : placé dans `cozy-cert-manager` (namespace de cert-manager pour les
  ClusterIssuers). À confirmer avec `kubectl describe clusterissuer letsencrypt-prod`.
- **Pools LINSTOR** : créés par `scripts/cozystack-storage.sh` (méthode du guide Cozystack,
  impérative). Une version déclarative (`LinstorSatelliteConfiguration`) est possible mais
  n'a pas été retenue car elle peut entrer en conflit avec la configuration générée par
  Cozystack. Seules les StorageClasses sont dans Git.
- **Télémétrie** : activée par défaut côté Cozystack (opérateur et contrôleur). Pour la couper :
  `cozystackOperator.disableTelemetry: true` (valeurs du chart) et `telemetry.disabled` dans le
  Package.

## Exploitation

- **Modifier la config Cozystack** : éditer `gitops-cozystack/cozystack-platform/package.yaml`,
  `make CLUSTER=cozy-01 gitops-render`, commit + push. ArgoCD applique (selfHeal).
- **Monter de version** : changer `COZYSTACK_VERSION` (cluster.env), lire les *breaking changes*
  de la release (les migrations s'exécutent en pre-upgrade), `gitops-render`, push.
- **Ajouter un worker** : `worker.count` dans `terraform.tfvars`, `make CLUSTER=cozy-01 talos-config`
  puis `make CLUSTER=cozy-01 cozystack-storage` (crée le pool du nouveau nœud).
- **Supprimer le cluster** : `make CLUSTER=cozy-01 down` (VM) puis, si voulu,
  `make CLUSTER=cozy-01 unifi-destroy` (VLAN + DNS).
- **Retour au flavor standard** : sans `PLATFORM_FLAVOR`, le comportement de `talos-02` est inchangé.
