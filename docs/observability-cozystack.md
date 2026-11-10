# Observabilité CozyStack

Stack d'observabilité complète pour le cluster `cozy-01`, basée sur les standards CozyStack et permettant l'isolation par tenant.

## Architecture

```
┌───────────────────────────────────────────────────────┐
│ Tenant: root (plateforme)                            │
│                                                       │
│  ┌─────────────────┐  ┌──────────────┐              │
│  │ VictoriaMetrics │  │ VictoriaLogs │              │
│  │  (CozyStack)    │  │   (ajouté)   │              │
│  │                 │  │              │              │
│  │  - Métriques    │  │  - Logs      │              │
│  │  - Alertes      │  │  - Retention │              │
│  └────────▲────────┘  └──────▲───────┘              │
│           │                  │                       │
│  ┌────────┴──────────────────┴───────┐              │
│  │         Grafana                    │              │
│  │  (CozyStack + datasources)         │              │
│  └────────────────────────────────────┘              │
│           │                                          │
│  ┌────────┴────────┐                                │
│  │     Tempo       │                                │
│  │   (Traces)      │                                │
│  └─────────────────┘                                │
└───────────────────────────────────────────────────────┘
            ▲                        ▲
            │                        │
    ┌───────┴────────┐       ┌───────┴────────┐
    │ Alloy          │       │ Alloy          │
    │ (DaemonSet)    │       │ (sidecar opt.) │
    │ Cluster-wide   │       │ per-tenant     │
    └────────────────┘       └────────────────┘
            ▲                        ▲
            │                        │
    ┌───────┴────────────────────────┴──────────┐
    │  Applications & Workloads                 │
    │                                            │
    │  - Logs stdout/stderr                     │
    │  - Métriques /metrics                     │
    │  - Traces OTLP gRPC:4317 / HTTP:4318     │
    └────────────────────────────────────────────┘
```

## Composants

| Composant | Rôle | Stockage | Rétention |
|---|---|---|---|
| **VictoriaMetrics** | Métriques (déjà installé par CozyStack) | LINSTOR | Défini par CozyStack |
| **VictoriaLogs** | Logs centralisés (compatible Loki API) | LINSTOR 50Gi | 30 jours |
| **Tempo** | Traces distribuées OpenTelemetry | LINSTOR 20Gi | 7 jours |
| **Alloy** | Collecteur unifié (logs + traces + métriques OTEL) | - | - |
| **Grafana** | Visualisation (déjà installé, datasources ajoutées) | LINSTOR | - |

## Installation

### 1. Déployer la stack

```bash
# Vérifier que le tenant root est configuré avec monitoring: true
kubectl get tenant root -n tenant-root -o yaml

# Ajouter l'application à ArgoCD
cd /home/napadelice/GitHub/TalosGitOps
make CLUSTER=cozy-01 gitops-render

# Commiter et pousser
git add clusters/cozy-01/gitops gitops-cozystack/
git commit -m "feat(cozy-01): add observability stack"
git push

# Vérifier le déploiement
export KUBECONFIG=clusters/cozy-01/kubeconfig
kubectl get applications -n argocd | grep observability
kubectl get pods -n tenant-root | grep -E 'victoria-logs|tempo|alloy'
```

### 2. Configurer Grafana

Le Grafana de CozyStack doit être configuré pour charger les datasources additionnelles.

**Option A : Via les ConfigMaps (recommandé)**

Les ConfigMaps `grafana-extra-datasources` et `grafana-extra-plugins` sont déjà créés. Il faut configurer le Grafana de CozyStack pour les lire :

```bash
# Vérifier la configuration actuelle du Grafana CozyStack
kubectl get helmrelease grafana -n tenant-root -o yaml

# Si le HelmRelease permet de monter des ConfigMaps additionnelles,
# l'ajout se fait via le Package cozystack-platform
```

**Option B : Configuration manuelle (temporaire)**

