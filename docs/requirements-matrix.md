# Requirements Traceability Matrix

Every assignment requirement, where it is implemented, and how it was verified. Status values: **Done**, **Done (documented design)** for items intentionally delivered as a documented design rather than deployed on the demo cluster, and **Partial** with the reason.

## Application

| Assignment Requirement | Implementation | File/Resource | Verification | Status |
|---|---|---|---|---|
| Backend application | Python FastAPI service, pinned dependencies, multi-stage non-root container (uid 10001) | `app/src/main.py`, `app/src/k8s.py`, `app/Dockerfile`, `app/requirements.txt` | `make test` (pytest 8/8), `make lint` (ruff), CI jobs `Python lint + tests` and `Docker build validation` | Done |
| GET /health | Cheap, dependency-free endpoint (deliberately no Kubernetes API call); reports `secretLoaded` boolean, never the secret value | `app/src/main.py` (`health()`) | `app/tests/test_health.py`; `scripts/verify.sh` asserts `/health -> 200` via port-forward | Done |
| GET /nodes with current-node marking | Lists nodes via in-cluster ServiceAccount (safe fields only: name/ready/current/kubeletVersion/architecture/os), marks the pod's node from Downward API `NODE_NAME`, returns 503 if the API is unavailable | `app/src/main.py` (`nodes()`), `app/src/k8s.py` | `app/tests/test_nodes.py` (shaping, current-node marking, 503 path); `scripts/verify.sh` compares `currentNode` against `kubectl get pod -o jsonpath='{.spec.nodeName}'` | Done |

## Kubernetes

| Assignment Requirement | Implementation | File/Resource | Verification | Status |
|---|---|---|---|---|
| Dedicated ServiceAccount | SA `backend` per namespace (token mounted intentionally, the app needs the API); separate SA `eso-backend` for the secrets flow | `apps/backend/base/serviceaccount.yaml` | `scripts/verify.sh`: `kubectl get serviceaccount -n dev backend eso-backend` | Done |
| Least-privilege RBAC | Exactly `get`,`list` on `nodes`; no watch, no secrets, no wildcards | `apps/backend/base/rbac.yaml` | `scripts/verify.sh` RBAC positive checks plus 7 negative `kubectl auth can-i` denials | Done |
| ClusterRole | `nodes` is cluster-scoped, so a namespaced Role cannot grant it; per-env unique names via overlay JSON patch (`terasky-backend-node-reader-<env>`) | `apps/backend/base/rbac.yaml`, `apps/backend/overlays/*/kustomization.yaml` | `kubectl get clusterrole terasky-backend-node-reader-dev` in `scripts/verify.sh` | Done |
| ClusterRoleBinding | Binds each env's ClusterRole to that namespace's `backend` SA; overlay repoints `roleRef` | `apps/backend/base/rbac.yaml`, overlay patches | `kubectl get clusterrolebinding terasky-backend-node-reader-dev` in `scripts/verify.sh` | Done |
| Namespace structure | `dev`, `staging`, `production` namespaces, each labeled `pod-security.kubernetes.io/enforce: restricted` | `apps/backend/overlays/{dev,staging,production}/namespace.yaml` | `kubectl get ns dev staging production --show-labels` | Done |
| Deployment | `spec.replicas` deliberately omitted (HPA owns replica count, otherwise Flux would revert scaling); RollingUpdate maxUnavailable 0 / maxSurge 1; podAntiAffinity across hostnames | `apps/backend/base/deployment.yaml` | CI job `Kustomize build + kubeconform`; `kubectl get deployments -A -l app.kubernetes.io/part-of=terasky-home-assignment` | Done |
| Service | ClusterIP service on port 80 -> 8000 | `apps/backend/base/service.yaml` | `scripts/verify.sh` port-forwards `svc/backend` and curls all endpoints | Done |
| Ingress | Manifest ships (class `alb`, internet-facing, IP targets, per-env host); AWS Load Balancer Controller not installed on the demo cluster (no domain, time-boxed). Demo access is `kubectl port-forward`; production design is Route53 -> ACM -> ALB -> Service -> Pods | `apps/backend/base/ingress.yaml`, overlay host patches | Rendered and schema-validated by `make validate` / CI `Kustomize build + kubeconform` | Done (documented design) |
| ConfigMap | `configMapGenerator` produces `backend-config` (APP_ENV, LOG_LEVEL) with a content-hash suffix, so config changes roll the Deployment | `apps/backend/base/kustomization.yaml`, per-env merge in overlays | `kubectl get cm -n dev`; `make kustomize-build` | Done |
| Secure Secret integration | ESO delivers `backend-secrets` from AWS Secrets Manager into env `API_KEY`; secret values never in Git or Terraform state | `apps/backend/base/externalsecret.yaml`, `apps/backend/base/deployment.yaml` (env `API_KEY`) | `scripts/verify.sh`: ExternalSecret Ready + Secret materialized in all 3 namespaces; `/health` reports `secretLoaded: true` | Done |
| Resource requests/limits | Requests and limits (CPU + memory) in base, larger in production overlay | `apps/backend/base/deployment.yaml`, `apps/backend/overlays/production/kustomization.yaml` | Kyverno `require-resources` in Enforce; `kyverno test policies/tests` | Done |
| Liveness probe | HTTP `/health`, 10s period, 3 failures | `apps/backend/base/deployment.yaml` | Kyverno `require-probes` in Enforce; `kubectl describe deploy backend -n dev` | Done |
| Readiness probe | HTTP `/health`; deliberately does not check the Kubernetes API so a control-plane hiccup cannot unready every replica at once | `apps/backend/base/deployment.yaml`, rationale in `app/src/main.py` | Kyverno `require-probes`; pods Ready in `scripts/verify.sh` | Done |
| SecurityContext | runAsNonRoot uid/gid 10001, seccomp RuntimeDefault, no privilege escalation, readOnlyRootFilesystem, drop ALL capabilities, `/tmp` emptyDir | `apps/backend/base/deployment.yaml` | PSA `restricted` admission on the namespaces; Kyverno `require-run-as-non-root` + `disallow-privilege-escalation` tests | Done |
| HPA | CPU-based; dev 1-3, base/staging 2-4, production 3-6 | `apps/backend/base/hpa.yaml`, overlay patches | `kubectl get hpa -A` and `kubectl top nodes` (metrics-server) in `scripts/verify.sh` | Done |
| PDB | Base `minAvailable: 1`; dev `maxUnavailable: 1` (can run one replica); production `minAvailable: 2` | `apps/backend/base/pdb.yaml`, overlay patches | `kubectl get pdb -n dev` in `scripts/verify.sh` | Done |
| NetworkPolicy | Ingress only from same-namespace pods to 8000; egress DNS + TCP/443 anywhere (trade-off: the EKS API endpoint has no stable portable CIDR; 443-anywhere still blocks lateral movement on other ports). Enforced by the VPC CNI network policy agent | `apps/backend/base/networkpolicy.yaml`; agent enabled via `enableNetworkPolicy` in `infra/terraform/main.tf` | `kubectl get networkpolicy -n dev`; addon config verified on the cluster | Done |

