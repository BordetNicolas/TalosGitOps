# Fichiers de la stack d'observabilité CozyStack

Récapitulatif de tous les fichiers créés pour la stack d'observabilité.

## 📂 Structure

```
TalosGitOps/
│
├── gitops-cozystack/
│   ├── apps/
│   │   └── 30-observability-stack.yaml       # ArgoCD Application principale
│   │
│   └── observability/
│       ├── README.md                          # Documentation du dossier
│       ├── victoria-logs.yaml                 # Logs centralisés (Loki-compatible)
│       ├── tempo.yaml                         # Traces distribuées (OpenTelemetry)
│       ├── alloy.yaml                         # Collecteur unifié (logs+traces+métriques)
│       └── grafana-datasources.yaml           # Datasources pour Grafana
│
├── docs/
│   ├── observability-cozystack.md             # 📘 Documentation complète
│   ├── QUICKSTART-OBSERVABILITY.md            # 🚀 Guide de démarrage rapide
│   └── observability-files.md                 # 📋 Ce fichier
│
├── examples/observability/
│   ├── README.md                              # Guide des exemples
│   │
│   ├── python-app/                            # Application Python instrumentée
│   │   ├── app.py                             # Code avec métriques + logs + traces
│   │   ├── requirements.txt
│   │   ├── Dockerfile
│   │   └── deployment.yaml                    # Kubernetes manifests
│   │
│   └── dashboards/
│       └── demo-app-dashboard.json            # Dashboard Grafana pré-configuré
│
└── scripts/
    ├── test-observability.sh                  # ✅ Script de test automatisé
    └── init-app-observability.sh              # 🔧 Init rapide pour nouvelle app
```

## 📄 Description des fichiers

### Configuration ArgoCD

| Fichier | Rôle |
|---------|------|
| `gitops-cozystack/apps/30-observability-stack.yaml` | Application ArgoCD qui déploie toute la stack (sync-wave 5) |
| `gitops-cozystack/observability/victoria-logs.yaml` | Déploie VictoriaLogs (logs) avec 50Gi LINSTOR, rétention 30j |
| `gitops-cozystack/observability/tempo.yaml` | Déploie Tempo (traces) avec 20Gi LINSTOR, rétention 7j |
| `gitops-cozystack/observability/alloy.yaml` | Déploie Alloy en DaemonSet, config complète (logs+traces+métriques) |
| `gitops-cozystack/observability/grafana-datasources.yaml` | ConfigMaps pour ajouter VictoriaLogs et Tempo dans Grafana |

### Documentation

| Fichier | Contenu | Audience |
|---------|---------|----------|
| `docs/observability-cozystack.md` | Guide complet : architecture, installation, utilisation, requêtes, dashboards, alertes, troubleshooting, évolution | Tous |
| `docs/QUICKSTART-OBSERVABILITY.md` | Démarrage en 10 min : déployer, tester, explorer dans Grafana | Débutants |
| `docs/observability-files.md` | Liste des fichiers créés (ce fichier) | Référence |
| `gitops-cozystack/observability/README.md` | Documentation du dossier observability | Mainteneurs |
| `examples/observability/README.md` | Guide des exemples d'applications | Développeurs |

### Exemples d'applications

| Fichier | Description |
|---------|-------------|
| `examples/observability/python-app/app.py` | Application Flask complète avec logs JSON structurés, métriques Prometheus + OTEL, traces OpenTelemetry, auto-instrumentation |
| `examples/observability/python-app/requirements.txt` | Dépendances Python (Flask, prometheus-client, OpenTelemetry SDK) |
| `examples/observability/python-app/Dockerfile` | Image Docker pour l'app de démo |
| `examples/observability/python-app/deployment.yaml` | Manifests K8s : Namespace, Deployment, Service (avec annotations Prometheus), Ingress |
| `examples/observability/dashboards/demo-app-dashboard.json` | Dashboard Grafana avec RED metrics, logs, traces, service graph |

### Scripts

| Fichier | Usage | Description |
|---------|-------|-------------|
| `scripts/test-observability.sh` | `make CLUSTER=cozy-01 test-observability` | Teste tous les composants : VictoriaLogs, Tempo, Alloy, ingestion logs/traces |
| `scripts/init-app-observability.sh` | `./scripts/init-app-observability.sh my-app prod` | Génère ConfigMap OTLP, Deployment example, snippets d'instrumentation |

### Modifications

| Fichier | Changement |
|---------|-----------|
| `Makefile` | Ajout de la cible `test-observability` |
| `README.md` | Ajout d'une note sur la stack d'observabilité avec liens vers les docs |

