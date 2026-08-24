# Trade-offs and known limitations

This is a time-boxed demo running on real AWS infrastructure. Every shortcut below was taken deliberately, with the production alternative stated. Nothing here is hidden in the code; the same reasoning appears as comments next to the resources involved.

## Trade-offs

### One cluster, three namespaces (vs. per-environment accounts and clusters)

Demo: a single EKS cluster (`terasky-demo`) with `dev`, `staging`, and `production` namespaces. Environments are separated by namespace, RBAC (per-env ClusterRole/Binding names), per-namespace SecretStores with per-env IRSA roles, NetworkPolicy, and PSA `enforce=restricted` labels.

For: one cluster costs roughly a third of three, provisions in minutes, and still demonstrates the full promotion flow (same immutable image dev -> staging -> production via Git PRs, reconciled by Flux).

Against: namespaces share a control plane, node pool, VPC, and AWS account. A cluster-level failure or a noisy neighbor hits all environments; a cluster-admin compromise crosses all of them.

Production: separate AWS accounts per environment (AWS Organizations) and separate clusters, with production isolated at minimum. Independent IAM, secrets, networking, and blast radius. The Kustomize overlay structure carries over unchanged; only the Flux `Kustomization` targets move to per-cluster paths.

### Public EKS API endpoint

Demo: `cluster_endpoint_public_access = true` so the assignment can be driven from a laptop without a bastion or VPN. Compensating controls: authentication still goes through IAM (access entries), control-plane `api`/`audit`/`authenticator` logs are enabled, and worker nodes sit in private subnets.

Production: private endpoint plus VPN or bastion access. This is also why Checkov checks CKV_AWS_38/39 are consciously skipped rather than silenced.

### Single NAT gateway

Demo: one NAT gateway (about 32 USD/month plus data) instead of one per AZ. If the NAT's AZ fails, private-subnet egress fails for both AZs.

Production: one NAT gateway per AZ, or VPC endpoints for ECR/S3/STS to remove most NAT traffic (cheaper and removes the dependency for image pulls entirely).

### Egress NetworkPolicy allows TCP/443 anywhere

The backend NetworkPolicy restricts ingress to same-namespace pods on port 8000 and restricts egress to DNS plus TCP/443. Port 443 is open to any address because the EKS API endpoint and AWS APIs have no stable CIDR that is portable across clusters; pinning it would break on every new cluster.

For: still blocks lateral movement on every other port, and kubelet probes and `kubectl port-forward` are unaffected (both go through the kubelet, which NetworkPolicy exempts by design).

Production: tighten 443 egress to the cluster's actual API endpoint IPs and AWS service prefixes (or route AWS traffic through VPC endpoints, whose security groups then become the control point). Enforcement here is real: the VPC CNI network-policy agent is enabled via the addon config (`enableNetworkPolicy=true`); without it EKS silently ignores NetworkPolicy objects.

### No ALB controller, no TLS in the demo

The Ingress manifest ships in the base (class `alb`, internet-facing, target-type `ip`, per-env hosts) but the AWS Load Balancer Controller is not installed: there is no real domain for this exercise and installing a controller that can never satisfy the host rule adds nothing. Demo access is `kubectl port-forward`.

Production: Route53 -> ACM certificate -> ALB (via the controller) -> Service -> pods, with TLS terminated at the ALB. The manifest is written so that installing the controller and pointing DNS is the only remaining work.

### Kyverno in Enforce with a single admission-controller replica

Six ClusterPolicies run in `Enforce`, scoped only to `dev`/`staging`/`production` (never system controllers). Enforce is justified because the project fully owns those namespaces and every manifest in Git complies; Audit mode would demo nothing.

The risk: Kyverno's admission webhook fails closed. With the demo's single admission-controller replica, a dead Kyverno pod blocks all deployments to the policied namespaces until it recovers. That is an accepted, documented demo sizing choice (the HelmRelease says so in its header comment).

Production: 3 admission-controller replicas with a PDB, spread across nodes, and monitoring on webhook latency and availability.

### metrics-server and External Secrets Operator run single replicas

Same sizing logic on a 2-node demo cluster. Consequences of an outage are bounded and non-destructive: without metrics-server the HPA stops scaling (replicas freeze at their current count); without ESO, secret refresh pauses but already-synced Kubernetes Secrets keep working. Production runs both with multiple replicas and PDBs.

### Local Terraform apply for the initial bootstrap, CI apply afterwards

The first `terraform apply` ran locally: the OIDC roles that CI assumes (`terasky-demo-gha-terraform`, `terasky-demo-gha-ecr`) are themselves Terraform-managed, so CI cannot create the credentials it needs to run (chicken and egg). After that first apply, the intended path is the `terraform.yml` workflow: plan on PRs via OIDC, apply only through `workflow_dispatch` gated by the `production` environment approval. No AWS keys are stored in GitHub at any point.

