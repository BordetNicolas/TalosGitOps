#!/usr/bin/env bash
# Vérifie la stack d'observabilité de cozy-01 : Tempo (ce dépôt) + logs/métriques Cozystack.
# Usage: KUBECONFIG=clusters/cozy-01/kubeconfig scripts/test-observability.sh

set -uo pipefail

NS="${NAMESPACE:-tenant-root}"
fail=0
PF_PIDS=()
trap 'kill "${PF_PIDS[@]}" 2>/dev/null' EXIT

ok() { echo "  ok   $1"; }
ko() { echo "  FAIL $1"; fail=1; }
check() { local msg="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$msg"; else ko "$msg"; fi; }

portforward() { # <svc> <local> <remote>
  kubectl -n "$NS" port-forward "svc/$1" "$2:$3" >/dev/null 2>&1 &
  PF_PIDS+=($!)
}

echo "Pods"
check "tempo prêt" kubectl -n "$NS" wait --for=condition=ready pod -l app.kubernetes.io/name=tempo --timeout=60s
check "vlinsert-generic prêt" kubectl -n "$NS" wait --for=condition=ready pod -l app.kubernetes.io/name=vlinsert --timeout=60s
check "fluent-bit prêt" kubectl -n cozy-monitoring rollout status ds/monitoring-agents-fluent-bit --timeout=60s

echo "Datasources Grafana"
for ds in vlogs-generic vm-shortterm tempo; do
  check "GrafanaDatasource $ds" kubectl -n "$NS" get grafanadatasource "$ds"
done

portforward tempo 13200 3200
portforward vlselect-generic 19471 9471
portforward vmselect-shortterm 18481 8481
sleep 4

echo "Endpoints"
check "tempo /ready" curl -fsS -m 5 http://localhost:13200/ready
check "vlselect-generic répond" curl -fsS -m 5 http://localhost:19471/select/logsql/query -d 'query=*' -d 'limit=1'
check "vmselect-shortterm répond" curl -fsS -m 5 "http://localhost:18481/select/0/prometheus/api/v1/query?query=up"

echo "Données"
n=$(curl -fsS -m 10 http://localhost:19471/select/logsql/hits -d 'query=_time:15m' -d 'start=15m' -d 'step=15m' 2>/dev/null |
  python3 -c "import sys,json; print(sum(g['total'] for g in json.load(sys.stdin)['hits']))" 2>/dev/null || echo 0)
if [ "${n:-0}" -gt 0 ]; then ok "logs reçus ces 15 dernières minutes ($n)"; else ko "aucun log reçu ces 15 dernières minutes"; fi

exit $fail
