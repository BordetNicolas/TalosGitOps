# Exemples d'observabilité CozyStack

Exemples d'applications instrumentées avec la stack d'observabilité CozyStack (métriques, logs, traces).

## Démarrage rapide

### 1. Déployer la stack d'observabilité

```bash
cd /home/napadelice/GitHub/TalosGitOps

# Générer les manifestes pour cozy-01
make CLUSTER=cozy-01 gitops-render

# Commiter et pousser
git add .
git commit -m "feat(cozy-01): add observability stack"
git push

# Vérifier le déploiement
export KUBECONFIG=clusters/cozy-01/kubeconfig
kubectl get applications -n argocd | grep observability
kubectl get pods -n tenant-root | grep -E 'victoria-logs|tempo|alloy'
```

### 2. Déployer l'application de démonstration

```bash
cd examples/observability/python-app

# Construire l'image (à adapter selon votre registry)
docker build -t python-demo-app:latest .

# Charger dans le cluster (pour test local)
# Méthode 1 : Via kind (si vous utilisez kind)
kind load docker-image python-demo-app:latest --name cozy-01

# Méthode 2 : Push vers un registry
docker tag python-demo-app:latest <your-registry>/python-demo-app:latest
docker push <your-registry>/python-demo-app:latest
# Puis modifier deployment.yaml avec l'image du registry

# Déployer
kubectl apply -f deployment.yaml

# Vérifier
kubectl get pods -n demo-app
kubectl logs -n demo-app -l app=python-demo-app --tail=20
```

### 3. Générer du trafic

```bash
# Port-forward vers l'application
kubectl port-forward -n demo-app svc/python-demo-app 8080:80

# Générer des requêtes
for i in {1..50}; do
  curl http://localhost:8080/
  curl http://localhost:8080/api/users
  curl http://localhost:8080/api/slow
  curl http://localhost:8080/api/error
  curl http://localhost:8080/api/chain
  sleep 0.5
done
```

### 4. Explorer dans Grafana

```bash
# Port-forward vers Grafana
kubectl port-forward -n tenant-root svc/grafana 3000:80

# Ouvrir http://localhost:3000
# Identifiants : voir `kubectl get secret -n tenant-root grafana-admin-secret`
```

**Explorer les données :**

1. **Métriques** (Explore → VictoriaMetrics) :
   ```promql
   # Taux de requêtes
   rate(http_requests_total[5m])
   
   # Latence P95
   histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))
   
   # Taux d'erreurs
   rate(http_requests_total{status="500"}[5m])
   ```

2. **Logs** (Explore → VictoriaLogs) :
   ```logsql
   # Tous les logs de l'app
   {namespace="demo-app"}
   
   # Logs d'erreur
   {namespace="demo-app"} | level="error"
   
   # Logs avec une trace
   {namespace="demo-app"} | traceid!=""
   ```

3. **Traces** (Explore → Tempo) :
   - Sélectionner service.name = "python-demo-app"
   - Chercher les traces > 1s
   - Cliquer sur une trace pour voir le détail
   - Cliquer sur "Logs for this span" pour corréler logs/traces

## Structure des exemples

```
examples/observability/
├── README.md                    # Ce fichier
├── python-app/                  # Application Python Flask
│   ├── app.py                   # Code avec instrumentation complète
│   ├── requirements.txt
│   ├── Dockerfile
│   └── deployment.yaml
├── go-app/                      # TODO: Application Go
└── dashboards/                  # Dashboards Grafana pré-configurés
    └── demo-app-dashboard.json
```

## Patterns d'instrumentation

### Python

Voir `python-app/app.py` pour un exemple complet avec :
- Logs structurés JSON avec contexte de trace
- Métriques Prometheus (Counter, Histogram)
- Métriques OpenTelemetry
- Traces OpenTelemetry avec spans imbriqués
- Auto-instrumentation Flask

### Go (exemple)

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// Setup tracer
exporter, _ := otlptracegrpc.New(ctx,
    otlptracegrpc.WithEndpoint("alloy.tenant-root.svc.cluster.local:4317"),
    otlptracegrpc.WithInsecure())

tp := trace.NewTracerProvider(trace.WithBatcher(exporter))
otel.SetTracerProvider(tp)

// Instrumenter HTTP handler
handler := otelhttp.NewHandler(http.HandlerFunc(myHandler), "my-handler")
```

### Node.js (exemple)

```javascript
const { NodeTracerProvider } = require('@opentelemetry/sdk-trace-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc');

