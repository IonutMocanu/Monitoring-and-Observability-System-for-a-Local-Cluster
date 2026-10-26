# Local Kubernetes Monitoring and Observability

This project builds a small, production-shaped observability lab on one Ubuntu
machine or Raspberry Pi 5:

```text
Docker build -> k3s/containerd -> mock application
                                  | /metrics
                                  v
                    Prometheus + kube-state-metrics
                         |                 |
                         v                 v
                      Grafana         Alertmanager -> email
```

The stack uses k3s, the `kube-prometheus-stack` Helm chart, Prometheus, Grafana,
Alertmanager, node-exporter, and kube-state-metrics. The sample Python service
exports Prometheus metrics and has explicit error, CPU-load, and crash test
endpoints.

## Repository layout

| Path | Purpose |
| --- | --- |
| `app/` | Python metrics application and Dockerfile |
| `k8s/mock-app.yaml` | Deployment, resource limits, probes, and Service |
| `k8s/servicemonitor.yaml` | Prometheus discovery for `/metrics` |
| `k8s/prometheus-rules.yaml` | restart, crash-loop, and CPU alerts |
| `k8s/grafana-dashboard.yaml` | provisioned CPU, memory, restart, and error dashboard |
| `monitoring/kube-prometheus-stack-values.yaml` | lightweight Helm configuration |
| `monitoring/persistence-values.yaml` | optional k3s `local-path` persistence |
| `scripts/` | chronological installation and deployment scripts |

## 0. Requirements and sizing

- Ubuntu 22.04/24.04 on `amd64` or 64-bit Raspberry Pi OS/Ubuntu on `arm64`
- A sudo-capable user
- 4 GB RAM minimum; 8 GB is more comfortable
- Approximately 15 GB free disk without persistence, or 30 GB with it
- Outbound HTTPS for package, container, and Helm chart downloads
- An SMTP account. Gmail requires 2FA plus an app password; a normal account
  password normally will not work.

The provided configuration is for a local single-node lab. It disables Traefik
and uses `kubectl port-forward`, so Grafana, Prometheus, and Alertmanager are
not exposed to the LAN.

Clone the repository and enter it:

```bash
git clone https://github.com/IonutMocanu/Monitoring-and-Observability-System-for-a-Local-Cluster.git
cd Monitoring-and-Observability-System-for-a-Local-Cluster
chmod +x scripts/*.sh
```

## 1. Install Docker, Helm, and host tools

The first script adds the official Docker and Helm apt repositories. Review it,
then run:

```bash
./scripts/01-install-host-tools.sh
```

Verify:

```bash
sudo docker run --rm hello-world
helm version --short
python3 --version
```

Docker and k3s deliberately use different container runtimes. Docker builds the
image; a later script imports it into k3s's containerd store.

## 2. Install k3s

The installer creates a single-node cluster, makes its kubeconfig readable, and
disables the unneeded Traefik ingress controller:

```bash
./scripts/02-install-k3s.sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

To pin k3s, set a release before running the script:

```bash
INSTALL_K3S_VERSION='v1.31.5+k3s1' ./scripts/02-install-k3s.sh
```

Verify the node, system pods, and bundled metrics-server:

```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system
kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl top nodes
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes
```

`kubectl top` can take one or two minutes to return data. metrics-server powers
`kubectl top`; Prometheus separately obtains CPU and memory from kubelet/cAdvisor.

## 3. Configure Alertmanager email

The script generates an Alertmanager config, safely places SMTP values in a
Kubernetes Secret, and does not write the password into the repository.

Gmail example:

```bash
export EMAIL_TO='operator@example.com'
export SMTP_FROM='your-account@gmail.com'
export SMTP_SMARTHOST='smtp.gmail.com:587'
export SMTP_USERNAME='your-account@gmail.com'
./scripts/03-configure-alertmanager-email.sh
```

The script securely prompts for `SMTP_PASSWORD`. Use a Google app password.
For another provider, use its SMTP host, port, username, and sender. If the
provider explicitly does not use STARTTLS, set `SMTP_REQUIRE_TLS=false`.

Verify that the secret exists without printing its credentials:

```bash
kubectl -n monitoring get secret local-monitoring-alertmanager
kubectl -n monitoring get secret local-monitoring-alertmanager \
  -o jsonpath='{.data.alertmanager\.yaml}' | wc -c
