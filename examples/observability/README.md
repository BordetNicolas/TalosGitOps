# Exemple d'application instrumentée

Application Flask de démonstration qui illustre les trois signaux sur cozy-01
(voir `docs/observability.md` pour l'architecture) :

| Signal | Comment |
|---|---|
| Logs | JSON sur stdout (avec `trace_id` / `span_id`), collectés par le fluent-bit de Cozystack |
| Métriques | `/metrics` (prometheus_client) scrapé par VMAgent via un `VMServiceScrape` |
| Traces | OpenTelemetry, OTLP gRPC direct vers `tempo.tenant-root.svc:4317` |

```
examples/observability/
├── python-app/
│   ├── app.py              # application Flask
│   ├── Dockerfile
│   ├── requirements.txt
│   └── deployment.yaml     # Namespace, Deployment, Service, VMServiceScrape, Ingress
└── dashboards/
    └── demo-app-dashboard.json   # dashboard Grafana (variables de datasource)
```

## Déployer

La stack (Tempo) doit être déployée : `make CLUSTER=cozy-01 test-observability`.

```bash
cd examples/observability/python-app
docker build -t <registry>/python-demo-app:latest . && docker push <registry>/python-demo-app:latest
# adapter `image:` (et l'hôte de l'Ingress) dans deployment.yaml
export KUBECONFIG=../../../clusters/cozy-01/kubeconfig
kubectl apply -f deployment.yaml
```

Endpoints de l'application : `/health`, `/metrics`, `/api/users`, `/api/slow`, `/api/error`
(500 aléatoires), `/api/chain` (trace sur plusieurs spans).

```bash
kubectl -n demo-app port-forward svc/python-demo-app 8080:80 &
for i in $(seq 50); do curl -s localhost:8080/api/users >/dev/null; curl -s localhost:8080/api/error >/dev/null; done
```

## Explorer dans Grafana

- **Métriques** : datasource `vm-shortterm`, par ex. `sum(rate(http_requests_total{namespace="demo-app"}[5m])) by (endpoint)`.
- **Logs** : datasource `vlogs-generic`, requête LogsQL `{kubernetes_namespace_name="demo-app"} level:i("error")`.
- **Traces** : datasource `tempo` (Explore > Search, `service.name = python-demo-app`).

Importer `dashboards/demo-app-dashboard.json` (Dashboards > Import) : les variables
`Metrics`, `Traces` et `Logs` sélectionnent les datasources ci-dessus. Les panneaux « logs » et
« service graph » n'ont pas été testés dans l'UI.

## Instrumenter une autre application

Trois choses à faire (voir `docs/observability.md`) : logger sur stdout, exposer `/metrics` avec un
`VMServiceScrape`, exporter les traces en OTLP vers Tempo. Variable standard :
`OTEL_EXPORTER_OTLP_ENDPOINT=tempo.tenant-root.svc:4317` (gRPC) ou `http://tempo.tenant-root.svc:4318` (HTTP).