```bash
# Port-forward vers Grafana
kubectl port-forward -n tenant-root svc/grafana 3000:80

# Accéder à http://localhost:3000
# Aller dans Configuration > Data sources > Add data source

# Ajouter VictoriaLogs
# Type: Loki (compatible)
# URL: http://victoria-logs-single-server.tenant-root.svc.cluster.local:9428
# HTTP Method: POST

# Ajouter Tempo
# Type: Tempo
# URL: http://tempo.tenant-root.svc.cluster.local:3200
# Linked Tracing Data: VictoriaLogs (filtrer par trace ID)
```

### 3. Vérifier les endpoints

```bash
# VictoriaMetrics (déjà installé)
kubectl port-forward -n tenant-root svc/vmsingle-vm 8429:8429
curl http://localhost:8429/api/v1/query?query=up

# VictoriaLogs
kubectl port-forward -n tenant-root svc/victoria-logs-single-server 9428:9428
curl http://localhost:9428/select/logsql/query -d 'query={namespace="default"}'

# Tempo
kubectl port-forward -n tenant-root svc/tempo 3200:3200
curl http://localhost:3200/api/search

# Alloy (OTLP endpoints)
kubectl port-forward -n tenant-root daemonset/alloy 4317:4317 4318:4318
```

## Utilisation

### 📊 Métriques (VictoriaMetrics)

#### Instrumenter une application

**Prometheus metrics endpoint** (déjà supporté) :

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  annotations:
    prometheus.io/scrape: "true"    # Active le scraping
    prometheus.io/port: "8080"      # Port des métriques
    prometheus.io/path: "/metrics"  # Endpoint (défaut: /metrics)
spec:
  ports:
    - name: metrics
      port: 8080
```

**Métriques OpenTelemetry** via Alloy :

```python
# Python + OpenTelemetry
from opentelemetry import metrics
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader

# Exporter vers Alloy
exporter = OTLPMetricExporter(
    endpoint="alloy.tenant-root.svc.cluster.local:4317",
    insecure=True
)

reader = PeriodicExportingMetricReader(exporter)
provider = MeterProvider(metric_readers=[reader])
metrics.set_meter_provider(provider)

# Créer des métriques
meter = metrics.get_meter(__name__)
counter = meter.create_counter("requests_total")
counter.add(1, {"endpoint": "/api/v1/users"})
```

#### Requêtes VictoriaMetrics (PromQL)

```promql
# Top 5 des pods par CPU
topk(5, rate(container_cpu_usage_seconds_total[5m]))

# Mémoire par namespace
sum by (namespace) (container_memory_working_set_bytes)

# Requêtes HTTP par code de statut
sum by (status_code) (rate(http_requests_total[5m]))

# Latence P95 des requêtes
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))
```

### 📝 Logs (VictoriaLogs)

#### Envoyer des logs

**Option 1 : stdout/stderr** (automatique via Alloy)

Les logs écrits sur stdout/stderr sont automatiquement collectés :

```python
import logging
import json

# Logs structurés JSON (recommandé)
logging.basicConfig(
    format='%(message)s',
    level=logging.INFO
)

logger = logging.getLogger(__name__)

# Log avec contexte de trace
logger.info(json.dumps({
    "message": "User created",
    "user_id": "12345",
    "level": "info",
    "traceid": trace_id,  # Lien avec les traces
    "spanid": span_id
}))
```

**Option 2 : Push direct vers VictoriaLogs** (Loki API)

```bash
# Format Loki/VictoriaLogs
curl -X POST http://victoria-logs-single-server.tenant-root.svc.cluster.local:9428/insert/loki/api/v1/push \
  -H "Content-Type: application/json" \
  -d '{
    "streams": [{
      "stream": {
        "app": "my-app",
        "level": "info"
      },
      "values": [
        ["'$(date +%s%N)'", "User login successful"]
      ]
    }]
  }'
