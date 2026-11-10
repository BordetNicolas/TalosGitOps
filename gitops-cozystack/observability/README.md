# Observability Stack pour CozyStack

Stack d'observabilité native CozyStack avec VictoriaMetrics, VictoriaLogs, Tempo et Alloy.

## Structure

```
observability/
├── README.md                      # Ce fichier
├── victoria-logs.yaml            # Logs centralisés (compatible Loki)
├── tempo.yaml                    # Traces distribuées (OpenTelemetry)
├── alloy.yaml                    # Collecteur unifié (logs + traces + métriques OTEL)
└── grafana-datasources.yaml      # Datasources additionnelles pour Grafana
```

## Installation

Cette stack est déployée automatiquement via l'application ArgoCD `observability-stack` (voir `apps/30-observability-stack.yaml`).

```bash
# Vérifier le déploiement
kubectl get applications -n argocd observability-stack
kubectl get pods -n tenant-root | grep -E 'victoria-logs|tempo|alloy'

# Tester la stack
./scripts/test-observability.sh
```

## Composants

| Composant | Version | Stockage | Rétention |
|---|---|---|---|
| VictoriaLogs | 0.7.6 | LINSTOR 50Gi | 30 jours |
| Tempo | 1.24.4 | LINSTOR 20Gi | 7 jours |
| Alloy | 1.8.1 | - | - |

## Configuration Alloy

Alloy collecte :

1. **Logs** : Tous les pods via `loki.source.kubernetes`, envoyés vers VictoriaLogs
2. **Traces** : OTLP (gRPC:4317, HTTP:4318), envoyées vers Tempo
3. **Métriques OTEL** : Converties en Prometheus et envoyées vers VictoriaMetrics
4. **Métriques Prometheus** : Scraping des services annotés `prometheus.io/scrape: "true"`

## Intégration Grafana

Le Grafana de CozyStack doit charger les datasources depuis `grafana-datasources.yaml`.

**Configuration manuelle** (si les ConfigMaps ne sont pas auto-chargées) :

```bash
kubectl port-forward -n tenant-root svc/grafana 3000:80

# Accéder à http://localhost:3000
# Configuration > Data sources > Add data source
# Ajouter VictoriaLogs (type: Loki) et Tempo selon grafana-datasources.yaml
```

## Utilisation

Voir la documentation complète : `docs/observability-cozystack.md`

Exemples d'applications instrumentées : `examples/observability/`

## Troubleshooting

```bash
# Logs des composants
kubectl logs -n tenant-root -l app.kubernetes.io/name=alloy --tail=100
kubectl logs -n tenant-root -l app.kubernetes.io/name=victoria-logs-single --tail=100
kubectl logs -n tenant-root -l app.kubernetes.io/name=tempo --tail=100

# Tester l'ingestion
# Logs
curl -X POST http://victoria-logs-single-server.tenant-root.svc.cluster.local:9428/insert/loki/api/v1/push \
  -H "Content-Type: application/json" \
  -d '{"streams":[{"stream":{"test":"true"},"values":[["'$(date +%s%N)'","test"]]}]}'

# Traces (via Alloy)
# Envoyer une trace OTLP vers alloy.tenant-root.svc.cluster.local:4317

# Métriques (via Alloy)
# Annoter un service avec prometheus.io/scrape: "true"
```

## Évolution

Pour passer en mode distribué (haute disponibilité) :

1. VictoriaMetrics : remplacer `vmsingle` par `vmcluster`
2. VictoriaLogs : cluster mode (quand disponible dans la chart)
3. Tempo : passer de `tempo` à `tempo-distributed`

Voir `docs/observability-cozystack.md` pour les détails.