### Checkov skips are documented accepted risks

`.checkov.yaml` skips exactly these checks, each a deliberate demo trade-off, not a silenced finding:

| Check | What it flags | Why skipped |
|---|---|---|
| CKV_AWS_38, CKV_AWS_39 | EKS public endpoint | Demo driven from a laptop; production uses a private endpoint plus bastion/VPN (see above) |
| CKV_AWS_37 | Not all control-plane log types enabled | `api`/`audit`/`authenticator` are kept; `scheduler`/`controllerManager` add cost with little demo value |
| CKV_AWS_341 | Managed node group launch template defaults | The demo uses the module's default launch template; production would use a custom one (encrypted gp3 volumes, IMDS hop limit of 1) |
| CKV_AWS_149 | Secrets Manager not using a customer-managed KMS key | AWS-managed key is acceptable for demo secrets; production uses a CMK with rotation |
| CKV2_AWS_57 | No automatic secret rotation configured | Rotation is handled out-of-band in this design (see secret rotation under known limitations) |
| CKV_AWS_136 | ECR not encrypted with a CMK | AES256 is acceptable for demo images; production recommendation is a CMK |
| CKV2_AWS_11 | No VPC flow logs | Cost trade-off for the demo; recommended in production |

## Known limitations

These are genuinely incomplete or weaker than production, not choices with an upside.

- **Bot-created PRs do not trigger CI.** The deploy PR from `build-push.yml` and the promotion PRs from `promote.yml` are created with the workflow `GITHUB_TOKEN`, and GitHub deliberately does not run workflows on events caused by that token (recursion safeguard). So CI checks do not auto-run on those PRs. Recommended fix: create the PRs with a GitHub App installation token (or a fine-grained PAT), which does trigger workflows.
- **Admin-bypass merges.** As a solo maintainer, deploy and promotion PRs are reviewed and merged by the repo admin, bypassing required checks where needed (a direct consequence of the previous point). In a team setup: branch protection with required status checks and required reviewers, no bypass.
- **No Prometheus actually deployed.** Monitoring is a documented design (kube-prometheus-stack or CloudWatch Container Insights, Fluent Bit for logs, OpenTelemetry for traces). The app exposes `/metrics` and `monitoring/alerts/backend-alerts.yaml` contains 6 syntactically valid PrometheusRule alerts, but no Prometheus runs on the demo cluster, so nothing scrapes or fires.
- **Secret rotation is manually triggered.** Rotation means running `aws secretsmanager put-secret-value` out-of-band; ESO then picks up the new value within its `refreshInterval` (1m in dev to make the rotation demo fast, 1h elsewhere). There is no automatic rotation schedule; production would attach a rotation Lambda in Secrets Manager, with the ESO sync path unchanged.
- **Terraform state backend is created imperatively.** `scripts/bootstrap-state.sh` creates the S3 state bucket (versioned, encrypted, public access blocked) and the DynamoDB lock table with the AWS CLI, because Terraform cannot store state in a bucket it has not created yet. The script is idempotent, but the backend itself is not under Terraform management. Common production answer: a tiny separate "bootstrap" Terraform root with local state, or an org-level module that provisions state backends for all projects.
- **Base image is version-pinned, not digest-pinned.** The Dockerfile uses `python:3.12-slim` in both stages. The tag moves as upstream patches land, so builds are not bit-for-bit reproducible and a compromised upstream tag would be inherited. All third-party GitHub Actions are already pinned to commit SHAs; the base image should get the same treatment (`python:3.12-slim@sha256:...`) with an automated bump process (Renovate/Dependabot) so the pin does not rot.

## What I would do next with more time

1. Pin the base image by digest and add Renovate for automated digest and dependency bumps.
2. Create the PR-bot GitHub App so CI runs on deploy and promotion PRs, then enable branch protection with required checks (no admin bypass).
3. Install the AWS Load Balancer Controller, attach a real domain (Route53 + ACM), and turn the shipped Ingress into a live TLS endpoint.
4. Deploy kube-prometheus-stack via Flux, wire in the existing PrometheusRule alerts, and add Fluent Bit log shipping to CloudWatch.
5. Split environments into separate AWS accounts and clusters; the overlay and Flux structure is already shaped for it.
6. Replace the manual rotation trigger with a Secrets Manager rotation Lambda.
7. Harden the node group with a custom launch template (encrypted gp3, IMDS hop limit 1) and add VPC endpoints for ECR/S3/STS, then tighten the 443 egress rule.
8. Scale Kyverno, ESO, and metrics-server to multiple replicas with PDBs, and alert on webhook availability.
9. Move the state backend under a dedicated bootstrap Terraform root and enable VPC flow logs plus full control-plane log types in production.
