# 📊 Stack d'observabilité CozyStack - Résumé

Stack d'observabilité complète pour CozyStack avec **métriques**, **logs** et **traces distribuées**, respectant les standards CozyStack et permettant l'isolation par tenant.

## ✅ Ce qui a été créé

### 🎯 Composants déployés

| Composant | Rôle | Stockage |
|-----------|------|----------|
| **VictoriaMetrics** | Métriques (déjà installé par CozyStack) | LINSTOR |
| **VictoriaLogs** | Logs centralisés (compatible Loki API) | LINSTOR 50Gi, rétention 30j |
| **Tempo** | Traces distribuées (OpenTelemetry) | LINSTOR 20Gi, rétention 7j |
| **Alloy** | Collecteur unifié (logs + traces + métriques OTEL) | DaemonSet |
| **Grafana** | Visualisation (déjà installé, datasources ajoutées) | LINSTOR |

### 📂 Fichiers créés (26 fichiers)

```
├── gitops-cozystack/
│   ├── apps/30-observability-stack.yaml           # Application ArgoCD
│   └── observability/
│       ├── README.md
│       ├── victoria-logs.yaml
│       ├── tempo.yaml
│       ├── alloy.yaml
│       └── grafana-datasources.yaml
│
├── docs/
│   ├── observability-cozystack.md                 # 📘 Guide complet (900+ lignes)
│   ├── QUICKSTART-OBSERVABILITY.md                # 🚀 Démarrage rapide
│   ├── observability-files.md                     # 📋 Liste des fichiers
│   └── observability-architecture.md              # 🏗️ Architecture détaillée
│
├── examples/observability/
│   ├── README.md
│   ├── python-app/                                # App Python instrumentée
│   │   ├── app.py                                 # Logs + métriques + traces
│   │   ├── requirements.txt
│   │   ├── Dockerfile
│   │   └── deployment.yaml
│   └── dashboards/
│       └── demo-app-dashboard.json                # Dashboard Grafana
│
└── scripts/
    ├── test-observability.sh                      # Tests automatisés
    └── init-app-observability.sh                  # Init rapide nouvelle app
```

## 🚀 Démarrage rapide (5 min)

### 1. Déployer la stack

```bash
cd /home/napadelice/GitHub/TalosGitOps

# Générer et déployer
make CLUSTER=cozy-01 gitops-render
git add . && git commit -m "feat: add observability stack" && git push

# Attendre le déploiement ArgoCD
kubectl get applications -n argocd observability-stack
```

### 2. Tester

```bash
# Test automatisé complet
make CLUSTER=cozy-01 test-observability

# Ou manuellement
kubectl get pods -n tenant-root | grep -E 'victoria-logs|tempo|alloy'
```

### 3. Explorer dans Grafana

```bash
# Port-forward
kubectl port-forward -n tenant-root svc/grafana 3000:80

# Ouvrir http://localhost:3000
# Admin password:
kubectl get secret -n tenant-root grafana-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

**Dans Grafana → Explore :**

- **Métriques** (VictoriaMetrics) : `rate(http_requests_total[5m])`
- **Logs** (VictoriaLogs) : `{namespace="demo-app"}`
- **Traces** (Tempo) : Service name = "python-demo-app"

## 📚 Documentation

| Document | Contenu | Lien |
|----------|---------|------|
| **Démarrage rapide** | Déployer et utiliser en 10 min | `docs/QUICKSTART-OBSERVABILITY.md` |
| **Guide complet** | Architecture, requêtes, dashboards, alertes, troubleshooting | `docs/observability-cozystack.md` |
| **Architecture** | Schémas détaillés, flux de données | `docs/observability-architecture.md` |
| **Fichiers** | Liste complète des fichiers créés | `docs/observability-files.md` |
| **Exemples** | Applications instrumentées | `examples/observability/` |

## 🔧 Instrumenter une application

### Méthode rapide

```bash
./scripts/init-app-observability.sh my-api production
# Génère : ConfigMap OTLP + Deployment template + Snippets de code
```

### Manuellement

**1. Ajouter annotations Prometheus au Service :**

```yaml
apiVersion: v1
kind: Service
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: "/metrics"
```

**2. Envoyer des logs JSON structurés :**

```python
import json
logger.info(json.dumps({
    "message": "User logged in",
    "level": "info",
    "traceid": trace_id,
    "user_id": "123"
}))
```

**3. Instrumenter avec OpenTelemetry :**

```python
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

