# Observabilité (cozy-01)

On s'appuie sur la stack de monitoring de Cozystack (tenant `root`, chart `monitoring`) et on
n'ajoute que le **tracing** (Tempo).

| Signal | Collecte | Stockage / lecture | Datasource Grafana |
|---|---|---|---|
| Logs (tous les namespaces) | fluent-bit (`cozy-monitoring`) → `vlinsert-generic.tenant-root.svc:9481` | VictoriaLogs `generic`, `vlselect-generic.tenant-root.svc:9471` | `vlogs-generic` |
| Métriques | VMAgent (`cozy-monitoring`) scrape les `VMServiceScrape` / `VMPodScrape` de **tous** les namespaces | `vminsert-shortterm\|longterm:8480` / `vmselect-*:8481` | `vm-shortterm`, `vm-longterm` |
| Traces | l'application exporte en OTLP directement | **Tempo** (ce dépôt) | `tempo` |

Ce dépôt déploie uniquement Tempo : `gitops-cozystack/observability/`
(`tempo.yaml` = Application ArgoCD, `grafana-datasources.yaml` = `GrafanaDatasource` Tempo),
via l'Application `observability-stack`. Après modification : `make CLUSTER=cozy-01 gitops-render`, commit, push.

Tempo : stockage `local` 10 Gi, rétention 7 j. Ses span metrics sont écrites dans
`vminsert-shortterm` (`/insert/0/prometheus/api/v1/write`).

## Monitoring de l'hôte Proxmox (pve1)

Déployé avec `observability-stack` (namespace `tenant-root`) : `gitops-cozystack/observability/`.

| Fichier | Rôle |
|---|---|
| `pve-exporter.yaml` | Deployment + Service `pve-exporter` (API Proxmox : storages, VMs, nœud) et `VMScrapeConfig` `pve` (multi-target, `/pve?target=<hôte>`) |
| `pve-node-exporter.yaml` | `VMScrapeConfig` `pve-node-exporter` : `<hôte>:9100` (node_exporter installé sur l'hôte : disques, I/O, CPU, RAM, températures) |
| `grafana-dashboards.yaml` | `GrafanaDashboard` 1860 (Node Exporter Full) et 10347 (Proxmox via Prometheus), dossier « Proxmox », datasource `vm-shortterm` |

L'hôte est déduit de `PROXMOX_VE_ENDPOINT` au rendu (`make CLUSTER=cozy-01 gitops-render`).

Prérequis hors cluster :

```bash
# sur pve1 : node_exporter
apt update && apt install -y prometheus-node-exporter

# sur pve1 : utilisateur + token en lecture seule pour pve-exporter
pveum user add prometheus@pve
pveum aclmod / -user prometheus@pve -role PVEAuditor
pveum user token add prometheus@pve exporter --privsep 0   # affiche la valeur du token une seule fois
```

Puis dans `clusters/cozy-01/cluster.env` (gitignoré) :

```bash
PVE_EXPORTER_USER=prometheus@pve
PVE_EXPORTER_TOKEN_NAME=exporter
PVE_EXPORTER_TOKEN_VALUE=<valeur du token>
```

et `make CLUSTER=cozy-01 cozystack-secrets` (crée le Secret `tenant-root/pve-exporter`).
Sans ce Secret, le pod reste en `CreateContainerConfigError`.

Le réseau doit laisser passer les nœuds (`192.168.20.0/24`) vers pve1 sur les ports 9100 et 8006.

## Instrumenter une application

- **Logs** : écrire sur stdout. Si c'est du JSON, les champs sont fusionnés (`Merge_Log`) et
  deviennent interrogeables. Champs utiles : `kubernetes_namespace_name`, `kubernetes_pod_name`,
  `kubernetes_container_name`. Exemple LogsQL : `{kubernetes_namespace_name="mon-ns"} level:i("error")`.
- **Métriques** : exposer `/metrics` et créer un `VMServiceScrape` (le Service doit avoir un port nommé) :
  ```yaml
  apiVersion: operator.victoriametrics.com/v1beta1
  kind: VMServiceScrape
  metadata: {name: mon-app, namespace: mon-ns}
  spec:
    selector: {matchLabels: {app: mon-app}}
    endpoints: [{port: http, path: /metrics, interval: 30s}]
  ```
  Les annotations `prometheus.io/*` ne sont lues par personne.
- **Traces** : OTLP gRPC `tempo.tenant-root.svc:4317` ou HTTP `http://tempo.tenant-root.svc:4318`.

Exemple complet (Flask) : `examples/observability/`.

## Pièges rencontrés (cozy-01)

- **Domaine DNS `cozy.local`** : utiliser `<svc>.<ns>.svc`, jamais `.svc.cluster.local`.
- **Egress deny-by-default dans `tenant-root`** : un pod qui parle à l'API server doit porter le
  label `policy.cozystack.io/allow-to-apiserver: "true"`.
- **StorageClass** : seules `local` (1 copie, `WaitForFirstConsumer`) et `replicated` (3 copies)
  existent. Le pool LINSTOR `data` fait ~199 Gi par worker et se remplit vite : `replicated` triple
  la consommation. Ne pas inventer de classes (`linstor-lvm-r1` n'existe pas).
- **`volumeClaimTemplates` est immuable** : changer la StorageClass ou la taille d'un StatefulSet
  impose de supprimer le StatefulSet et son PVC (ArgoCD le recrée).
- **StatefulSet `OutOfSync` en boucle** avec `ServerSideApply=true` : ArgoCD prédit
  `creationTimestamp: null` dans les `volumeClaimTemplates`. Ajouter sur l'Application
  `argocd.argoproj.io/compare-options: ServerSideDiff=true` (un `ignoreDifferences` ne suffit pas).
- **Supprimer une Application enfant du dépôt** ne supprime pas ses ressources (pas de finalizer) :
  les nettoyer à la main.
- **`AppProject platform`** : toute nouvelle source Helm doit être ajoutée à `sourceRepos`
  (`gitops-cozystack/projects/platform.yaml`).

## Vérifier

```bash
make CLUSTER=cozy-01 test-observability
```
