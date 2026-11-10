#!/usr/bin/env bash
# Initialise une application avec observabilité (annotations, config OTLP)

set -euo pipefail

APP_NAME="${1:-}"
NAMESPACE="${2:-default}"

if [ -z "$APP_NAME" ]; then
  echo "Usage: $0 <app-name> [namespace]"
  echo "Example: $0 my-api production"
  exit 1
fi

echo "🚀 Initializing observability for app: $APP_NAME in namespace: $NAMESPACE"
echo ""

# Créer le namespace s'il n'existe pas
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "📦 Creating namespace: $NAMESPACE"
  kubectl create namespace "$NAMESPACE"
else
  echo "✓ Namespace $NAMESPACE already exists"
fi

# Créer un ConfigMap avec la config OTLP
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${APP_NAME}-otel-config
  namespace: $NAMESPACE
data:
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://alloy.tenant-root.svc.cluster.local:4318"
  OTEL_EXPORTER_OTLP_PROTOCOL: "http/protobuf"
  OTEL_SERVICE_NAME: "$APP_NAME"
  OTEL_RESOURCE_ATTRIBUTES: "service.namespace=$NAMESPACE,deployment.environment=production"
  OTEL_TRACES_EXPORTER: "otlp"
  OTEL_METRICS_EXPORTER: "otlp"
  OTEL_LOGS_EXPORTER: "otlp"
EOF

echo "✓ Created ConfigMap: ${APP_NAME}-otel-config"

# Créer un exemple de Deployment avec observabilité
cat > "/tmp/${APP_NAME}-deployment-example.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: APP_NAME
  namespace: NAMESPACE
  labels:
    app: APP_NAME
spec:
  replicas: 2
  selector:
    matchLabels:
      app: APP_NAME
  template:
    metadata:
      labels:
        app: APP_NAME
      annotations:
        # Pour auto-instrumentation OpenTelemetry (si operator installé)
        instrumentation.opentelemetry.io/inject: "true"
    spec:
      containers:
        - name: app
          image: YOUR_IMAGE:latest
          ports:
            - name: http
              containerPort: 8080
          # Injecter la config OTLP via ConfigMap
          envFrom:
            - configMapRef:
                name: APP_NAME-otel-config
          # Variables supplémentaires
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 256Mi
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: APP_NAME
  namespace: NAMESPACE
  labels:
    app: APP_NAME
  annotations:
    # Annotations pour Prometheus scraping
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: "/metrics"
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
      name: http
  selector:
    app: APP_NAME
EOF

# Remplacer les placeholders
sed -i "s/APP_NAME/$APP_NAME/g" "/tmp/${APP_NAME}-deployment-example.yaml"
sed -i "s/NAMESPACE/$NAMESPACE/g" "/tmp/${APP_NAME}-deployment-example.yaml"

echo ""
echo "✓ Created example Deployment: /tmp/${APP_NAME}-deployment-example.yaml"
echo ""

# Créer un snippet de code d'instrumentation
cat > "/tmp/${APP_NAME}-instrumentation-snippet.txt" <<'EOF'
# ==============================================================================
# Code snippet for instrumenting your application
# ==============================================================================

# Python (Flask/FastAPI)
# ----------------------
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.instrumentation.flask import FlaskInstrumentor  # or fastapi

# Setup (automatically uses OTEL_* env vars from ConfigMap)
provider = TracerProvider()
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(provider)

# Auto-instrument Flask
FlaskInstrumentor().instrument_app(app)

# Manual tracing
tracer = trace.get_tracer(__name__)
with tracer.start_as_current_span("my_operation"):
    # Your code here
    pass

# Go
# --
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
    "go.opentelemetry.io/otel/sdk/trace"
)

// Setup (uses OTEL_EXPORTER_OTLP_ENDPOINT from env)
exporter, _ := otlptracehttp.New(context.Background())
tp := trace.NewTracerProvider(trace.WithBatcher(exporter))
otel.SetTracerProvider(tp)

// Use
tracer := otel.Tracer("my-app")
ctx, span := tracer.Start(ctx, "my_operation")
defer span.End()

# Node.js
# -------
const { NodeTracerProvider } = require('@opentelemetry/sdk-trace-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');

// Setup (uses OTEL_EXPORTER_OTLP_ENDPOINT from process.env)
const provider = new NodeTracerProvider();
provider.addSpanProcessor(
  new BatchSpanProcessor(new OTLPTraceExporter())
);
provider.register();

# Logs structurés (JSON with trace context)
# ------------------------------------------
# Python
import logging
import json

logger = logging.getLogger(__name__)

span = trace.get_current_span()
trace_id = format(span.get_span_context().trace_id, '032x')

logger.info(json.dumps({
    "message": "User logged in",
    "user_id": "123",
    "traceid": trace_id,
    "level": "info"
}))

# Prometheus metrics
# ------------------
# Python
from prometheus_client import Counter, Histogram

request_count = Counter('http_requests_total', 'Total requests', ['method', 'endpoint'])
request_duration = Histogram('http_request_duration_seconds', 'Request duration')

request_count.labels(method='GET', endpoint='/api/users').inc()

# ==============================================================================
# Service annotations for Prometheus scraping
# ==============================================================================

# Add to your Service:
apiVersion: v1
kind: Service
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: "/metrics"

# ==============================================================================
# Testing
# ==============================================================================

# Test OTLP endpoint connectivity
kubectl run test-otlp --rm -i --restart=Never --image=curlimages/curl -- \
  curl -v http://alloy.tenant-root.svc.cluster.local:4318/v1/traces

# View logs in VictoriaLogs
kubectl port-forward -n tenant-root svc/victoria-logs-single-server 9428:9428
curl 'http://localhost:9428/select/logsql/query?query={namespace="NAMESPACE"}'

# View traces in Tempo (via Grafana)
kubectl port-forward -n tenant-root svc/grafana 3000:80
# Open http://localhost:3000 → Explore → Tempo

EOF

sed -i "s/NAMESPACE/$NAMESPACE/g" "/tmp/${APP_NAME}-instrumentation-snippet.txt"

echo "✓ Created instrumentation guide: /tmp/${APP_NAME}-instrumentation-snippet.txt"
echo ""

# Résumé
cat <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✅ Created ConfigMap: ${APP_NAME}-otel-config in namespace $NAMESPACE
   - Contains OTEL_* environment variables
   - Ready to be injected in your Deployment

📄 Files created:
   1. /tmp/${APP_NAME}-deployment-example.yaml
      → Example Deployment + Service with observability annotations
   
   2. /tmp/${APP_NAME}-instrumentation-snippet.txt
      → Code snippets for Python/Go/Node.js instrumentation

🔧 Next steps:

1. Review and customize the Deployment example:
   cat /tmp/${APP_NAME}-deployment-example.yaml

2. Instrument your application code (see snippet file):
   cat /tmp/${APP_NAME}-instrumentation-snippet.txt

3. Deploy your application:
   kubectl apply -f /tmp/${APP_NAME}-deployment-example.yaml

4. Generate traffic and view in Grafana:
   kubectl port-forward -n tenant-root svc/grafana 3000:80
   # Open http://localhost:3000 → Explore

📚 Documentation:
   - Full guide: docs/observability-cozystack.md
   - Quick start: docs/QUICKSTART-OBSERVABILITY.md
   - Examples: examples/observability/

🔗 OTLP Endpoints:
   - gRPC: alloy.tenant-root.svc.cluster.local:4317
   - HTTP: alloy.tenant-root.svc.cluster.local:4318

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
