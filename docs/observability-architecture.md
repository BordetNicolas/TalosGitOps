# Architecture de la stack d'observabilité CozyStack

## Vue d'ensemble

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CozyStack Cluster (cozy-01)                         │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │ Tenant: root (Plateforme)                            tenant-root      │ │
│  │                                                                       │ │
│  │  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │ │
│  │  │ VictoriaMetrics  │  │  VictoriaLogs    │  │      Tempo       │  │ │
│  │  │  (CozyStack)     │  │   (ajouté)       │  │    (ajouté)      │  │ │
│  │  │                  │  │                  │  │                  │  │ │
│  │  │  📊 Métriques    │  │  📝 Logs         │  │  🔍 Traces       │  │ │
│  │  │  • PromQL        │  │  • LogsQL        │  │  • TraceQL       │  │ │
│  │  │  • Alertes       │  │  • Loki API      │  │  • OTLP          │  │ │
│  │  │  • 15d rétention │  │  • 30d rétention │  │  • 7d rétention  │  │ │
│  │  │                  │  │                  │  │  • Metrics gen   │  │ │
│  │  └────────▲─────────┘  └────────▲─────────┘  └────────▲─────────┘  │ │
│  │           │                     │                      │            │ │
│  │           │                     │                      │            │ │
│  │  ┌────────┴─────────────────────┴──────────────────────┴─────────┐ │ │
│  │  │                      Grafana (CozyStack)                       │ │ │
│  │  │                                                                │ │ │
│  │  │  Datasources:                                                 │ │ │
│  │  │  • VictoriaMetrics (uid: vm) ✅ default                       │ │ │
│  │  │  • VictoriaLogs (uid: victorialogs)                           │ │ │
│  │  │  • Tempo (uid: tempo)                                         │ │ │
│  │  │                                                                │ │ │
│  │  │  Features:                                                     │ │ │
│  │  │  • Explore (requêtes ad-hoc)                                  │ │ │
│  │  │  • Dashboards (préconfigurés + custom)                        │ │ │
│  │  │  • Alerting (via VictoriaMetrics)                             │ │ │
│  │  │  • Correlation logs ↔ traces                                  │ │ │
│  │  │  • Service graph (Tempo)                                      │ │ │
│  │  └────────────────────────────────────────────────────────────────┘ │ │
│  │           │                                                          │ │
│  │           │ https://grafana.cozy-01.alexetnico.com                  │ │
│  │           ▼                                                          │ │
│  │  ┌───────────────┐                                                  │ │
│  │  │    Ingress    │                                                  │ │
│  │  └───────────────┘                                                  │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │ Collecteur : Alloy (DaemonSet sur tous les nœuds)                    │ │
│  │                                                                       │ │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐    │ │
│  │  │   Logs          │  │    Traces       │  │   Métriques     │    │ │
│  │  │   Collection    │  │   Collection    │  │   Collection    │    │ │
│  │  ├─────────────────┤  ├─────────────────┤  ├─────────────────┤    │ │
│  │  │ • K8s pods      │  │ • OTLP gRPC     │  │ • Prometheus    │    │ │
│  │  │   (stdout/err)  │  │   :4317         │  │   scraping      │    │ │
│  │  │ • Enrichment    │  │ • OTLP HTTP     │  │ • OTLP metrics  │    │ │
│  │  │   (namespace,   │  │   :4318         │  │ • Service       │    │ │
│  │  │    pod, tenant) │  │ • Batching      │  │   discovery     │    │ │
│  │  │ • JSON parsing  │  │ • Propagation   │  │ • Relabeling    │    │ │
│  │  │ • Trace linking │  │   context       │  │                 │    │ │
│  │  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘    │ │
│  │           │                    │                     │             │ │
│  │           ▼                    ▼                     ▼             │ │
│  │    VictoriaLogs            Tempo              VictoriaMetrics      │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │ Tenant: lab (Workloads isolés)                      tenant-lab       │ │
│  │                                                                       │ │
│  │  Applications:                                                        │ │
│  │  • my-api                                                             │ │
│  │  • my-frontend                                                        │ │
│  │  • background-worker                                                  │ │
│  │                                                                       │ │
│  │  Alloy tenant-lab (optionnel) :                                      │ │
│  │  • Collecte seulement namespace=tenant-lab                           │ │
│  │  • Envoie vers tenant-root (ou stack dédiée)                         │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │ Applications (tous namespaces)                                        │ │
│  │                                                                       │ │
│  │  ┌────────────────────────────────────────────────────────────────┐  │ │
│  │  │ Application Pod                                                 │  │ │
│  │  │                                                                 │  │ │
│  │  │  Container:                                                     │  │ │
│  │  │  ┌──────────────────────────────────────────────────────────┐ │  │ │
│  │  │  │ App Process                                              │ │  │ │
│  │  │  │                                                          │ │  │ │
│  │  │  │ Logs:                                                    │ │  │ │
│  │  │  │ • stdout/stderr → JSON structuré                        │ │  │ │
│  │  │  │ • Fields: message, level, traceid, spanid, ...          │ │  │ │
│  │  │  │                                                          │ │  │ │
│  │  │  │ Métriques:                                               │ │  │ │
│  │  │  │ • Endpoint /metrics (Prometheus format)                  │ │  │ │
│  │  │  │ • Annotations: prometheus.io/scrape: "true"              │ │  │ │
│  │  │  │ • OU : OTLP → Alloy                                      │ │  │ │
│  │  │  │                                                          │ │  │ │
│  │  │  │ Traces:                                                  │ │  │ │
│  │  │  │ • OpenTelemetry SDK                                      │ │  │ │
│  │  │  │ • OTLP exporter → alloy:4317 ou :4318                   │ │  │ │
│  │  │  │ • Propagation W3C Trace Context                          │ │  │ │
│  │  │  │ • Spans imbriqués (DB, HTTP calls, etc.)                │ │  │ │
│  │  │  └──────────────────────────────────────────────────────────┘ │  │ │
│  │  │                                                                 │  │ │
│  │  │  Env vars (from ConfigMap):                                     │  │ │
│  │  │  • OTEL_EXPORTER_OTLP_ENDPOINT                                  │  │ │
│  │  │  • OTEL_SERVICE_NAME                                            │  │ │
│  │  │  • OTEL_RESOURCE_ATTRIBUTES                                     │  │ │
│  │  └──────────────────────────────────────────────────────────────────┘  │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Flux de données

