# monitoring/

Example alerting rules for the backend service. **Not deployed on the demo cluster** (no Prometheus stack there); the full observability design, alert rationale table, and incident workflow live in [docs/monitoring.md](../docs/monitoring.md).

## Contents

- `alerts/backend-alerts.yaml`: one `PrometheusRule` with 6 alerts (5xx rate, crash loops, unavailable replicas, HPA at max, CPU near limit, node pressure). Syntactically valid kube-prometheus-stack rules; the first alert uses the app's own `http_requests_total` metric, the rest use kube-state-metrics and node-exporter series.

## How these would be deployed

1. Install kube-prometheus-stack (as a Flux `HelmRelease`, matching how metrics-server/external-secrets/kyverno are managed in `infrastructure/controllers/`), which brings Prometheus Operator, Prometheus, kube-state-metrics, node-exporter, Grafana, and Alertmanager.
2. Apply this file (or add it to a Flux Kustomization). The `release: kube-prometheus-stack` label on the PrometheusRule matches the operator's default rule selector, so Prometheus loads the rules automatically; a different Helm release name means updating that label.
3. Add a `ServiceMonitor` for the backend (`app.kubernetes.io/name: terasky-backend`, port 8000, path `/metrics`) so the 5xx-rate alert has data.
