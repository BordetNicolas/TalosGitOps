# 🚀 Démarrage rapide : Observabilité CozyStack

Guide pour déployer et utiliser la stack d'observabilité en 10 minutes.

## Prérequis

- Cluster CozyStack `cozy-01` déployé
- `kubectl` configuré avec le kubeconfig du cluster
- Git avec accès au dépôt

## 1. Déployer la stack (5 min)

```bash
cd /home/napadelice/GitHub/TalosGitOps

# Générer les manifestes ArgoCD
make CLUSTER=cozy-01 gitops-render

# Vérifier les fichiers créés
ls -l clusters/cozy-01/gitops/observability/

# Commiter et pousser
git add clusters/cozy-01/gitops gitops-cozystack/
git commit -m "feat(cozy-01): add observability stack"
git push

# Attendre le déploiement (ArgoCD sync automatique)
export KUBECONFIG=clusters/cozy-01/kubeconfig
watch kubectl get applications -n argocd

# Attendre que observability-stack soit "Healthy" et "Synced"
```

**Vérifier que tout fonctionne :**

```bash
# Test automatisé
make CLUSTER=cozy-01 test-observability

# Ou manuellement
kubectl get pods -n tenant-root | grep -E 'victoria-logs|tempo|alloy'
```

## 2. Déployer l'application de démo (2 min)

```bash
cd examples/observability/python-app

# Construire l'image
docker build -t python-demo-app:latest .

# Charger dans le cluster (adapter selon votre setup)
# Option A : Kind
kind load docker-image python-demo-app:latest --name cozy-01

# Option B : Registry privé
# docker tag python-demo-app:latest registry.cozy-01.alexetnico.com/python-demo-app:latest
# docker push registry.cozy-01.alexetnico.com/python-demo-app:latest
# Puis modifier deployment.yaml avec l'image du registry

# Déployer
kubectl apply -f deployment.yaml

# Vérifier
kubectl get pods -n demo-app
kubectl logs -n demo-app -l app=python-demo-app --tail=10
```

## 3. Générer du trafic (1 min)

```bash
# Port-forward vers l'app
kubectl port-forward -n demo-app svc/python-demo-app 8080:80 &

# Générer des requêtes
for i in {1..100}; do
  curl -s http://localhost:8080/ >/dev/null
  curl -s http://localhost:8080/api/users >/dev/null
  curl -s http://localhost:8080/api/slow >/dev/null
  curl -s http://localhost:8080/api/error >/dev/null
  curl -s http://localhost:8080/api/chain >/dev/null
  sleep 0.2
done

echo "✓ Generated 500 requests"
```

## 4. Explorer dans Grafana (2 min)

```bash
# Port-forward vers Grafana
kubectl port-forward -n tenant-root svc/grafana 3000:80

# Ouvrir http://localhost:3000
# Login: admin / <voir le secret>
kubectl get secret -n tenant-root grafana-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

### Aller dans Explore

**1. Métriques (VictoriaMetrics)**

```promql
# Taux de requêtes par endpoint
sum(rate(http_requests_total{namespace="demo-app"}[5m])) by (endpoint)

# Latence P95
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket{namespace="demo-app"}[5m]))

# Taux d'erreurs
rate(http_requests_total{namespace="demo-app",status="500"}[5m]) 
  / rate(http_requests_total{namespace="demo-app"}[5m])
```

**2. Logs (VictoriaLogs)**

```logsql
# Tous les logs de l'app
{namespace="demo-app"}

# Logs d'erreur
{namespace="demo-app"} | level="error"

# Logs d'un endpoint spécifique
{namespace="demo-app"} | endpoint="/api/slow"

# Logs liés à une trace (copier un traceid depuis Tempo)
{namespace="demo-app"} | traceid="abc123..."
```

**3. Traces (Tempo)**

- Service name: `python-demo-app`
- Duration: `> 1s` (traces lentes)
- Cliquer sur une trace pour voir le détail
- Cliquer sur "Logs for this span" pour voir les logs corrélés

### Importer un dashboard

```bash
# Dans Grafana: Dashboards → Import → Upload JSON file
# Sélectionner: examples/observability/dashboards/demo-app-dashboard.json
```

## Commandes utiles

### Vérifier les composants

```bash
# Pods de la stack
kubectl get pods -n tenant-root | grep -E 'victoria-logs|tempo|alloy'

