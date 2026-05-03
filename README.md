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
|   +-- kubeconfig_publish.tf  # aws_s3_object pointed at MinIO
|   +-- outputs.tf
|   +-- modules/talos-node/ # reusable VM module (with extra Longhorn disks)
+-- talos/                  # Talos config (rendered by scripts/bootstrap.sh)
|   +-- talconfig.yaml.tpl  # template for talhelper
|   +-- patches/            # controlplane.yaml + cluster-common.yaml
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
- A free range of IPs on the bridge: 1 IP for the cluster VIP + a contiguous
  range for MetalLB

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
| `MINIO_ENDPOINT`, `MINIO_STATE_BUCKET`, `MINIO_STATE_KEY` | State storage |
| `MINIO_KUBECONFIG_BUCKET`, `MINIO_KUBECONFIG_KEY` | Where the kubeconfig lands |
| `ARGOCD_GIT_REPO`, `ARGOCD_GIT_REVISION`, `ARGOCD_GIT_PATH` | Source of truth for ArgoCD |
| `ARGOCD_INGRESS_HOST` | FQDN exposed by ingress-nginx |

### 2. `tofu/terraform.tfvars`

```bash
cp tofu/terraform.tfvars.example tofu/terraform.tfvars
$EDITOR tofu/terraform.tfvars
```

Important blocks:

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
make argocd-bootstrap    # helm install Cilium + ArgoCD, apply App-of-Apps
make upload-kubeconfig   # push kubeconfig to MinIO via mc
make tofu-publish        # second OpenTofu apply -> aws_s3_object kubeconfig
```

Once ArgoCD has synced, get its admin password and open the UI:

```bash
make argo-pwd
open https://${ARGOCD_INGRESS_HOST}
```

(Make sure `${ARGOCD_INGRESS_HOST}` resolves to the IP MetalLB allocated to
the `ingress-nginx-controller` Service.)

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
  `talos/patches/cluster-common.yaml`). The `k8sServiceHost` is set to the
  cluster VIP at install time by `bootstrap-argocd.sh`.
- **Longhorn cannot find disks**: check `kubectl -n longhorn-system get
  nodes.longhorn.io <node> -o yaml`. Verify that
  `/var/mnt/longhorn-0` is present and writable inside the worker
  (`talosctl -n <worker-ip> ls /var/mnt`).

## License

MIT.
