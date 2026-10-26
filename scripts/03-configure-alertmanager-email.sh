#!/usr/bin/env bash
set -euo pipefail

: "${EMAIL_TO:?Set EMAIL_TO, for example alerts@example.com}"
: "${SMTP_FROM:?Set SMTP_FROM, for example monitoring@example.com}"
: "${SMTP_SMARTHOST:?Set SMTP_SMARTHOST, for example smtp.gmail.com:587}"
: "${SMTP_USERNAME:?Set SMTP_USERNAME}"

if [[ -z "${SMTP_PASSWORD:-}" ]]; then
  read -r -s -p "SMTP password or app password: " SMTP_PASSWORD
  echo
  export SMTP_PASSWORD
fi

export EMAIL_TO SMTP_FROM SMTP_SMARTHOST SMTP_USERNAME
export SMTP_REQUIRE_TLS="${SMTP_REQUIRE_TLS:-true}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

config_file="$(mktemp)"
trap 'rm -f "$config_file"' EXIT
chmod 600 "$config_file"

# json.dumps creates strings that are also valid YAML and safely handles symbols
# commonly found in SMTP passwords.
python3 >"$config_file" <<'PY'
import json
import os

q = lambda name: json.dumps(os.environ[name])
tls = os.environ["SMTP_REQUIRE_TLS"].lower()
if tls not in {"true", "false"}:
    raise SystemExit("SMTP_REQUIRE_TLS must be true or false")

print(f"""global:
  resolve_timeout: 5m
  smtp_smarthost: {q("SMTP_SMARTHOST")}
  smtp_from: {q("SMTP_FROM")}
  smtp_auth_username: {q("SMTP_USERNAME")}
  smtp_auth_identity: {q("SMTP_USERNAME")}
  smtp_auth_password: {q("SMTP_PASSWORD")}
  smtp_require_tls: {tls}

route:
  receiver: discard
  group_by: [alertname, namespace, pod]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - receiver: email
      matchers:
        - alertname=~"PodContainerRestarted|PodCrashLooping|PodCpuLimitOver80Percent"

receivers:
  - name: discard
  - name: email
    email_configs:
      - to: {q("EMAIL_TO")}
        send_resolved: true
""")
PY

kubectl -n monitoring create secret generic local-monitoring-alertmanager \
  --from-file=alertmanager.yaml="$config_file" \
  --dry-run=client -o yaml |
  kubectl apply -f -

echo "Alertmanager email configuration stored in secret/local-monitoring-alertmanager."