# Logs d'Alloy (collecteur)
kubectl logs -n tenant-root daemonset/alloy --tail=100 -f

# Logs de VictoriaLogs
kubectl logs -n tenant-root -l app.kubernetes.io/name=victoria-logs-single --tail=100

# Logs de Tempo
kubectl logs -n tenant-root -l app.kubernetes.io/name=tempo --tail=100
```

### Endpoints directs (sans Grafana)

```bash
# VictoriaLogs
kubectl port-forward -n tenant-root svc/victoria-logs-single-server 9428:9428
curl 'http://localhost:9428/select/logsql/query?query={namespace="demo-app"}'

# Tempo
kubectl port-forward -n tenant-root svc/tempo 3200:3200
curl http://localhost:3200/api/search?limit=10

# VictoriaMetrics
kubectl port-forward -n tenant-root svc/vmsingle-vm 8429:8429
curl 'http://localhost:8429/api/v1/query?query=up{namespace="demo-app"}'
```

### Tester l'ingestion

```bash
# Envoyer un log de test
kubectl run test-log --rm -i --restart=Never --image=curlimages/curl -n tenant-root -- \
  curl -X POST http://victoria-logs-single-server.tenant-root.svc.cluster.local:9428/insert/loki/api/v1/push \
  -H "Content-Type: application/json" \
  -d '{"streams":[{"stream":{"test":"true"},"values":[["'$(date +%s%N)'","Hello from CLI"]]}]}'

# Requêter le log
sleep 2
kubectl run test-query --rm -i --restart=Never --image=curlimages/curl -n tenant-root -- \
  curl -s "http://victoria-logs-single-server.tenant-root.svc.cluster.local:9428/select/logsql/query?query={test=\"true\"}"
```

## Prochaines étapes

### Instrumenter votre application

Voir les exemples dans `examples/observability/python-app/app.py` :

1. **Logs structurés** : JSON avec `traceid` et `spanid`
2. **Métriques** : Prometheus ou OpenTelemetry
3. **Traces** : OpenTelemetry avec endpoint `alloy.tenant-root.svc.cluster.local:4317`

### Ajouter des annotations de scraping

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: "/metrics"
```

### Configurer des alertes

Voir `docs/observability-cozystack.md` section "Alerting".

### Isolation par tenant

Pour isoler l'observabilité d'un tenant :

1. Déployer un Alloy dédié dans le namespace du tenant
2. Configurer le scraping seulement pour ce namespace
3. Créer des dashboards filtrés par `namespace="tenant-xxx"`

Voir `docs/observability-cozystack.md` section "Isolation par tenant".

## Troubleshooting

### Les logs n'apparaissent pas

```bash
# Vérifier qu'Alloy tourne partout
kubectl get pods -n tenant-root -l app.kubernetes.io/name=alloy -o wide

# Vérifier la config
kubectl get configmap alloy -n tenant-root -o yaml | grep -A 20 "loki.source.kubernetes"

# Tester la connexion
kubectl exec -n tenant-root daemonset/alloy -- \
  wget -qO- http://victoria-logs-single-server.tenant-root.svc.cluster.local:9428/health
```

### Les traces ne sont pas visibles

```bash
# Vérifier les logs d'Alloy
kubectl logs -n tenant-root daemonset/alloy | grep -i otlp

# Vérifier que Tempo reçoit les traces
kubectl logs -n tenant-root -l app.kubernetes.io/name=tempo | grep -i receive

# Vérifier l'endpoint OTLP
kubectl exec -n tenant-root daemonset/alloy -- netstat -ln | grep 4317
```

### Grafana ne voit pas les datasources

```bash
# Vérifier les ConfigMaps
kubectl get configmap -n tenant-root | grep grafana

# Redémarrer Grafana
kubectl rollout restart deployment/grafana -n tenant-root

# Ou configurer manuellement dans l'UI
```

## Documentation complète

- **Guide complet** : `docs/observability-cozystack.md`
- **Exemples d'applications** : `examples/observability/`
- **CozyStack docs** : `docs/cozystack.md`

## Support

- Issues GitHub : https://github.com/BordetNicolas/TalosGitOps/issues
- VictoriaMetrics docs : https://docs.victoriametrics.com/
- OpenTelemetry docs : https://opentelemetry.io/docs/