## Environments

| Assignment Requirement | Implementation | File/Resource | Verification | Status |
|---|---|---|---|---|
| dev/staging/production configurations | One Kustomize base, three overlays differing in: namespace, APP_ENV, LOG_LEVEL (DEBUG/INFO/WARNING), resources, HPA and PDB sizing, ingress host, ESO secret path, ESO refreshInterval (dev 1m for the rotation demo), per-env IRSA role annotation, per-env ClusterRole/Binding names | `apps/backend/base/`, `apps/backend/overlays/{dev,staging,production}/` | `make kustomize-build` + `make validate`; CI job `Kustomize build + kubeconform` renders all three overlays | Done |

## GitOps

| Assignment Requirement | Implementation | File/Resource | Verification | Status |
|---|---|---|---|---|
| Flux GitOps | Bootstrapped with `flux bootstrap github --path clusters/demo --token-auth=false` (SSH deploy key, no PAT in cluster); layered Kustomizations `infra-controllers` -> `infra-configs` -> `backend-{dev,staging,production}` with `dependsOn`, `prune: true`, `wait: true`, 5-10m intervals | `clusters/demo/flux-system/`, `clusters/demo/infrastructure.yaml`, `clusters/demo/applications.yaml` | `flux get kustomizations -A` and `flux get helmreleases -A` in `scripts/verify.sh` (all Ready) | Done |
| Drift detection / reconciliation explanation | Flux continuously reconciles Git to cluster; `prune: true` removes deleted objects. Drift demo: `kubectl set env` an out-of-band change, Flux reverts it. Deliberately not `kubectl scale`, because the HPA (not Flux) owns replicas and would correct it first, muddying the story | `clusters/demo/applications.yaml`, drift step in `scripts/demo.sh` | Run `scripts/demo.sh`; watch Flux revert the env var on the next reconcile | Done |

## CI/CD

