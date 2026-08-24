# Monitoring and Logging

**Status up front:** this is the production observability design. It is mostly **not deployed** on the demo cluster (time-boxed; no Prometheus stack, no log shipper, no tracing). What IS live today:

- The app exposes real Prometheus metrics on `GET /metrics` (verifiable via `kubectl port-forward`).
- `metrics-server` (chart 3.14.0) is installed via Flux for HPA resource metrics.
- EKS control-plane logs (`api`, `audit`, `authenticator`) ship to CloudWatch.
- `monitoring/alerts/backend-alerts.yaml` contains 6 example `PrometheusRule` alerts, syntactically valid but not applied (nothing on the cluster would consume them).

## Metrics stack

Two viable options, with a recommendation:

| | Self-managed kube-prometheus-stack | AWS-managed (AMP + AMG, Container Insights) |
|---|---|---|
| Components | Prometheus, kube-state-metrics, node-exporter, Grafana, Alertmanager, one Helm chart | Amazon Managed Prometheus, Amazon Managed Grafana, CloudWatch Container Insights |
| Operational cost | You run and upgrade it; Prometheus storage/retention is yours to size | No servers to run; retention and HA handled by AWS |
| Money cost | EC2/EBS only | Per-sample ingestion + query pricing, Container Insights per-metric pricing (can dominate at scale) |
| Ecosystem | Full PromQL, ServiceMonitor/PrometheusRule CRDs, huge dashboard library | AMP is PromQL-compatible; Container Insights is CloudWatch-native, weaker Kubernetes drill-down |
| Lock-in | None (portable to any cluster) | AWS-only |

**Recommendation:** kube-prometheus-stack in-cluster for scraping and rules, because the alert rules in this repo are PrometheusRule CRDs and the app already speaks the Prometheus exposition format. For a multi-cluster or compliance-driven production estate, keep the same in-cluster collection but remote-write to Amazon Managed Prometheus so metric storage survives cluster loss and dashboards (Amazon Managed Grafana) sit outside the failure domain. Container Insights is a reasonable low-effort baseline but is not sufficient alone for the PromQL alerts below.

Scrape config for the backend would be a `ServiceMonitor` (or `PodMonitor`) selecting `app.kubernetes.io/name: terasky-backend` on port 8000, path `/metrics`, per namespace `dev`/`staging`/`production`.

## Logging

The app logs structured lines to stdout/stderr (level per environment: dev `DEBUG`, staging `INFO`, production `WARNING`), which is all a container should do; shipping is the platform's job.

**Design:** Fluent Bit as a DaemonSet reading `/var/log/containers/*` via the tail input with the Kubernetes filter (adds namespace/pod/container labels), output to **CloudWatch Logs**, one log group per environment (for example `/terasky-demo/backend/production`), retention set per group (dev short, production per compliance). The AWS for Fluent Bit chart plus an IRSA role with `logs:PutLogEvents`/`CreateLogStream` scoped to the project's log groups mirrors the ESO IRSA pattern already in this repo.

**Alternatives:**

- **Amazon OpenSearch:** better full-text search and dashboards, meaningfully more cost and an extra cluster to operate.
- **Loki:** label-indexed (cheap storage, same Grafana pane as metrics), natural fit if kube-prometheus-stack is chosen; weaker for arbitrary full-text queries.

CloudWatch Logs is the recommendation here because control-plane logs already land there, IAM is already the auth model, and there is nothing new to operate.

## Traces

**Design:** OpenTelemetry SDK in the FastAPI app (auto-instrumentation covers ASGI routes with minimal code), exporting OTLP to an OpenTelemetry Collector (deployed via the OTel Operator or Helm chart), which fans out to a backend: AWS X-Ray (via ADOT, IAM-native) or Grafana Tempo (pairs with Loki/Prometheus). For a single service traces add little; they earn their cost the moment a second service or an external dependency appears, because the trace joins the latency story across hops. Propagate W3C `traceparent` and inject the trace ID into log lines so logs and traces cross-link.

## Application metrics and SLOs

The app exports two metric families from `app/src/main.py` via a middleware that observes every request:

- `http_requests_total{method, path, status}` (counter)
- `http_request_duration_seconds{method, path}` (histogram)

These are exactly the inputs for the two SLOs that matter for a stateless HTTP API:

- **Availability SLO** (for example 99.9% of requests non-5xx over 30 days): error ratio is `sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))`. Alert 1 below is the fast-burn version of this.
- **Latency SLO** (for example 95% of requests under 300 ms): `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))`. The histogram also gives an exact "fraction under threshold" via the bucket counters, which is the correct SLI form (quantiles are for dashboards, bucket ratios for SLO math).

Everything else (restarts, replica availability, HPA state, node conditions) comes from kube-state-metrics and node-exporter, not the app, which is why the alert file needs the full stack.

## The 6 example alerts