exporter = OTLPSpanExporter(
    endpoint="alloy.tenant-root.svc.cluster.local:4317",
    insecure=True
)
```

Voir `examples/observability/python-app/app.py` pour un exemple complet.

## 🎯 Use cases

### Déboguer une erreur

1. **Voir l'erreur dans les métriques** (pic de `http_requests_total{status="500"}`)
2. **Trouver les logs** : `{namespace="my-app"} | level="error"`
3. **Voir la trace** : Cliquer sur `traceid` dans le log
4. **Analyser** : Service graph, span details, durées

### Optimiser les performances

1. **Latence P95** : `histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))`
2. **Traces lentes** : Tempo → Duration > 1s
3. **Identifier le bottleneck** : Span le plus long dans la trace
4. **Corréler avec les ressources** : CPU, mémoire, DB

### Surveillance proactive

1. **Créer des dashboards** : RED metrics (Rate, Errors, Duration)
2. **Configurer des alertes** : Taux d'erreur > 5%, latence > 1s
3. **Suivre les tendances** : Évolution sur 7 jours

## 🔗 Endpoints

| Service | URL interne | Port | Usage |
|---------|-------------|------|-------|
| VictoriaLogs | `victoria-logs-single-server.tenant-root.svc.cluster.local` | 9428 | Push + Query logs |
| Tempo | `tempo.tenant-root.svc.cluster.local` | 3200 | Query traces |
| Alloy OTLP | `alloy.tenant-root.svc.cluster.local` | 4317/4318 | Receive traces/metrics |
| VictoriaMetrics | `vmsingle-vm.tenant-root.svc.cluster.local` | 8429 | Query metrics |
| Grafana | `grafana.tenant-root.svc.cluster.local` | 80 | UI |

## 📊 Exemples de requêtes

### Métriques (PromQL)

```promql
# Taux de requêtes
sum(rate(http_requests_total[5m])) by (endpoint)

# Taux d'erreurs
rate(http_requests_total{status="500"}[5m]) / rate(http_requests_total[5m])

# Latence P95
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))

# CPU par pod
rate(container_cpu_usage_seconds_total[5m])
```

### Logs (LogsQL)

```logsql
# Tous les logs d'un namespace
{namespace="demo-app"}

# Logs d'erreur
{namespace="demo-app"} | level="error"

# Logs contenant "timeout"
{namespace="demo-app"} | "timeout"

# Logs d'une trace
{namespace="demo-app"} | traceid="abc123"

# Agrégation
{namespace="demo-app"} | level="error" | stats count() by (pod)
```

### Traces (TraceQL)

```traceql
# Traces d'un service
{ service.name = "my-app" }

# Traces lentes
{ duration > 1s }

# Traces avec erreurs
{ status = error }

# Traces avec attribut spécifique
{ http.status_code = 500 }
```

## 🎨 Dashboards

### Importer le dashboard de démo

```bash
# Dans Grafana : Dashboards → Import → Upload JSON
# Fichier : examples/observability/dashboards/demo-app-dashboard.json
```

### Créer un dashboard personnalisé

**Panels recommandés** :
1. Request Rate (timeseries)
2. Error Rate (timeseries + threshold)
3. Latency P50/P95/P99 (timeseries)
4. Active Pods (stat)
5. Recent Error Logs (logs panel)
6. Trace Service Graph (node graph)

## 🧪 Application de démo

```bash
cd examples/observability/python-app

# Build et déployer
docker build -t python-demo-app:latest .
kubectl apply -f deployment.yaml

