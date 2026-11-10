#!/usr/bin/env bash
# Test de la stack d'observabilité CozyStack

set -euo pipefail

NAMESPACE="${NAMESPACE:-tenant-root}"
DEMO_NS="${DEMO_NS:-demo-app}"

echo "🔍 Testing Observability Stack on CozyStack"
echo "============================================"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

check() {
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓${NC} $1"
  else
    echo -e "${RED}✗${NC} $1"
    return 1
  fi
}

# 1. Vérifier que les pods sont running
echo ""
echo "1️⃣  Checking pods status..."
kubectl get pods -n "$NAMESPACE" | grep -E 'victoria-logs|tempo|alloy' || true

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=alloy -n "$NAMESPACE" --timeout=60s 2>/dev/null
check "Alloy pods are ready"

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=victoria-logs-single -n "$NAMESPACE" --timeout=60s 2>/dev/null
check "VictoriaLogs pod is ready"

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=tempo -n "$NAMESPACE" --timeout=60s 2>/dev/null
check "Tempo pod is ready"

# 2. Vérifier les endpoints
echo ""
echo "2️⃣  Checking service endpoints..."

# VictoriaLogs health
VLOGS_POD=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=victoria-logs-single -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "$NAMESPACE" "$VLOGS_POD" -- wget -qO- http://localhost:9428/health | grep -q "OK"
check "VictoriaLogs health endpoint"

# Tempo ready
TEMPO_POD=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=tempo -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "$NAMESPACE" "$TEMPO_POD" -- wget -qO- http://localhost:3200/ready | grep -q "ready"
check "Tempo ready endpoint"

# 3. Tester l'ingestion de logs
echo ""
echo "3️⃣  Testing log ingestion..."

TEST_LOG_MSG="test-observability-$(date +%s)"
kubectl run test-log-sender --rm -i --restart=Never --image=curlimages/curl -n "$NAMESPACE" -- \
  curl -X POST http://victoria-logs-single-server."$NAMESPACE".svc.cluster.local:9428/insert/loki/api/v1/push \
  -H "Content-Type: application/json" \
  -d "{\"streams\":[{\"stream\":{\"test\":\"true\",\"source\":\"script\"},\"values\":[[\"$(date +%s%N)\",\"$TEST_LOG_MSG\"]]}]}" \
  -s -w "%{http_code}" -o /dev/null | grep -q "200"
check "Log ingestion to VictoriaLogs"

sleep 2

# Requêter le log
kubectl run test-log-query --rm -i --restart=Never --image=curlimages/curl -n "$NAMESPACE" -- \
  curl -s "http://victoria-logs-single-server."$NAMESPACE".svc.cluster.local:9428/select/logsql/query?query={test=\"true\"}" \
  | grep -q "$TEST_LOG_MSG"
check "Log query from VictoriaLogs"

# 4. Tester les métriques
echo ""
echo "4️⃣  Testing metrics..."

# Vérifier que VictoriaMetrics est accessible (déjà installé par CozyStack)
VM_SVC="vmsingle-vm"
if kubectl get svc -n "$NAMESPACE" "$VM_SVC" >/dev/null 2>&1; then
  VM_POD=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=victoria-metrics-single -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$VM_POD" ]; then
    kubectl exec -n "$NAMESPACE" "$VM_POD" -- wget -qO- "http://localhost:8429/api/v1/query?query=up" | grep -q "success"
    check "VictoriaMetrics query endpoint"
  else
    echo -e "${YELLOW}⊘${NC} VictoriaMetrics not found (expected from CozyStack)"
  fi
else
  echo -e "${YELLOW}⊘${NC} VictoriaMetrics service not found"
fi

# 5. Tester les traces
echo ""
echo "5️⃣  Testing traces..."

# Vérifier que Tempo peut recevoir des traces
kubectl exec -n "$NAMESPACE" "$TEMPO_POD" -- wget -qO- http://localhost:3200/api/search?limit=1 >/dev/null
check "Tempo search API"

# 6. Vérifier Alloy endpoints (OTLP)
echo ""
echo "6️⃣  Checking Alloy OTLP endpoints..."

ALLOY_POD=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=alloy -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "$NAMESPACE" "$ALLOY_POD" -- wget -qO- http://localhost:12345/metrics 2>/dev/null | grep -q "alloy"
check "Alloy metrics endpoint"

# Vérifier que les ports OTLP sont en écoute
kubectl exec -n "$NAMESPACE" "$ALLOY_POD" -- sh -c "netstat -ln | grep -E ':(4317|4318)'" >/dev/null 2>&1
check "Alloy OTLP ports (4317, 4318)"

# 7. Test de l'application de démo (si déployée)
echo ""
echo "7️⃣  Testing demo app (if deployed)..."

if kubectl get namespace "$DEMO_NS" >/dev/null 2>&1; then
  if kubectl get deployment python-demo-app -n "$DEMO_NS" >/dev/null 2>&1; then
    kubectl wait --for=condition=available deployment/python-demo-app -n "$DEMO_NS" --timeout=60s 2>/dev/null
    check "Demo app is available"
    
    # Générer du trafic
    echo "   Generating test traffic..."
    for i in {1..10}; do
      kubectl run test-traffic-$i --rm -i --restart=Never --image=curlimages/curl -n "$DEMO_NS" -- \
        curl -s http://python-demo-app."$DEMO_NS".svc.cluster.local/ >/dev/null &
    done
    wait
    check "Generated test traffic to demo app"
    
    sleep 5
    
    # Vérifier que les logs de l'app sont collectés
    kubectl run test-demo-logs --rm -i --restart=Never --image=curlimages/curl -n "$NAMESPACE" -- \
      curl -s "http://victoria-logs-single-server."$NAMESPACE".svc.cluster.local:9428/select/logsql/query?query={namespace=\"$DEMO_NS\"}" \
      | grep -q "demo-app"
    check "Demo app logs in VictoriaLogs"
    
  else
    echo -e "${YELLOW}⊘${NC} Demo app not deployed (skip)"
  fi
else
  echo -e "${YELLOW}⊘${NC} Demo namespace not found (skip)"
fi

# 8. Résumé des endpoints
echo ""
echo "8️⃣  Endpoints summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

cat <<EOF
📊 VictoriaMetrics:  http://vmsingle-vm.$NAMESPACE.svc.cluster.local:8429
📝 VictoriaLogs:     http://victoria-logs-single-server.$NAMESPACE.svc.cluster.local:9428
🔍 Tempo:            http://tempo.$NAMESPACE.svc.cluster.local:3200
📡 Alloy OTLP gRPC:  alloy.$NAMESPACE.svc.cluster.local:4317
📡 Alloy OTLP HTTP:  alloy.$NAMESPACE.svc.cluster.local:4318

Port-forward commands:
----------------------
kubectl port-forward -n $NAMESPACE svc/vmsingle-vm 8429:8429
kubectl port-forward -n $NAMESPACE svc/victoria-logs-single-server 9428:9428
kubectl port-forward -n $NAMESPACE svc/tempo 3200:3200
kubectl port-forward -n $NAMESPACE svc/grafana 3000:80
EOF

echo ""
echo -e "${GREEN}✓${NC} Observability stack is functional!"
echo ""
echo "Next steps:"
echo "  1. Access Grafana: kubectl port-forward -n $NAMESPACE svc/grafana 3000:80"
echo "  2. Deploy demo app: kubectl apply -f examples/observability/python-app/deployment.yaml"
echo "  3. View documentation: docs/observability-cozystack.md"