| Assignment Requirement | Implementation | File/Resource | Verification | Status |
|---|---|---|---|---|
| CI/CD pipeline | Four GitHub Actions workflows, all third-party actions pinned to commit SHAs; CI/CD never touches the cluster (no kubectl/helm deploy anywhere), Flux pulls | `.github/workflows/{ci,build-push,promote,terraform}.yml` | Green runs in GitHub Actions; `grep -r kubectl .github/workflows` finds no cluster access | Done |
| Build/test/scan/push flow | On `app/**` push to main: pytest -> OIDC AssumeRole -> ECR login -> build `sha-<7sha>` -> Trivy image scan (HIGH/CRITICAL gate) -> push -> auto-PR updating the dev overlay via `kustomize edit set image` | `.github/workflows/build-push.yml` | Workflow jobs `Unit tests`, `Build, scan, push image`, `PR - deploy to dev` | Done |
| Image tagging strategy | Immutable `sha-<git sha>` tags only; ECR repository set to IMMUTABLE with scan-on-push and a lifecycle policy; `:latest` blocked by Kyverno | `.github/workflows/build-push.yml`, `infra/terraform/ecr.tf`, `policies/kyverno/disallow-latest-tag.yaml` | ECR rejects tag overwrite; `kyverno test policies/tests` covers the untagged/latest fixtures | Done |
| Promotion strategy | The same immutable image tag moves dev -> staging -> production, never rebuilt; `promote.yml` enforces the chain (staging <= dev, production <= staging) by reading the source overlay; production job gated by the GitHub `production` environment with a required reviewer; output is a PR only | `.github/workflows/promote.yml`, `scripts/promote.sh` | `Promote` workflow run + the reviewed promotion PR diff (only `newTag` changes) | Done |
| Rollback strategy | `git revert` the promotion commit (or a PR restoring the prior tag); Flux reconciles the cluster back. `kubectl set image` is break-glass only and must be followed by re-reconciling Git | Promotion PRs in Git history; `clusters/demo/applications.yaml` | `git revert <sha>` then `flux reconcile kustomization backend-production -n flux-system` | Done |
| GitHub -> AWS authentication | OIDC only, zero stored AWS keys; existing account OIDC provider reused as a data source; two scoped roles (`terasky-demo-gha-ecr`, `terasky-demo-gha-terraform`); trust covers both legacy and immutable OIDC subject formats (this account issues immutable subject claims) | `infra/terraform/iam-github.tf` | Successful OIDC assume in `Build, scan, push image` and `terraform plan` jobs; no `AWS_ACCESS_KEY_ID` secrets in the repo | Done |

## IaC

| Assignment Requirement | Implementation | File/Resource | Verification | Status |
|---|---|---|---|---|
| Infrastructure as Code | Terraform: VPC + EKS v1.33 (2x t3.large, AL2023, private subnets, KMS secret encryption, IRSA, control-plane logs, VPC CNI network policy agent), ECR, IAM (GitHub OIDC + per-env ESO roles), Secrets Manager containers; remote state S3 + DynamoDB lock | `infra/terraform/` (`main.tf`, `ecr.tf`, `iam-github.tf`, `iam-eso.tf`, `secrets.tf`), `scripts/bootstrap-state.sh` | `make tf-fmt tf-validate`; CI job `Terraform fmt + validate`; `terraform.yml` plan on PR, gated apply; 73 resources applied cleanly (0 changed/destroyed on first apply) | Done |

## Security/Policy

| Assignment Requirement | Implementation | File/Resource | Verification | Status |
|---|---|---|---|---|
| Policy as Code | 6 Kyverno ClusterPolicies in Enforce, scoped only to `dev`/`staging`/`production` (never system controllers): require-run-as-non-root, disallow-privilege-escalation, require-resources, require-probes, disallow-latest-tag, restrict-image-registries (only the project ECR). Enforce is justified: the namespaces are fully owned by this project and every Git manifest complies. Single-replica admission controller is a documented demo trade-off (webhook fail-closed) | `policies/kyverno/`, deployed via `infrastructure/configs/` -> Flux `infra-configs` | `make policy-test` (`kyverno test policies/tests`, 16 assertions against good/bad/untagged fixtures); CI job `Kyverno policy tests`; live: apply `policies/tests/resources/bad-pod.yaml` and watch admission deny it | Done |
| Security scanning | Trivy filesystem scan (vuln/misconfig/secret, HIGH/CRITICAL exit 1), Trivy image scan before push, Checkov on Terraform with documented skips | CI `Trivy + Checkov scans` job, `.trivyignore`, `.checkov.yaml`, image scan in `.github/workflows/build-push.yml` | CI runs; local Trivy fs clean (0 HIGH/CRITICAL) | Done |

## Secrets