### 1. Logs

```
┌─────────────┐
│ Application │
│  (stdout)   │
└──────┬──────┘
       │ JSON: {"message":"...", "level":"info", "traceid":"abc", ...}
       ▼
┌──────────────────┐
│ Alloy DaemonSet  │
│  (node local)    │
├──────────────────┤
│ • Capture logs   │
│ • Parse JSON     │
│ • Extract labels │
│ • Add metadata   │
└──────┬───────────┘
       │
       ▼
┌──────────────────┐
│  VictoriaLogs    │
├──────────────────┤
│ • Index          │
│ • Compress       │
│ • Retention 30d  │
└──────┬───────────┘
       │
       ▼
┌──────────────────┐
│     Grafana      │
│  (query LogsQL)  │
└──────────────────┘
```

### 2. Traces

```
┌─────────────┐
│ Application │
│ (OTLP SDK)  │
└──────┬──────┘
       │ OTLP gRPC:4317 ou HTTP:4318
       │ Spans: {trace_id, span_id, parent_span_id, ...}
       ▼
┌──────────────────┐
│ Alloy (OTLP      │
│  receiver)       │
├──────────────────┤
│ • Batch          │
│ • Enrich         │
│ • Generate       │
│   metrics        │
└──────┬───────────┘
       │
       ▼
┌──────────────────┐
│      Tempo       │
├──────────────────┤
│ • Store traces   │
│ • Build graph    │
│ • Retention 7d   │
└──────┬───────────┘
       │
       ▼
┌──────────────────┐
│     Grafana      │
│  (query TraceQL) │
│  • Service Map   │
│  • Flame graph   │
│  • Logs link     │
└──────────────────┘
```

### 3. Métriques

```
┌─────────────┐     ┌─────────────┐
│ Application │     │ Application │
│ /metrics    │     │ (OTLP SDK)  │
└──────┬──────┘     └──────┬──────┘
       │                   │ OTLP
       │ Prometheus        │
       │ format            │
       ▼                   ▼
┌────────────────────────────────┐
│        Alloy                   │
├────────────────────────────────┤
│ • Scrape (prometheus.io/*)     │
│ • Receive OTLP metrics         │
│ • Convert to Prometheus format │
│ • Relabel                      │
└──────┬─────────────────────────┘
       │
       ▼
┌──────────────────┐
│ VictoriaMetrics  │
├──────────────────┤
│ • Store TSDB     │
│ • Compress       │
│ • Retention 15d  │
│ • Alerting       │
└──────┬───────────┘
       │
       ▼
┌──────────────────┐
│     Grafana      │
│  (query PromQL)  │
└──────────────────┘
```

## Corrélation logs ↔ traces

```
1. Application génère une trace avec trace_id = "abc123"
   
2. Application log avec JSON: {"message":"...", "traceid":"abc123", ...}
   
3. Dans Grafana Explore (Tempo):
   • Sélectionner une trace
   • Cliquer sur "Logs for this span"
   • Grafana requête VictoriaLogs: {namespace="xxx"} | traceid="abc123"
   
4. Dans Grafana Explore (VictoriaLogs):
   • Voir un log avec traceid
   • Cliquer sur le lien de la trace
   • Grafana affiche la trace complète dans Tempo
```

## Stockage

```
┌────────────────────────────────────────────────────────────┐
│ LINSTOR (CozyStack storage)                                │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  PVC: victoria-logs-single-server                          │
│  • StorageClass: linstor-lvm-r1                           │
│  • Size: 50Gi                                              │
│  • Retention: 30d (~1.7 GB/jour)                          │
│                                                            │
│  PVC: tempo-data                                           │
│  • StorageClass: linstor-lvm-r1                           │
│  • Size: 20Gi                                              │
│  • Retention: 7d (168h)                                    │
│                                                            │
│  PVC: vmsingle-vm (CozyStack)                              │
│  • Géré par CozyStack                                      │
│  • Retention: définie par CozyStack                        │
└────────────────────────────────────────────────────────────┘
```

