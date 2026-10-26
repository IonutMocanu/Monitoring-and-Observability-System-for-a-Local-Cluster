#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

kubectl apply -f "${ROOT_DIR}/k8s/namespaces.yaml"

if ! kubectl -n monitoring get secret local-monitoring-alertmanager >/dev/null 2>&1; then
  cat >&2 <<'EOF'
The Alertmanager secret does not exist.
Configure SMTP and run scripts/03-configure-alertmanager-email.sh first.
EOF
  exit 1
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm_args=(
  upgrade --install monitoring prometheus-community/kube-prometheus-stack
  --namespace monitoring
  --values "${ROOT_DIR}/monitoring/kube-prometheus-stack-values.yaml"
  --wait
  --timeout 15m
  --atomic
)
if [[ "${ENABLE_PERSISTENCE:-false}" == "true" ]]; then
  helm_args+=(--values "${ROOT_DIR}/monitoring/persistence-values.yaml")
fi
if [[ -n "${CHART_VERSION:-}" ]]; then
  helm_args+=(--version "${CHART_VERSION}")
fi
helm "${helm_args[@]}"

kubectl apply -f "${ROOT_DIR}/k8s/prometheus-rules.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/grafana-dashboard.yaml"

kubectl -n monitoring wait --for=condition=Available deployment --all --timeout=300s
kubectl -n monitoring get pods
kubectl -n monitoring get svc
kubectl -n monitoring get prometheusrule local-cluster-alerts