```

To rotate credentials, export the new settings and rerun the same script.
Prometheus Operator automatically reloads the updated Secret.

## 4. Deploy Prometheus, Grafana, and Alertmanager

Install the latest available `kube-prometheus-stack` chart:

```bash
./scripts/04-deploy-monitoring.sh
```

For repeatable environments, inspect available chart versions and pin one:

```bash
helm search repo prometheus-community/kube-prometheus-stack --versions
CHART_VERSION='<chosen-version>' ./scripts/04-deploy-monitoring.sh
```

For persistent data, use the included `local-path` PVC overlay on the first
install. This requests 10 GiB for Prometheus, 2 GiB for Grafana, and 1 GiB for
Alertmanager:

```bash
ENABLE_PERSISTENCE=true ./scripts/04-deploy-monitoring.sh
kubectl -n monitoring get pvc
```

The base lab uses ephemeral volumes. Changing an existing Prometheus
StatefulSet between ephemeral and persistent storage may require recreating
that StatefulSet, so choose persistence at initial installation when possible.

Verify the chart and custom resources:

```bash
helm list -n monitoring
kubectl -n monitoring get pods
kubectl -n monitoring get svc
kubectl -n monitoring get prometheus,alertmanager
kubectl -n monitoring get prometheusrule local-cluster-alerts
kubectl -n monitoring get configmap local-cluster-dashboard
```

All monitoring pods should become `Running`. Jobs may show `Completed`.
On a Raspberry Pi, initial image pulls can take several minutes.

## 5. Build and deploy the mock application

Build with Docker, import the image into k3s containerd, and apply the
Deployment, Service, and ServiceMonitor:

```bash
./scripts/05-build-and-deploy-app.sh
```

The deployment uses two replicas, HTTP readiness/liveness probes, a 100 millicore
CPU limit, and a 128 MiB memory limit. Verify:

```bash
kubectl -n demo get deployment,pods,service,servicemonitor
kubectl -n demo rollout status deployment/mock-app
kubectl -n demo describe servicemonitor mock-app
kubectl -n demo top pods
```

Test the service and exported metrics:

```bash
kubectl -n demo port-forward service/mock-app 8080:8080
```

In a second terminal:

```bash
curl -fsS http://127.0.0.1:8080/
curl -fsS http://127.0.0.1:8080/healthz
curl -fsS http://127.0.0.1:8080/metrics | \
  grep -E 'mock_app_http_requests_total|process_resident_memory_bytes'
curl -i http://127.0.0.1:8080/simulate-error
```

The image is local to one node. On a multi-node cluster, push it to a registry
and replace `image: local/mock-observable-app:1.0.0`, or import the image archive
into k3s containerd on every schedulable node.

## 6. Verify Prometheus scraping and queries

Open Prometheus:

```bash
kubectl -n monitoring port-forward \
  service/monitoring-kube-prometheus-prometheus 9090:9090
```

Visit <http://127.0.0.1:9090/targets>. Search for `demo/mock-app`; both targets
should be `UP`. Under **Status > Rules**, confirm the
`kubernetes-pod-health` group is loaded.

The same checks can be made from a terminal:

```bash
curl -fsSG http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=up{namespace="demo",service="mock-app"}'

curl -fsSG http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=sum(rate(mock_app_http_requests_total[5m])) by (pod,status)'

curl -fsSG http://127.0.0.1:9090/api/v1/rules \
  --data-urlencode 'type=alert'
```

If the target is absent, check discovery and operator logs:

```bash
kubectl -n demo get servicemonitor mock-app -o yaml
kubectl -n monitoring logs \
  deployment/monitoring-kube-prometheus-operator --tail=100
```

## 7. Open Grafana and use the dashboard

Retrieve the generated admin password:

```bash
kubectl -n monitoring get secret monitoring-grafana \
  -o jsonpath='{.data.admin-password}' | base64 --decode
echo
```

Start the tunnel:

```bash
kubectl -n monitoring port-forward service/monitoring-grafana 3000:80
```

Open <http://127.0.0.1:3000> and sign in as `admin`. The Helm chart provisions
Prometheus as the default data source with UID `prometheus`.

Navigate to **Dashboards > Browse** and open
**Local Kubernetes: Pod Resources and Reliability**. Its ConfigMap is loaded by
Grafana's dashboard sidecar. It contains:

1. Pod CPU consumption as a percentage of configured CPU limits.
2. Pod working-set memory as a percentage of configured memory limits.
3. Container restart increases, used as the crash signal.
4. Application HTTP 4xx/5xx and explicit error rates.

Select namespace `demo` and one or all pods. If it does not appear, verify:

```bash
kubectl -n monitoring get configmap local-cluster-dashboard \
  -o jsonpath='{.metadata.labels.grafana_dashboard}'