| Assignment Requirement | Implementation | File/Resource | Verification | Status |
|---|---|---|---|---|
| Secrets-management design | Per-namespace SecretStore (not ClusterSecretStore) with IRSA JWT auth via SA `eso-backend`; each env's IAM role trusts only `system:serviceaccount:<env>:eso-backend` and can read only that env's secret ARN (GetSecretValue/DescribeSecret). Terraform creates the secret containers; values are set out-of-band with `aws secretsmanager put-secret-value`, never in state or Git. Rotation: update the value, ESO refreshInterval picks it up (dev 1m) | `apps/backend/base/externalsecret.yaml`, `infra/terraform/iam-eso.tf`, `infra/terraform/secrets.tf`, ESO HelmRelease in `infrastructure/controllers/external-secrets/` | `scripts/verify.sh`: ExternalSecret Ready and Secret materialized in all 3 namespaces; rotation demo in `scripts/demo.sh` | Done |

## Monitoring

| Assignment Requirement | Implementation | File/Resource | Verification | Status |
|---|---|---|---|---|
| Monitoring/logging design | `/metrics` implemented (prometheus-client: `http_requests_total`, `http_request_duration_seconds`); design documents kube-prometheus-stack (or CloudWatch Container Insights), Fluent Bit -> CloudWatch for logs, OpenTelemetry for traces; metrics-server deployed (feeds the HPA) | `app/src/main.py`, `infrastructure/controllers/metrics-server/`, design in `docs/architecture.md` | `scripts/verify.sh` curls `/metrics` and asserts `http_requests_total`; `kubectl top nodes`. Prometheus stack itself not deployed on the demo cluster (time-boxed) | Done (documented design) |
| >= 3 example alerts | 6 PrometheusRule alerts: BackendHighErrorRate, BackendPodCrashLooping, BackendReplicasUnavailable, BackendHpaAtMaxCapacity, BackendHighCpu, NodePressure | `monitoring/alerts/backend-alerts.yaml` | Syntactically valid PrometheusRule; not deployed (no Prometheus on the demo cluster) | Done (documented design) |

## AWS design

| Assignment Requirement | Implementation | File/Resource | Verification | Status |
|---|---|---|---|---|
| Production AWS architecture | Demo cluster is live (EKS terasky-demo, eu-west-1, private nodes). Documented production deltas: separate AWS accounts per env (Organizations) and separate clusters (prod isolated at minimum), private EKS endpoint + VPN/bastion (demo uses public endpoint), one NAT per AZ or VPC endpoints (demo uses a single NAT for cost), Route53 + ACM + ALB ingress | `infra/terraform/main.tf`, production deltas in `docs/architecture.md` | `terraform plan` clean; cluster live (`kubectl get nodes`: 2 Ready). Production variant is a documented design, deliberately not built for a demo | Done (documented design) |
| Environment separation | Demo: one cluster, three namespaces with PSA, per-env RBAC names, per-env IRSA roles and secret paths, NetworkPolicies (explicit cost/time trade-off). Production recommendation: account- and cluster-level separation | `apps/backend/overlays/`, `infra/terraform/iam-eso.tf` | `scripts/verify.sh` cross-namespace RBAC denials; per-env IAM policies scope to one secret ARN each | Done |

## Docs

| Assignment Requirement | Implementation | File/Resource | Verification | Status |
|---|---|---|---|---|
| Architecture diagram | Repository and runtime architecture with diagram(s) | `docs/architecture.md` | Renders on GitHub | Done |
| Assumptions | Stated explicitly (single demo account/region, no domain, time-boxed scope) | `README.md`, `docs/architecture.md` | Review | Done |
| Design decisions | Recorded with rationale (HPA owns replicas, ClusterRole necessity, per-namespace SecretStore, Enforce-mode Kyverno, readiness probe scope) | `docs/decisions.md`, inline comments in the manifests they govern | Review; each decision cross-references the implementing file | Done |
| Trade-offs | Every demo trade-off marked against its production recommendation (single NAT, public endpoint, shared cluster, no ALB controller, single-replica controllers) | `docs/tradeoffs.md`, `README.md` | Review | Done |
| Known limitations | Documented honestly, including: PRs created with the workflow `GITHUB_TOKEN` do not trigger other workflows (GitHub safeguard), so CI does not auto-run on bot-created deploy/promotion PRs; solo-maintainer flow is admin review + merge; production fix is a GitHub App installation token | `docs/tradeoffs.md`, `README.md` | Review | Done |
| Production recommendations | Per-topic production path stated next to each demo trade-off | `docs/aws-production-design.md`, `docs/tradeoffs.md` | Review | Done |
| Deployment/demo instructions | Bootstrap state, Terraform apply, Flux bootstrap, verification, guided 5-minute demo | `README.md`, `scripts/bootstrap-state.sh`, `scripts/verify.sh`, `scripts/demo.sh`, `Makefile` | `make verify` passes against the live cluster; `scripts/demo.sh` executed end to end | Done |
| AI transparency | How AI tooling was used in producing this assignment | `docs/AI_USAGE.md` | Review | Done |
| Requirements traceability | This matrix | `docs/requirements-matrix.md` | Review | Done |