# Générer du trafic
kubectl port-forward -n demo-app svc/python-demo-app 8080:80
for i in {1..100}; do curl -s http://localhost:8080/api/users; done

# Voir dans Grafana
kubectl port-forward -n tenant-root svc/grafana 3000:80
```

## 🛠️ Commandes utiles

```bash
# Status de la stack
make CLUSTER=cozy-01 test-observability

# Logs des composants
kubectl logs -n tenant-root -l app.kubernetes.io/name=alloy --tail=100
kubectl logs -n tenant-root -l app.kubernetes.io/name=victoria-logs-single --tail=100
kubectl logs -n tenant-root -l app.kubernetes.io/name=tempo --tail=100

# Tester l'ingestion de logs
kubectl run test-log --rm -i --restart=Never --image=curlimages/curl -n tenant-root -- \
  curl -X POST http://victoria-logs-single-server.tenant-root.svc.cluster.local:9428/insert/loki/api/v1/push \
  -H "Content-Type: application/json" \
  -d '{"streams":[{"stream":{"test":"true"},"values":[["'$(date +%s%N)'","test"]]}]}'

# Port-forwards
kubectl port-forward -n tenant-root svc/grafana 3000:80
kubectl port-forward -n tenant-root svc/victoria-logs-single-server 9428:9428
kubectl port-forward -n tenant-root svc/tempo 3200:3200
```

## 🔐 Isolation par tenant

### Option 1 : Filtrage par namespace (simple)

Toutes les données dans `tenant-root`, dashboards filtrés par namespace.

### Option 2 : Alloy dédié par tenant (avancé)

Déployer un Alloy par tenant qui collecte seulement son namespace.

Voir `docs/observability-cozystack.md` section "Isolation par tenant".

## 🚨 Alerting

Configurer des alertes dans VictoriaMetrics :

```yaml
- alert: HighErrorRate
  expr: rate(http_requests_total{status=~"5.."}[5m]) > 0.05
  for: 5m
  annotations:
    summary: "High error rate in {{ $labels.namespace }}"
```

## 🐛 Troubleshooting

### Les logs n'apparaissent pas

```bash
# Vérifier Alloy
kubectl get pods -n tenant-root -l app.kubernetes.io/name=alloy
kubectl logs -n tenant-root daemonset/alloy | grep -i error

# Tester VictoriaLogs
kubectl exec -n tenant-root victoria-logs-xxx -- wget -qO- http://localhost:9428/health
```

### Les traces ne sont pas visibles

```bash
# Vérifier les logs d'Alloy
kubectl logs -n tenant-root daemonset/alloy | grep -i otlp

# Vérifier Tempo
kubectl logs -n tenant-root tempo-xxx | grep -i receive

# Vérifier l'endpoint OTLP
kubectl exec -n tenant-root alloy-xxx -- netstat -ln | grep 4317
```

Voir `docs/observability-cozystack.md` section "Troubleshooting" pour plus de détails.

## 📈 Prochaines étapes

1. ✅ Déployer la stack
2. ✅ Tester avec l'app de démo
3. ⏭️ Instrumenter vos applications
4. ⏭️ Créer des dashboards personnalisés
5. ⏭️ Configurer des alertes
6. ⏭️ Mettre en place l'isolation par tenant

## 🆘 Support

- **Documentation** : Voir `docs/` pour guides complets
- **Exemples** : Voir `examples/observability/` pour code instrumenté
- **Issues** : https://github.com/BordetNicolas/TalosGitOps/issues

## 🔗 Ressources externes

- [VictoriaMetrics docs](https://docs.victoriametrics.com/)
- [VictoriaLogs docs](https://docs.victoriametrics.com/victorialogs/)
- [Grafana Tempo docs](https://grafana.com/docs/tempo/latest/)
- [OpenTelemetry docs](https://opentelemetry.io/docs/)
- [CozyStack docs](https://cozystack.io/docs/)

---

**🎉 Votre stack d'observabilité CozyStack est prête !**

Commencez par : `docs/QUICKSTART-OBSERVABILITY.md`