const provider = new NodeTracerProvider();
provider.addSpanProcessor(
  new BatchSpanProcessor(
    new OTLPTraceExporter({
      url: 'alloy.tenant-root.svc.cluster.local:4317',
    })
  )
);
provider.register();
```

## Dashboards

### Importer un dashboard

```bash
# Port-forward vers Grafana
kubectl port-forward -n tenant-root svc/grafana 3000:80

# Dans Grafana UI:
# Dashboards → Import → Upload JSON file
# Sélectionner dashboards/demo-app-dashboard.json
```

### Créer un dashboard personnalisé

1. Dans Grafana : Dashboards → New → New Dashboard
2. Ajouter des panels avec les requêtes suivantes :

**RED metrics (Rate, Errors, Duration)** :

```promql
# Rate
rate(http_requests_total{namespace="demo-app"}[5m])

# Errors
rate(http_requests_total{namespace="demo-app",status=~"5.."}[5m])

# Duration (P50, P95, P99)
histogram_quantile(0.95, 
  rate(http_request_duration_seconds_bucket{namespace="demo-app"}[5m]))
```

**USE metrics (Utilization, Saturation, Errors)** :

```promql
# CPU utilization
rate(container_cpu_usage_seconds_total{namespace="demo-app"}[5m])

# Memory utilization
container_memory_working_set_bytes{namespace="demo-app"} 
  / container_spec_memory_limit_bytes{namespace="demo-app"}

# Errors
rate(kube_pod_container_status_restarts_total{namespace="demo-app"}[5m])
```

## Tests de charge

### Avec k6

```javascript
// load-test.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '1m', target: 10 },   // ramp-up
    { duration: '3m', target: 10 },   // steady
    { duration: '1m', target: 0 },    // ramp-down
  ],
};

export default function () {
  const endpoints = [
    'http://python-demo-app.demo-app.svc.cluster.local/',
    'http://python-demo-app.demo-app.svc.cluster.local/api/users',
    'http://python-demo-app.demo-app.svc.cluster.local/api/slow',
    'http://python-demo-app.demo-app.svc.cluster.local/api/error',
  ];

  const endpoint = endpoints[Math.floor(Math.random() * endpoints.length)];
  const res = http.get(endpoint);

  check(res, {
    'status is 200 or 500': (r) => r.status === 200 || r.status === 500,
  });

  sleep(1);
}
```

```bash
# Lancer k6 depuis un pod dans le cluster
kubectl run k6 --rm -it --restart=Never \
  --image=grafana/k6 \
  -- run - < load-test.js
```

### Avec hey

```bash
# Installer hey
go install github.com/rakyll/hey@latest

# Port-forward
kubectl port-forward -n demo-app svc/python-demo-app 8080:80

# Générer du trafic
hey -z 5m -c 10 -q 5 http://localhost:8080/api/users
```

## Alertes

### Exemples d'alertes pour l'app de démo

```yaml
# À ajouter dans vmalert-rules ConfigMap
groups:
  - name: demo_app_alerts
    interval: 30s
    rules:
      - alert: DemoAppHighErrorRate
        expr: |
          rate(http_requests_total{namespace="demo-app",status="500"}[5m])
          / rate(http_requests_total{namespace="demo-app"}[5m])
          > 0.05
        for: 5m
        labels:
          severity: warning
          namespace: demo-app
        annotations:
          summary: "High error rate in demo app"
          description: "Error rate is {{ $value | humanizePercentage }}"

      - alert: DemoAppHighLatency
        expr: |
          histogram_quantile(0.95,
            rate(http_request_duration_seconds_bucket{namespace="demo-app"}[5m])
          ) > 1
        for: 5m
        labels:
          severity: warning
          namespace: demo-app
        annotations:
          summary: "High latency in demo app"
          description: "P95 latency is {{ $value }}s"

      - alert: DemoAppDown
        expr: up{job="demo-app"} == 0
        for: 2m
        labels:
          severity: critical
          namespace: demo-app
        annotations:
          summary: "Demo app is down"
```

## Nettoyage

```bash
# Supprimer l'application de démo
kubectl delete namespace demo-app

# Si vous voulez supprimer toute la stack d'observabilité
kubectl delete application observability-stack -n argocd
```

## Ressources

- Documentation complète : `docs/observability-cozystack.md`
- [OpenTelemetry Python](https://opentelemetry.io/docs/instrumentation/python/)
- [Prometheus best practices](https://prometheus.io/docs/practices/naming/)
- [Grafana dashboards](https://grafana.com/grafana/dashboards/)