```

#### Requêtes VictoriaLogs (LogsQL)

```logsql
# Logs d'un namespace
{namespace="default"}

# Logs avec niveau error
{namespace="default"} | level="error"

# Logs contenant "timeout"
{namespace="default"} | "timeout"

# Logs par tenant
{tenant="lab"} | level="error"

# Logs liés à une trace
{namespace="default"} | traceid="abc123"

# Agrégation : nombre d'erreurs par pod
{namespace="default"} | level="error" | stats count() by (pod)

# Logs dans les dernières 5 minutes avec pattern
{namespace="default"} [5m] | re("user_id=(?P<user>\w+)")
```

### 🔍 Traces (Tempo)

#### Instrumenter une application

**Python + OpenTelemetry** :

```python
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource

# Configuration
resource = Resource.create({"service.name": "my-app"})
provider = TracerProvider(resource=resource)

# Exporter vers Alloy
otlp_exporter = OTLPSpanExporter(
    endpoint="alloy.tenant-root.svc.cluster.local:4317",
    insecure=True
)

provider.add_span_processor(BatchSpanProcessor(otlp_exporter))
trace.set_tracer_provider(provider)

# Créer des spans
tracer = trace.get_tracer(__name__)

with tracer.start_as_current_span("handle_request") as span:
    span.set_attribute("http.method", "GET")
    span.set_attribute("http.url", "/api/users")
    
    # Sous-span
    with tracer.start_as_current_span("database_query"):
        # Code de requête DB
        pass
    
    span.set_attribute("http.status_code", 200)
```

**Go + OpenTelemetry** :

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/sdk/trace"
    "google.golang.org/grpc"
    "google.golang.org/grpc/credentials/insecure"
)

// Setup tracer
ctx := context.Background()
conn, _ := grpc.DialContext(ctx, "alloy.tenant-root.svc.cluster.local:4317",
    grpc.WithTransportCredentials(insecure.NewCredentials()))

exporter, _ := otlptracegrpc.New(ctx, otlptracegrpc.WithGRPCConn(conn))
tp := trace.NewTracerProvider(trace.WithBatcher(exporter))
otel.SetTracerProvider(tp)

// Utiliser
tracer := otel.Tracer("my-app")
ctx, span := tracer.Start(ctx, "operation")
defer span.End()
```

**Avec auto-instrumentation (sidecar)** :

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    metadata:
      annotations:
        instrumentation.opentelemetry.io/inject: "true"
    spec:
      containers:
        - name: app
          image: my-app:latest
          env:
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://alloy.tenant-root.svc.cluster.local:4318"
```

#### Requêtes dans Grafana

Dans Grafana > Explore > Tempo :

- **Search** : Chercher des traces par service, durée, tags
- **TraceQL** : Langage de requête avancé

```traceql
# Traces d'un service
{ service.name = "my-app" }

# Traces lentes (>1s)
{ duration > 1s }

# Traces avec erreurs
{ status = error }

# Traces avec attribut spécifique
{ http.status_code = 500 }

# Combinaison
{ service.name = "api" && duration > 500ms && http.method = "POST" }
```

## Dashboards Grafana

### Dashboards recommandés

1. **CozyStack Cluster Overview** (déjà fourni)
2. **VictoriaLogs Dashboard** (logs par namespace/pod)
3. **Tempo Service Graph** (map des services)
4. **Application Performance Monitoring (APM)**

### Créer un dashboard APM personnalisé

```bash
# Importer via l'UI Grafana ou API
kubectl port-forward -n tenant-root svc/grafana 3000:80

