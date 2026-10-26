#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "Run this script as your normal sudo-capable user, not as root." >&2
  exit 1
fi

sudo apt-get update
sudo apt-get install -y ca-certificates curl gpg python3
sudo install -m 0755 -d /etc/apt/keyrings

# Docker's official Ubuntu repository (works on amd64 and arm64).
sudo rm -f /etc/apt/keyrings/docker.asc
curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
  sudo tee /etc/apt/keyrings/docker.asc >/dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
ARCH="$(dpkg --print-architecture)"
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" |
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

# Helm's official Debian/Ubuntu repository.
curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey |
  gpg --dearmor |
  sudo tee /etc/apt/keyrings/helm.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" |
  sudo tee /etc/apt/sources.list.d/helm-stable-debian.list >/dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin helm
sudo systemctl enable --now docker

echo "Installed versions:"
sudo docker version --format 'Docker {{.Server.Version}}'
helm version --short
