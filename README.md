# Talos cluster on Proxmox - GitOps automation

Provision a HA Kubernetes cluster running [Talos Linux](https://www.talos.dev/)
on Proxmox VE (`pve1`), with the number of masters/workers and their resources
fully configurable through a single `terraform.tfvars`. The OpenTofu state is
stored in a MinIO bucket (S3 backend with native locking), and the resulting
kubeconfig is published in a second MinIO bucket. After the cluster is
bootstrapped, ArgoCD takes over and manages Cilium, MetalLB, ingress-nginx and
Longhorn from the `gitops/` sub-folder of this repo.

## Architecture

```
+-----------+       +------------+       +-------------+
| Operator  | --->  | Makefile + | --->  | OpenTofu    | --> Proxmox VE (pve1)
| (laptop)  |       |   .env     |       | bpg/proxmox |     - VMs CP x N
+-----------+       +------------+       +-------------+     - VMs WK x M
                          |                                  - Longhorn disks
                          |              +-------------+
                          | tfstate ---> | MinIO       |
                          |              | (bucket)    |
                          | kubeconfig ->|             |
                          v              +-------------+
                  +----------------+
                  | scripts/...    |
                  | - bootstrap.sh |  (talhelper + talosctl)
                  | - bootstrap-   |  (helm cilium + helm argocd)
                  |   argocd.sh    |
                  +----------------+
                          |
                          v
                  +----------------+
                  | ArgoCD (self-  |
                  | managed,       |  --- watches gitops/ in this repo ---
                  | App-of-Apps)   |  --> Cilium / MetalLB / ingress-nginx /
                  +----------------+      Longhorn / ArgoCD itself
```

## Repo layout

```
talos/
+-- Makefile                # entry point, loads .env
+-- .env.example            # template for credentials and endpoints
+-- tofu/                   # OpenTofu (Proxmox VMs + ISO + kubeconfig publish)
|   +-- versions.tf
|   +-- backend.tf          # MinIO S3 backend with use_lockfile
|   +-- providers.tf        # bpg/proxmox + aws (alias minio)
|   +-- variables.tf        # cluster sizing, MinIO buckets, ArgoCD repo
|   +-- iso.tf              # Talos Image Factory + Proxmox download
|   +-- vms.tf              # for_each control-plane / worker
|   +-- kubeconfig_publish.tf  # null_resource → scripts/upload-kubeconfig.sh (mc / aws cli)
|   +-- outputs.tf
|   +-- modules/talos-node/ # reusable VM module (with extra Longhorn disks)
+-- talos/                  # Talos config (rendered by scripts/bootstrap.sh)
|   +-- talconfig.yaml.tpl  # template for talhelper
|   +-- patches/            # base Talos + fragments générés (réseau DHCP)
|   +-- schematic.yaml      # Talos Image Factory extensions
+-- bootstrap/              # Helm values used during the initial install only
|   +-- cilium-values.yaml
|   +-- argocd-values.yaml
+-- gitops/                 # source of truth for ArgoCD (App-of-Apps)
|   +-- projects/platform.yaml
|   +-- bootstrap/root-app.yaml
|   +-- apps/               # Application manifests, sync-wave ordered
|   +-- argocd/             # ArgoCD Ingress
|   +-- metallb/            # IPAddressPool + L2Advertisement
+-- scripts/
    +-- bootstrap.sh        # Talos cluster bootstrap (talhelper + talosctl)
    +-- bootstrap-argocd.sh # helm cilium/argocd + apply App-of-Apps
    +-- upload-kubeconfig.sh
    +-- gitops-render.sh    # one-time placeholder substitution in gitops/
    +-- gen-iso.sh          # manual escape hatch for the Talos ISO
```

## Prerequisites

Install on the operator's machine:

- [`tofu`](https://opentofu.org/) >= 1.10 (for `use_lockfile`)
- [`talosctl`](https://www.talos.dev/v1.8/talos-guides/install/talosctl/) matching the cluster Talos version
- [`talhelper`](https://github.com/budimanjojo/talhelper)
- `helm`, `kubectl`
- `mc` (MinIO client)
- `envsubst`, `jq`, `yq`, `curl`, `git`

On Proxmox:

- An API token with role `PVEVMAdmin` and `Datastore.AllocateSpace` on the
  target node `pve1`
- DHCP sur le segment des VMs (guest agent Proxmox pour les IP) + une plage
  contiguë pour MetalLB. Optionnel : `cluster.kubernetes_api_host` pour forcer
  l’hôte API (DNS ou IP fixe) au lieu du premier control plane DHCP.

On MinIO:

- Two buckets pre-created (or pre-creatable by the access key):
  - `talos-tfstate` (state backend)
  - `kubeconfigs` (output destination)

A Git repository (this one or a fork) reachable from the future ArgoCD pod.
For private repos, add the credentials to ArgoCD post-bootstrap.

## Configuration

### 1. `.env`

Copy the template and fill in your values. Every variable is exported by the
Makefile to OpenTofu and the helper scripts.

```bash
cp .env.example .env
$EDITOR .env
```

Key entries:

| Variable | Purpose |
|---|---|
| `PROXMOX_VE_ENDPOINT` / `PROXMOX_VE_API_TOKEN` | Proxmox auth (read by the `bpg/proxmox` provider) |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | MinIO credentials, reused by both the S3 backend and `mc` |
| `MINIO_INSECURE` | `true` si le certificat TLS de MinIO n’est pas reconnu (`mc --insecure`) |
| `USE_AWS_CLI_FOR_KUBECONFIG` | `1` pour forcer `aws s3 cp` au lieu de `mc` pour le kubeconfig |
| `MINIO_ENDPOINT`, `MINIO_STATE_BUCKET`, `MINIO_STATE_KEY` | State storage |
| `MINIO_KUBECONFIG_BUCKET`, `MINIO_KUBECONFIG_KEY` | Where the kubeconfig lands |
| `ARGOCD_GIT_REPO`, `ARGOCD_GIT_REVISION`, `ARGOCD_GIT_PATH` | Source of truth for ArgoCD |
| `ARGOCD_INGRESS_HOST` | FQDN exposed by ingress-nginx |

### 2. `tofu/terraform.tfvars`

```bash
cp tofu/terraform.tfvars.example tofu/terraform.tfvars
$EDITOR tofu/terraform.tfvars
```

**Migration** : supprime tout bloc `node_network` et toute IP statique obligatoire.
`cluster.kubernetes_api_host` est **optionnel** ; par défaut l’output OpenTofu
`kubernetes_api_host` reprend l’IP DHCP du **premier** control plane (guest agent).

Important blocks:

- **`cluster`**: `kubernetes_api_host` (optionnel) — surcharge DNS/IP pour
  talconfig, certSANs et Cilium ; sinon IP du premier CP issue du DHCP.
  `install_disk` (optionnel, défaut `/dev/sda`) — champ `installDisk` requis par
  talhelper ; avec le module Proxmox (OS sur `scsi0`), `/dev/sda` convient en
  général. Utilise `/dev/vda` si le disque système apparaît en virtio-blk.
- **`control_plane`**: `count` (must be odd), `cores`, `memory_mb`, `disk_gb`.
- **`worker`**: `count`, `cores`, `memory_mb`, `disk_gb` (OS disk), and
  `longhorn_disks` - a list of additional disks dedicated to Longhorn. Each
  entry has its own `size_gb`, optional `storage` pool and `ssd` flag.

  ```hcl
  worker = {
    count     = 3
    cores     = 4
    memory_mb = 8192
    disk_gb   = 50
    longhorn_disks = [
      { size_gb = 200, storage = "fast-nvme" },
      { size_gb = 500, storage = "slow-hdd",  ssd = false },
    ]
  }
  ```

  Set `longhorn_disks = []` for compute-only workers.

- **`metallb_pool`**: inclusive range advertised in L2 mode. After editing
  the tfvars, also update `gitops/metallb/ipaddresspool.yaml` to the same
  range and commit the change.

- **`argocd`**: Git source for the App-of-Apps and the FQDN exposed by
  ingress-nginx.

- **`minio`**: bucket layout for state and kubeconfig.

- **`proxmox.vlan_tag`** (optional): 802.1Q VLAN ID applied by Proxmox on the VM
  NIC. Talos still sees a single untagged `eth0`; only the host bridge tags
  egress traffic. Omit for an untagged port group.

### 3. Render and commit `gitops/`

The child Application manifests reference the user's Git repo via the
placeholders `__ARGOCD_GIT_REPO__`, `__ARGOCD_GIT_REVISION__`,
`__ARGOCD_GIT_PATH__` and `__ARGOCD_INGRESS_HOST__`. ArgoCD reads these
manifests from Git, so the substitution must happen **before** the first
`make up`:

```bash
make gitops-render
git add gitops/
git commit -m "gitops: render placeholders for my-cluster"
git push
```

Re-run `make gitops-render` after changing any of the four variables in
`.env`.

## Bootstrap workflow

```bash
make up
```

equivalent to:

```bash
make tofu-init           # init OpenTofu against the MinIO S3 backend
make tofu-apply          # download Talos ISO + create VMs on Proxmox
make talos-config        # render machineconfigs and apply them to nodes
make talos-bootstrap     # talosctl bootstrap + fetch kubeconfig
make fetch-kubeconfig      # uniquement récupérer le kubeconfig (si bootstrap déjà OK)
make argocd-bootstrap    # helm install Cilium + ArgoCD, apply App-of-Apps
make upload-kubeconfig   # push kubeconfig to MinIO via mc (ou aws s3 cp en secours)
make tofu-publish        # second apply : même upload via OpenTofu (null_resource, pratique hors make)
```

Once ArgoCD has synced, get its admin password and open the UI:

```bash
make argo-pwd
open https://${ARGOCD_INGRESS_HOST}
```

(Make sure `${ARGOCD_INGRESS_HOST}` resolves to the IP MetalLB allocated to
the `ingress-nginx-controller` Service.)

## ArgoCD HTTPS with cert-manager

This repo deploys:

- `ingress-nginx` as the Ingress controller,
- `cert-manager` via `gitops/apps/19-cert-manager.yaml`,
- Let's Encrypt DNS-01 (Cloudflare) via `gitops/apps/22-cert-manager-issuers.yaml`,
- ArgoCD Ingress TLS in `gitops/argocd/ingress.yaml`.

`gitops/cert-manager/` contains exactly two manifests:

- `clusterissuer.yaml` — ClusterIssuer `letsencrypt-prod`

Set `ACME_EMAIL` in `cluster.env` and `gitops-render`. Cloudflare API token comes from **Doppler**.

ArgoCD Ingress uses `cert-manager.io/cluster-issuer: letsencrypt-prod`.

### Cloudflare DNS-01 setup

1. Create a Cloudflare API token for your zone (`Zone / DNS / Edit`, `Zone / Zone / Read`).
2. Set `ACME_EMAIL` and `CLOUDFLARE_API_TOKEN` in `cluster.env`, then `gitops-render`.
3. Ensure DNS has an `A`/`CNAME` for `${ARGOCD_INGRESS_HOST}` pointing to your ingress IP.

## ExternalDNS (Cloudflare + UniFi local)

This repo deploys:

- `external-dns-cloudflare` (`gitops/apps/24-external-dns-cloudflare.yaml`)
- `external-dns-unifi` (`gitops/apps/25-external-dns-unifi.yaml`)
- shared config/resources (`gitops/apps/23-external-dns-config.yaml`)

### Cloudflare instance

Used for public DNS zone updates (example: `alexetnico.com`).

Credentials are synced from **Doppler** into `external-dns` (see below).

### UniFi local instance (Dream Machine)

Webhook sidecar in chart `external-dns-unifi`; credentials from Doppler (`UNIFI_*` variables).

`external-dns-unifi` is scoped to `home.alexetnico.com` by default. Update
`domainFilters` in `gitops/apps/25-external-dns-unifi.yaml` if needed.

## Secrets with Doppler

API tokens (`CLOUDFLARE_API_TOKEN`, `UNIFI_HOST`, `UNIFI_API_KEY`, etc.) are stored in
**Doppler**, not in Git or `cluster.env`.

| Component | ArgoCD app | Sync wave |
|-----------|------------|-----------|
| Doppler operator | `18-doppler-operator` | 1 |
| `DopplerSecret` CRs | `17-doppler-secrets` | 2 |
| cert-manager / external-dns | later waves | consume synced Secrets |

In `cluster.env` (gitignored):

- `DOPPLER_SERVICE_TOKEN` — Doppler **Service Token** (Free plan; never commit)
- `DOPPLER_PROJECT`, `DOPPLER_CONFIG` — rendered into `DopplerSecret` CRs (safe to commit)

```bash
make CLUSTER=<name> gitops-render
make CLUSTER=<name> apply-doppler-token   # once: installs Secret/doppler-service-token
git add clusters/<name>/gitops/ && git commit && git push
```

### Doppler setup (Free plan / service token)

1. In Doppler, create a **Service Token** with read access to your project/config.
2. Store app secrets in that config: `CLOUDFLARE_API_TOKEN`, `UNIFI_HOST`, `UNIFI_API_KEY`, `UNIFI_SITE` (`UNIFI_SKIP_TLS_VERIFY` is set in `cluster.env` for Helm, not Doppler).
3. Set `DOPPLER_SERVICE_TOKEN`, `DOPPLER_PROJECT`, `DOPPLER_CONFIG` in `cluster.env`.
4. `apply-doppler-token` then ArgoCD sync (`platform-namespaces` → `doppler-operator` → `doppler-secrets`).

`external-dns` and `cert-manager` namespaces are created at wave 1 so Doppler can write managed Secrets before Helm apps start.

## Day-2 operations

### Scaling

Edit `tofu/terraform.tfvars`:

- Bump `control_plane.count` (keep it odd) or `worker.count`.
- Add or remove entries from `worker.longhorn_disks` to grow/shrink the
  storage pool.

Re-run `make up`. New nodes pick up Cilium/Longhorn DaemonSets automatically;
new disks are formatted and mounted by Talos at `/var/mnt/longhorn-<index>`,
then Longhorn discovers them via the
`node.longhorn.io/create-default-disk=config` label.

### Updating component versions

Edit the `targetRevision` (chart version) inside
`gitops/apps/*-<component>.yaml`, commit, and push. ArgoCD auto-syncs.

### Tearing down

```bash
make down
```

This destroys every Proxmox VM. The MinIO state remains in the bucket so the
cluster can be re-created on demand. To remove the kubeconfig object too:

```bash
mc rm "${MINIO_ENDPOINT%/}/${MINIO_KUBECONFIG_BUCKET}/${MINIO_KUBECONFIG_KEY}"
```

## Troubleshooting

- **`no route to host` vers l’API `:6443` / `:50000`** : joindre l’IP du
  premier control plane (DHCP) ou celle de `cluster.kubernetes_api_host` si tu
  l’as fixée. Routage / firewall / VLAN. Pour **`talosctl kubeconfig`** et
  **`talosctl health`**, défaut = premier CP (`tofu output`), override `TALOS_FETCH_*` dans `.env`.
- **`talosconfig` vs `kubeconfig`** : `talosconfig` (racine du dépôt) sert à
  **`talosctl`** (API Talos). **`kubectl`** utilise le fichier **`kubeconfig`**
  (même répertoire), créé par **`talosctl kubeconfig`** après bootstrap quand
  l’API Kubernetes sur l’hôte effectif (`tofu output kubernetes_api_host`) répond. Sans ce fichier, le bucket MinIO
  `kubeconfigs` reste vide. Enchaîne : `make talos-bootstrap` ou
  `make fetch-kubeconfig` puis `make upload-kubeconfig`.
- **Kubeconfig absent du bucket MinIO** : vérifie `make upload-kubeconfig` (logs
  + `mc stat`). TLS auto-signé : `MINIO_INSECURE=true` dans `.env`. En dernier
  recours : `USE_AWS_CLI_FOR_KUBECONFIG=1` avec AWS CLI v2 installé. Après une
  ancienne version utilisant `aws_s3_object`, supprime les entrées d’état
  obsolètes : `tofu state rm 'aws_s3_object.kubeconfig[0]' 'data.local_file.kubeconfig[0]'`
  puis `tofu apply`.
- **`proxmox_download_file` / HTTP 403 sur factory.talos.dev** : le nœud
  Proxmox interroge l’URL distante ; l’Image Factory peut répondre **403**
  (WAF, géolocalisation, etc.). Ce dépôt télécharge l’ISO **sur la machine qui
  lance OpenTofu** (`curl` dans `null_resource.talos_iso_local`) puis l’envoie
  avec `proxmox_virtual_environment_file`. Si tu migres depuis une ancienne
  version du code, supprime l’ancienne ressource d’état :
  `tofu state rm 'proxmox_download_file.talos_iso'`.
- **`Output "cluster_name" not found`** : le `Makefile` lance un `tofu apply`
  **ciblé** (`-target=…`). Les outputs racine qui ne dépendent que de variables
  (comme `cluster_name`) ne sont pas toujours écrits dans l’état. Les scripts
  lisent désormais `var.cluster.name` via `tofu console` pour éviter ce cas.
  Tu peux aussi lancer une fois `tofu apply` **sans** `-target` si tu veux
  rafraîchir tous les outputs.
- **`tofu init` / `NoSuchBucket`**: OpenTofu only uses an **existing** bucket;
  it never creates it. The error means `MINIO_STATE_BUCKET` does not exist on
  your MinIO (credentials can still be correct). Run `make minio-buckets`
  before `make tofu-init`, or create the bucket manually (`mc mb …`). The
  default `make up` flow runs `minio-buckets` automatically before `tofu-init`.
- **`tofu init` fails with "BadRequest"**: MinIO requires path-style access,
  which the backend enables via `use_path_style = true`. Make sure the
  endpoint URL has no trailing path component.
- **VMs never get an IP**: the Talos ISO must include the
  `siderolabs/qemu-guest-agent` extension (default in `talos/schematic.yaml`),
  and `agent.enabled = true` is set on the Proxmox VM. Without it, OpenTofu
  cannot read the IP back.
- **`talosctl bootstrap` returns AlreadyExists**: ignored, the cluster is
  already bootstrapped. Re-run `make talos-bootstrap` if needed.
- **Cilium pods CrashLoopBackOff**: confirm `kubeProxyReplacement: true` and
  that `kubeProxy.disabled = true` is in the cluster patch (it is, in
  `talos/patches/cluster-common-base.yaml`). `k8sServiceHost` est fixé à
  l’output `kubernetes_api_host` par `bootstrap-argocd.sh`.
- **Longhorn cannot find disks**: check `kubectl -n longhorn-system get
  nodes.longhorn.io <node> -o yaml`. Verify that
  `/var/mnt/longhorn-0` is present and writable inside the worker
  (`talosctl -n <worker-ip> ls /var/mnt`).

## License

MIT.