Source: `monitoring/alerts/backend-alerts.yaml` (PrometheusRule, `release: kube-prometheus-stack` label so the operator's rule selector picks it up). Not deployed on the demo cluster.

| Alert | Condition | Severity | Why it matters | First response |
|---|---|---|---|---|
| `BackendHighErrorRate` | 5xx ratio > 5% of requests per namespace for 5m (app's own `http_requests_total`) | critical | Users are actively failing; this is the availability SLO burning fast | Check recent Flux deployments (`flux get kustomizations`, git log of the overlay), then pod logs; revert the last promotion if it correlates |
| `BackendPodCrashLooping` | > 3 restarts of the `backend` container in 15m | critical | CrashLoopBackOff: bad image, failing startup (for example missing secret), OOMKill | `kubectl describe pod` for last state and exit code, `kubectl logs --previous`, check `secretLoaded` path and ExternalSecret status |
| `BackendReplicasUnavailable` | Deployment `backend` has unavailable replicas for 10m | warning | Rollout stuck, scheduling failure, or failing probes; capacity and PDB headroom eroding | `kubectl rollout status`, `kubectl get events`, look for image pull errors, unschedulable pods, or probe failures |
| `BackendHpaAtMaxCapacity` | HPA current replicas >= maxReplicas for 15m | warning | No scaling headroom left; next load increase degrades latency instead of scaling | Confirm it is real load (request rate vs baseline), raise `maxReplicas` in the overlay via PR, or find the hot path |
| `BackendHighCpu` | Pod CPU > 90% of its limit for 15m | warning | CFS throttling degrades latency before the HPA average target reacts | Check `http_request_duration_seconds` p95, review limits in the overlay, profile if load is unchanged |
| `NodePressure` | Node reports Memory/Disk/PID pressure for 5m | critical | Kubelet may start evicting pods; a workload symptom is about to become a cluster symptom | `kubectl describe node`, identify the hog via node-exporter/`kubectl top`, cordon if needed; check node group sizing |

Routing: Alertmanager would send `severity: critical` to a paging channel and `severity: warning` to a ticket/Slack queue, grouped by namespace.

## Incident workflow

Order matters: go from user impact outward, and end at "what changed", because most incidents are deployments. Concrete commands for this project:

1. **Alert** fires (Alertmanager page or, interim, a CloudWatch alarm). Note namespace and severity from the labels.
2. **Dashboard:** Grafana service dashboard for the namespace: request rate, error ratio, p95 from the two app metrics, replica count vs HPA bounds.
3. **Workload metrics:** `kubectl -n production get deploy,hpa,pods -o wide` and `kubectl top pods -n production` (metrics-server is installed). Is it one pod or all of them? Scaling pinned?
4. **Kubernetes events:** `kubectl -n production get events --sort-by=.lastTimestamp` and `kubectl -n production describe pod <pod>` (probe failures, OOMKilled, FailedScheduling, image pulls).
5. **Pod logs:** `kubectl -n production logs deploy/backend --previous` for crashed containers, current logs otherwise; in the full design, the CloudWatch/Loki query for the namespace over the alert window.
6. **Application traces:** in the production design, open the exemplar trace for a slow/failed request in X-Ray or Tempo; not available on the demo.
7. **Node/cluster state:** `kubectl get nodes`, `kubectl describe node <node>` (conditions, allocatable vs allocated), and the EKS control-plane `api`/`audit` logs in CloudWatch if the API server itself is suspect. The app's own `/nodes` endpoint is a quick node-readiness view.
8. **Recent deployment history (the usual culprit):**
   - `flux get kustomizations` and `flux get helmreleases -A` (what reconciled, when, whether anything is failing or suspended).
   - `git log --oneline -- apps/backend/overlays/production/` (image tag bumps arrive as promotion PRs, so the diff that hit production is one commit).
   - `kubectl -n production get deploy backend -o jsonpath='{.spec.template.spec.containers[0].image}'` to confirm the running `sha-<gitsha>` tag matches Git.
   - Rollback is `git revert` of the promotion commit (or a PR restoring the prior tag); Flux reconciles it back. `kubectl set image` is break-glass only and must be re-reconciled to Git afterward.

## Demo vs production summary

| Concern | Demo (now) | Production recommendation |
|---|---|---|
| Metrics collection | App `/metrics` live, metrics-server only, nothing scrapes the app | kube-prometheus-stack, optionally remote-write to Amazon Managed Prometheus |
| Alerting | 6 example rules in Git, not applied | Same rules deployed via a Flux-managed kube-prometheus-stack HelmRelease, Alertmanager routing to paging/Slack |
| Logs | `kubectl logs` plus EKS control-plane logs in CloudWatch | Fluent Bit DaemonSet to CloudWatch Logs (or Loki), per-env groups and retention |
| Traces | None | OpenTelemetry SDK + collector to X-Ray (ADOT) or Tempo |
| Dashboards | None | Grafana (in-cluster or Amazon Managed Grafana): service SLO dashboard plus cluster/node dashboards |
