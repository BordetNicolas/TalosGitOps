# Observabilité (Cozystack)

Cozystack fournit déjà l'essentiel dans le tenant `root` (chart `monitoring`) :

| Besoin | Fourni par Cozystack |
|---|---|
| Collecte des logs de **tous** les namespaces | fluent-bit (`cozy-monitoring`) → `vlinsert-generic.tenant-root.svc:9481` |
| Stockage / lecture des logs | VictoriaLogs `generic` (`vlselect-generic.tenant-root.svc:9471`) |
| Métriques | VictoriaMetrics `shortterm` / `longterm` (`vminsert-*:8480`, `vmselect-*:8481`) |
| Dashboards | Grafana (datasources `vlogs-generic`, `vm-shortterm`, `vm-longterm`) |

Ce dossier n'ajoute que ce qui manque : le **tracing**.

```
observability/
├── tempo.yaml                 # Application ArgoCD : Tempo (traces), stockage local 10Gi, rétention 7j
└── grafana-datasources.yaml   # GrafanaDatasource "tempo" (grafana-operator)
```

Déployé par l'Application `observability-stack` (`apps/30-observability-stack.yaml`).

## Envoyer des traces

Les applications exportent en OTLP directement vers Tempo :

- gRPC : `tempo.tenant-root.svc:4317`
- HTTP : `http://tempo.tenant-root.svc:4318`

Les métriques dérivées des traces (span metrics) sont écrites par Tempo dans
`vminsert-shortterm` (`/insert/0/prometheus/api/v1/write`).

## Notes

- Le domaine DNS du cluster est `cozy.local` : utiliser `<svc>.<ns>.svc` (jamais `.svc.cluster.local`).
- `tenant-root` est en egress deny-by-default : un pod qui doit parler à l'API server
  doit porter le label `policy.cozystack.io/allow-to-apiserver: "true"`.
- `tempo.yaml` porte `compare-options: ServerSideDiff=true` : sans lui, un StatefulSet avec
  `volumeClaimTemplates` reste `OutOfSync` (ArgoCD ajoute `creationTimestamp: null`).
- Changer la StorageClass ou la taille du volume impose de supprimer le StatefulSet et son PVC
  (`volumeClaimTemplates` est immuable).
