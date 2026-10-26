#!/usr/bin/env bash
set -euo pipefail

command -v curl >/dev/null || {
  echo "curl is required; run scripts/01-install-host-tools.sh first." >&2
  exit 1
}

# Pin with INSTALL_K3S_VERSION=vX.Y.Z+k3s1 if your environment requires it.
curl -sfL https://get.k3s.io |
  INSTALL_K3S_VERSION="${INSTALL_K3S_VERSION:-}" sh -s - \
    --write-kubeconfig-mode 0644 \
    --disable traefik

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl get nodes -o wide
kubectl get pods --all-namespaces

cat <<'EOF'

k3s is ready. Add this to your shell profile if desired:
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
EOF