kubectl -n monitoring logs deployment/monitoring-grafana \
  -c grafana-sc-dashboard --tail=100
```

The complete, importable dashboard JSON is under the
`local-cluster.json` key in `k8s/grafana-dashboard.yaml`. To import manually,
copy that JSON and use **Dashboards > New > Import**, then select the Prometheus
data source.

## 8. Understand and test alerts

`k8s/prometheus-rules.yaml` installs three rules:

- `PodContainerRestarted`: fires when a non-system container restarts in five
  minutes.
- `PodCrashLooping`: fires after two minutes in `CrashLoopBackOff`.
- `PodCpuLimitOver80Percent`: fires when a container remains over 80% of its
  configured CPU limit for five minutes.

The email receiver intentionally routes only these three lab alerts. Default
chart alerts remain visible but do not send email.

### Test a pod crash

Keep the application port-forward from step 5 running, then call:

```bash
curl -v http://127.0.0.1:8080/simulate-crash || true
kubectl -n demo get pods -w
```

The selected container exits, Kubernetes restarts it, and
`PodContainerRestarted` fires after the next scrape/evaluation. Alertmanager
waits 30 seconds to group notifications. Confirm:

```bash
kubectl -n demo get pods \
  -o custom-columns='POD:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount'
```

### Test sustained CPU above 80%

In one terminal:

```bash
kubectl -n demo port-forward service/mock-app 8080:8080
```

In another terminal, keep one replica busy for seven minutes:

```bash
curl --max-time 450 \
  'http://127.0.0.1:8080/simulate-cpu?seconds=420'
```

The endpoint performs a CPU-bound loop. The container's 100m CPU limit makes
the ratio approach 100%. The alert has a five-minute `for` period, so allow at
least six minutes plus the 30-second scrape/evaluation intervals.

Inspect pending/firing alerts in Prometheus at
<http://127.0.0.1:9090/alerts>, or query:

```bash
curl -fsSG http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=ALERTS{alertstate=~"pending|firing",alertname=~"Pod.*"}'
```

### Verify Alertmanager delivery

Open Alertmanager:

```bash
kubectl -n monitoring port-forward \
  service/monitoring-kube-prometheus-alertmanager 9093:9093
```

Visit <http://127.0.0.1:9093>. Also inspect runtime logs:

```bash
kubectl -n monitoring logs \
  statefulset/alertmanager-monitoring-kube-prometheus-alertmanager \
  -c alertmanager --tail=100
```

SMTP failures such as authentication rejection, sender-policy rejection, or
TLS mismatch are shown in these logs. Do not paste the Secret into logs or
support tickets.

## 9. Useful operations

Restart or upgrade the chart after changing values:

```bash
./scripts/04-deploy-monitoring.sh
```

Reapply only dashboards and alert rules:

```bash
kubectl apply -f k8s/grafana-dashboard.yaml
kubectl apply -f k8s/prometheus-rules.yaml
```

View current resource use:

```bash
kubectl top nodes
kubectl top pods -A --sort-by=memory
```

Stop k3s without deleting data:

```bash
sudo systemctl stop k3s
sudo systemctl start k3s
```

Remove the lab workloads and chart:

```bash
helm uninstall monitoring -n monitoring
kubectl delete namespace demo monitoring
```

Completely uninstall k3s only when you intend to delete the cluster:

```bash
sudo /usr/local/bin/k3s-uninstall.sh
```

## Security and production notes

- Replace port-forwarding with authenticated TLS ingress before remote access.
- Keep SMTP credentials only in Secrets and rotate them periodically.
- The crash endpoint is enabled only for this lab. Remove
  `ALLOW_CRASH_ENDPOINT=true` in a real workload.
- A Kubernetes Secret is base64-encoded, not encrypted by default. Production
  clusters should enable secret encryption at rest or use an external secret
  manager.
- Local-path volumes are tied to one node and are not backups. Use remote
  storage and tested backups for production.
- Tune retention and resource limits to the host. Prometheus cardinality and
  retention are the primary disk/RAM drivers.