# Dashboard.json exemple (à importer)
```

**Panels recommandés** :

```json
{
  "panels": [
    {
      "title": "Request Rate",
      "targets": [{
        "expr": "rate(http_requests_total[5m])"
      }]
    },
    {
      "title": "Error Rate",
      "targets": [{
        "expr": "rate(http_requests_total{status=~\"5..\"}[5m])"
      }]
    },
    {
      "title": "Latency P95",
      "targets": [{
        "expr": "histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))"
      }]
    },
    {
      "title": "Recent Errors",
      "datasource": "VictoriaLogs",
      "targets": [{
        "expr": "{namespace=\"$namespace\"} | level=\"error\""
      }]
    },
    {
      "title": "Trace Service Map",
      "datasource": "Tempo",
      "type": "nodeGraph"
    }
  ]
}
```

## Isolation par tenant

### Configuration multi-tenant

Pour isoler l'observabilité d'un tenant spécifique (ex: `tenant-lab`) :

**1. Déployer Alloy dédié au tenant**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: alloy-tenant-lab
  namespace: argocd
spec:
  source:
    repoURL: https://grafana.github.io/helm-charts
    chart: alloy
    targetRevision: 1.8.1
    helm:
      values: |
        alloy:
          configMap:
            content: |
              discovery.kubernetes "pods" {
                role = "pod"
                namespaces {
                  names = ["tenant-lab"]  # Seulement ce tenant
                }
              }
              
              # ... reste de la config (logs + traces vers tenant-root)
  destination:
    namespace: tenant-lab
```

**2. Créer un Grafana dédié** (optionnel)

```yaml
# Dans tenant-lab, avec datasources pointant vers tenant-root
# Ou : créer des dashboards filtrés par namespace="tenant-lab"
```

**3. Contrôle d'accès RBAC**

```yaml
apiVersion: rbac.authorization.gat.io/v1
kind: Role
metadata:
  name: tenant-lab-viewer
  namespace: tenant-lab
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-lab-viewer
  namespace: tenant-lab
subjects:
  - kind: User
    name: lab-user
roleRef:
  kind: Role
  name: tenant-lab-viewer
  apiGroup: rbac.authorization.k8s.io
```

## Alerting

### Configurer des alertes dans VictoriaMetrics

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vmalert-rules
  namespace: tenant-root
data:
  alerts.yaml: |
    groups:
      - name: cozystack_alerts
        interval: 30s
        rules:
          - alert: HighErrorRate
            expr: rate(http_requests_total{status=~"5.."}[5m]) > 0.05
            for: 5m
            labels:
              severity: warning
              tenant: "{{ $labels.namespace }}"
            annotations:
              summary: "High error rate in {{ $labels.namespace }}"
              description: "Error rate is {{ $value | humanizePercentage }}"
          
          - alert: PodCrashLooping
            expr: rate(kube_pod_container_status_restarts_total[15m]) > 0
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Pod {{ $labels.pod }} is crash looping"
          
          - alert: HighMemoryUsage
            expr: container_memory_working_set_bytes / container_spec_memory_limit_bytes > 0.9
            for: 10m
            labels:
              severity: warning
            annotations:
              summary: "Container {{ $labels.container }} memory usage > 90%"
```

### Intégrer Alertmanager (optionnel)

Si vous voulez des notifications (Telegram, Slack, etc.) :

```bash
# Déployer Alertmanager dans tenant-root
# Configurer VictoriaMetrics pour envoyer les alertes à Alertmanager
```

## Troubleshooting

### Vérifier la collecte de logs

```bash
# Logs d'Alloy (collecteur)
kubectl logs -n tenant-root daemonset/alloy --tail=100

# Test d'envoi vers VictoriaLogs
kubectl run test-log --rm -i --restart=Never --image=curlimages/curl -- \
  curl -X POST http://victoria-logs-single-server.tenant-root.svc.cluster.local:9428/insert/loki/api/v1/push \
  -H "Content-Type: application/json" \
  -d '{"streams":[{"stream":{"test":"true"},"values":[["'$(date +%s%N)'","test message"]]}]}'

