#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="local/mock-observable-app:1.0.0"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

sudo docker build --tag "${IMAGE}" "${ROOT_DIR}/app"

image_archive="$(mktemp --suffix=.tar)"
trap 'rm -f "$image_archive"' EXIT
sudo docker save "${IMAGE}" --output "$image_archive"
sudo k3s ctr images import "$image_archive"

kubectl apply -f "${ROOT_DIR}/k8s/mock-app.yaml"
kubectl apply -f "${ROOT_DIR}/k8s/servicemonitor.yaml"
kubectl -n demo rollout status deployment/mock-app --timeout=180s

kubectl -n demo get deployment,pod,service,servicemonitor
echo
echo "The image was imported into this node's k3s containerd image store."
echo "For a multi-node cluster, import the archive on every schedulable node or use a registry."