## 🚀 Utilisation rapide

### Déployer la stack

```bash
cd /home/napadelice/GitHub/TalosGitOps
make CLUSTER=cozy-01 gitops-render
git add . && git commit -m "feat: add observability stack" && git push
```

### Tester

```bash
make CLUSTER=cozy-01 test-observability
```

### Déployer l'app de démo

```bash
cd examples/observability/python-app
docker build -t python-demo-app:latest .
kubectl apply -f deployment.yaml
```

### Explorer dans Grafana

```bash
kubectl port-forward -n tenant-root svc/grafana 3000:80
# http://localhost:3000
```

### Initialiser une nouvelle app

```bash
./scripts/init-app-observability.sh my-api production
# Crée ConfigMap + templates + snippets de code
```

## 📊 Composants déployés

| Composant | Version | Chart | Namespace | Stockage |
|-----------|---------|-------|-----------|----------|
| VictoriaLogs | 0.7.6 | victoria-logs-single | tenant-root | LINSTOR 50Gi |
| Tempo | 1.24.4 | tempo | tenant-root | LINSTOR 20Gi |
| Alloy | 1.8.1 | alloy | tenant-root | - (DaemonSet) |
| VictoriaMetrics | (CozyStack) | victoria-metrics-single | tenant-root | (déjà installé) |
| Grafana | (CozyStack) | grafana | tenant-root | (déjà installé) |

## 🔗 Endpoints

| Service | URL interne | Port |
|---------|-------------|------|
| VictoriaLogs | `victoria-logs-single-server.tenant-root.svc.cluster.local` | 9428 |
| Tempo | `tempo.tenant-root.svc.cluster.local` | 3200 |
| Alloy OTLP gRPC | `alloy.tenant-root.svc.cluster.local` | 4317 |
| Alloy OTLP HTTP | `alloy.tenant-root.svc.cluster.local` | 4318 |
| VictoriaMetrics | `vmsingle-vm.tenant-root.svc.cluster.local` | 8429 |
| Grafana | `grafana.tenant-root.svc.cluster.local` | 80 |

## 📚 Ressources

### Documentation externe

- [VictoriaMetrics](https://docs.victoriametrics.com/)
- [VictoriaLogs](https://docs.victoriametrics.com/victorialogs/)
- [Grafana Tempo](https://grafana.com/docs/tempo/latest/)
- [Grafana Alloy](https://grafana.com/docs/alloy/latest/)
- [OpenTelemetry](https://opentelemetry.io/docs/)
- [CozyStack](https://cozystack.io/docs/)

### Liens internes

- Architecture CozyStack : `docs/cozystack.md`
- Guide GitOps : `README.md`
- Makefile targets : `make help`

## 🆘 Support

### Problèmes courants

Voir section "Troubleshooting" dans :
- `docs/observability-cozystack.md`
- `docs/QUICKSTART-OBSERVABILITY.md`

### Logs de débogage

```bash
# Stack components
kubectl logs -n tenant-root -l app.kubernetes.io/name=alloy --tail=100
kubectl logs -n tenant-root -l app.kubernetes.io/name=victoria-logs-single --tail=100
kubectl logs -n tenant-root -l app.kubernetes.io/name=tempo --tail=100

# Test ingestion
./scripts/test-observability.sh
```

### Issues

GitHub Issues : https://github.com/BordetNicolas/TalosGitOps/issues

## 🔄 Prochaines étapes

1. ✅ Stack de base déployée (VictoriaLogs, Tempo, Alloy)
2. 📝 TODO : Auto-instrumentation avec OpenTelemetry Operator
3. 📝 TODO : Exemple Go + Node.js
4. 📝 TODO : Dashboards supplémentaires (Kubernetes cluster overview, Tenant isolation)
5. 📝 TODO : Alertes pré-configurées (AlertManager)
6. 📝 TODO : Mode distribué haute disponibilité

## ✅ Checklist de déploiement

- [ ] Stack déployée : `kubectl get applications -n argocd observability-stack`
- [ ] Pods running : `kubectl get pods -n tenant-root | grep -E 'victoria-logs|tempo|alloy'`
- [ ] Tests passent : `make CLUSTER=cozy-01 test-observability`
- [ ] Grafana accessible : `kubectl port-forward -n tenant-root svc/grafana 3000:80`
- [ ] Datasources configurées dans Grafana
- [ ] App de démo déployée et visible dans Grafana
- [ ] Documentation lue : `docs/QUICKSTART-OBSERVABILITY.md`

---

**Dernière mise à jour** : $(date +%Y-%m-%d)
**Version** : 1.0.0