# Requêter VictoriaLogs
kubectl port-forward -n tenant-root svc/victoria-logs-single-server 9428:9428
curl 'http://localhost:9428/select/logsql/query?query={test="true"}'
```

### Vérifier les traces

```bash
# Logs de Tempo
kubectl logs -n tenant-root statefulset/tempo --tail=100

# Test d'envoi OTLP
kubectl run test-trace --rm -i --restart=Never --image=curlimages/curl -- \
  curl -X POST http://alloy.tenant-root.svc.cluster.local:4318/v1/traces \
  -H "Content-Type: application/json" \
  -d '{"resourceSpans":[...]}'

# Voir les traces récentes dans Grafana
kubectl port-forward -n tenant-root svc/tempo 3200:3200
curl http://localhost:3200/api/search?limit=10
```

### Vérifier les métriques

```bash
# ServiceMonitors créés
kubectl get servicemonitor -n tenant-root

# Targets dans VictoriaMetrics
kubectl port-forward -n tenant-root svc/vmsingle-vm 8429:8429
curl http://localhost:8429/api/v1/targets

# Vérifier qu'une métrique existe
curl 'http://localhost:8429/api/v1/query?query=up'
```

### Problèmes courants

**1. Les logs n'apparaissent pas dans VictoriaLogs**

```bash
# Vérifier qu'Alloy tourne sur tous les nœuds
kubectl get pods -n tenant-root -l app.kubernetes.io/name=alloy -o wide

# Vérifier la config Alloy
kubectl get configmap -n tenant-root alloy -o yaml

# Tester la connexion
kubectl exec -n tenant-root daemonset/alloy -- \
  wget -O- http://victoria-logs-single-server.tenant-root.svc.cluster.local:9428/health
```

**2. Les traces ne sont pas reçues par Tempo**

```bash
# Vérifier que l'app envoie bien vers Alloy:4317 ou :4318
# Vérifier les logs Alloy
kubectl logs -n tenant-root daemonset/alloy | grep -i otlp

# Vérifier Tempo
kubectl logs -n tenant-root statefulset/tempo | grep -i receive
```

**3. Grafana ne voit pas les datasources**

```bash
# Vérifier que les ConfigMaps existent
kubectl get cm -n tenant-root grafana-extra-datasources

# Redémarrer Grafana si nécessaire
kubectl rollout restart deployment/grafana -n tenant-root
```

## Évolution et optimisation

### Passer à une architecture scalable

Si le volume de données augmente :

1. **VictoriaMetrics en cluster** :
   ```yaml
   # Remplacer vmsingle par vmcluster (vmselect, vminsert, vmstorage)
   ```

2. **VictoriaLogs en cluster** (quand disponible)

3. **Tempo distributed** :
   ```yaml
   # Passer de tempo (monolithic) à tempo-distributed
   # (distributor, ingester, querier, compactor)
   ```

### Optimiser les coûts de stockage

```yaml
# Réduire la rétention
# VictoriaLogs
retentionPeriod: "15d"  # au lieu de 30d

# Tempo
retention: 72h  # au lieu de 168h

# Compresser les données
persistence:
  storageClassName: linstor-lvm-r1-compressed
```

### Ajouter du sampling de traces

```alloy
// Dans la config Alloy
otelcol.processor.probabilistic_sampler "default" {
  sampling_percentage = 10  // Ne garder que 10% des traces
  output {
    traces = [otelcol.exporter.otlp.tempo.input]
  }
}
```

## Ressources

- [VictoriaMetrics docs](https://docs.victoriametrics.com/)
- [VictoriaLogs docs](https://docs.victoriametrics.com/victorialogs/)
- [Grafana Tempo docs](https://grafana.com/docs/tempo/latest/)
- [Grafana Alloy docs](https://grafana.com/docs/alloy/latest/)
- [OpenTelemetry docs](https://opentelemetry.io/docs/)
- [CozyStack monitoring](https://cozystack.io/docs/monitoring/)