## Isolation par tenant

```
┌──────────────────────────────────────────────────────────────┐
│ Option 1 : Filtrage par namespace (simple)                  │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  • Toutes les données dans tenant-root                       │
│  • Dashboards avec variable $namespace                       │
│  • Requêtes: {namespace="tenant-lab"}                        │
│  • RBAC K8s : limiter accès Grafana par tenant              │
│                                                              │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ Option 2 : Alloy dédié par tenant (isolation forte)         │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  tenant-lab namespace:                                       │
│  ┌────────────────────────────────────────────┐            │
│  │ Alloy (deployment ou daemonset)            │            │
│  │ • Scrape seulement tenant-lab              │            │
│  │ • Envoie vers tenant-root ou stack dédiée  │            │
│  └────────────────────────────────────────────┘            │
│                                                              │
│  Avantages:                                                  │
│  • Isolation réseau                                          │
│  • Configuration spécifique                                  │
│  • Pas de fuite de données inter-tenant                     │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## Endpoints de service

| Service | DNS interne | Port | Protocole | Usage |
|---------|-------------|------|-----------|-------|
| VictoriaLogs | `victoria-logs-single-server.tenant-root.svc.cluster.local` | 9428 | HTTP | Push (Loki API) + Query (LogsQL) |
| Tempo | `tempo.tenant-root.svc.cluster.local` | 3200 | HTTP | Query (HTTP API) |
| Tempo | `tempo.tenant-root.svc.cluster.local` | 4317 | gRPC | OTLP ingestion (via Alloy) |
| Alloy | `alloy.tenant-root.svc.cluster.local` | 4317 | gRPC | OTLP receiver (traces + metrics) |
| Alloy | `alloy.tenant-root.svc.cluster.local` | 4318 | HTTP | OTLP receiver (traces + metrics) |
| VictoriaMetrics | `vmsingle-vm.tenant-root.svc.cluster.local` | 8429 | HTTP | Query (PromQL) + Remote Write |
| Grafana | `grafana.tenant-root.svc.cluster.local` | 80 | HTTP | UI + API |

## Formats de données

### Logs (VictoriaLogs - Loki API)

```json
{
  "streams": [
    {
      "stream": {
        "namespace": "demo-app",
        "pod": "my-app-abc123",
        "container": "app",
        "level": "info"
      },
      "values": [
        ["1699564800000000000", "{\"message\":\"User logged in\",\"user_id\":\"123\",\"traceid\":\"abc123\"}"]
      ]
    }
  ]
}
```

### Traces (OpenTelemetry / OTLP)

```protobuf
ResourceSpans {
  resource {
    attributes: [
      {key: "service.name", value: "my-app"},
      {key: "service.namespace", value: "demo-app"}
    ]
  }
  scopeSpans {
    spans {
      trace_id: "abc123...",
      span_id: "def456...",
      parent_span_id: "...",
      name: "GET /api/users",
      kind: SPAN_KIND_SERVER,
      attributes: [
        {key: "http.method", value: "GET"},
        {key: "http.status_code", value: 200}
      ]
    }
  }
}
```

### Métriques (Prometheus format)

```
# HELP http_requests_total Total number of HTTP requests
# TYPE http_requests_total counter
http_requests_total{method="GET",endpoint="/api/users",status="200"} 1234.0

# HELP http_request_duration_seconds HTTP request duration in seconds
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{endpoint="/api/users",le="0.1"} 100
http_request_duration_seconds_bucket{endpoint="/api/users",le="0.5"} 450
http_request_duration_seconds_bucket{endpoint="/api/users",le="+Inf"} 500
http_request_duration_seconds_sum{endpoint="/api/users"} 123.45
http_request_duration_seconds_count{endpoint="/api/users"} 500
```

## Ressources

### CPU et mémoire (estimations)

| Composant | CPU request | Memory request | Memory limit |
|-----------|-------------|----------------|--------------|
| VictoriaLogs | 200m | 512Mi | 2Gi |
| Tempo | 200m | 512Mi | 1Gi |
| Alloy (par pod) | 100m | 256Mi | 512Mi |
| VictoriaMetrics | - | - | (CozyStack) |
| Grafana | - | - | (CozyStack) |

### Dimensionnement stockage

**VictoriaLogs (50Gi, 30j)** :
- ~1.7 GB/jour pour un cluster moyen
- Compression efficace (~10x)
- Ajuster selon le volume de logs

**Tempo (20Gi, 7j)** :
- Dépend du taux de sampling
- ~3 GB/jour avec sampling 10%
- Compression ~5x

**VictoriaMetrics** :
- Géré par CozyStack
- ~7.8k samples/s → ~18 GB pour 15 jours

## Références

- Documentation complète : `docs/observability-cozystack.md`
- Démarrage rapide : `docs/QUICKSTART-OBSERVABILITY.md`
- Liste des fichiers : `docs/observability-files.md`
