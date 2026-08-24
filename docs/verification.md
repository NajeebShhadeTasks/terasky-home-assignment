# Verification record

Non-sensitive evidence collected while building and deploying the assignment.
Date: 2026-08-24. All commands were actually executed; outputs are trimmed for
readability, never altered.

## Environment

| Tool | Version |
|---|---|
| git | 2.50.1 |
| gh | authenticated as `NajeebShhadeTasks` (keyring) |
| aws cli | account `647604014014`, user `Admin`, region `eu-west-1` |
| terraform | 1.5.7 |
| kubectl | v1.34.1 (kustomize v5.7.1) |
| flux | 2.9.4 |
| docker | 28.5.1 |
| kubeconform | v0.8.0 |
| kyverno CLI | 1.19.0 |
| trivy | 0.74.0 |
| python | 3.12 (venv for app), 3.9 system |

Pre-existing account facts (verified before any change):

- GitHub OIDC provider `token.actions.githubusercontent.com` already existed
  (owned by an unrelated project) -> reused via a Terraform data source.
- No `terasky*` resources existed anywhere (IAM, ECR, EKS, Secrets Manager).
- Only the default VPC existed in eu-west-1; 2/5 EIPs in use.

## Terraform

```
terraform fmt -check -recursive   -> clean
terraform validate                -> Success! The configuration is valid.
terraform plan                    -> 73 to add, 0 to change, 0 to destroy
  (plan JSON inspected programmatically: only "create" actions - no changes to
   any pre-existing resource)
terraform apply                   -> Apply complete! Resources: 73 added, 0 changed, 0 destroyed.
```

Key outputs: cluster `terasky-demo` (v1.33), ECR
`647604014014.dkr.ecr.eu-west-1.amazonaws.com/terasky-demo/backend`, IAM roles
`terasky-demo-gha-ecr`, `terasky-demo-gha-terraform`, `terasky-demo-eso-{dev,staging,production}`.

A follow-up apply updated only the two GitHub-Actions role trust policies
(immutable OIDC subject support): `0 added, 2 changed, 0 destroyed`.

## Application

```
pytest  -> 8 passed
ruff format --check / ruff check -> clean
```

Dependency remediation: the first CI image scan found starlette 0.41.3
(HIGH CVE-2025-62727, CVE-2026-48818, CVE-2026-54283, all with fixed versions).
Fixed by upgrading to fastapi 0.141.1 / starlette 1.6.0 and fully pinning the
transitive dependency tree in `app/requirements.txt`; tests re-run green.

## Kubernetes manifests

```
kubectl kustomize apps/backend/overlays/{dev,staging,production} -> build OK
kubeconform (strict, with datree CRD catalog):
  dev/staging/production: 14 resources each - Valid: 14, Invalid: 0
  infrastructure/controllers: 8 valid; infrastructure/configs: 6 valid
```

Confirmed in the rendered output: ClusterRole/ClusterRoleBinding renamed per
environment (`terasky-backend-node-reader-dev`), binding subject namespace set
by the kustomize namespace transformer.

## Policies

```
kyverno test policies/tests -> 16 passed, 0 failed
  (compliant pod passes all 8 rules; violating pod fails all 7 applicable
   rules; untagged image fails require-image-tag)
```

## Security scanning

```
trivy fs . (HIGH/CRITICAL, vuln+misconfig+secret) -> clean after remediation
```

Accepted, documented findings (.trivyignore / .checkov.yaml): EKS public
endpoint (demo access trade-off), module-default node egress, IMDS hop limit,
AWS-managed keys, VPC flow logs - each with justification and a production
recommendation.

## GitHub Actions

First runs failed; each failure was diagnosed and fixed (recorded honestly):

1. `Not authorized to perform sts:AssumeRoleWithWebIdentity` -> this GitHub
   account issues immutable OIDC subject claims
   (`repo:NajeebShhadeTasks@176375566/terasky-home-assignment@1344950844:...`,
   verified via `gh api .../actions/oidc/customization/sub`). Trust policies
   updated to accept both exact subject formats. Subsequent OIDC logins succeed.
2. `clusters/demo` had no kustomization (Flux bootstrap layout) -> CI now
   builds `clusters/demo/flux-system` and validates the sync files directly.
3. trivy-action's internal installer failed -> replaced with a directly pinned
   trivy install (v0.74.0).
4. Image scan HIGH findings in starlette -> dependency upgrade (see above).

## Flux

```
flux bootstrap github ... --token-auth=false
  -> SSH deploy key created; all controllers healthy
flux get helmreleases -A
  -> metrics-server 3.14.0 Ready, external-secrets 2.9.0 Ready, kyverno 3.9.0 Ready
```

## Cluster (interim state before first image)

```
kubectl get nodes -> 2x t3.large Ready (v1.33.13-eks)
kubectl get pods -A -> all platform pods Running;
  backend pods ImagePullBackOff in dev/staging/production
  (expected: overlays pointed at placeholder sha-0000000 before the first CI
   image was built; resolved by the first deploy/promotion PRs)
```

## Runtime verification (final)

### Full deployment

First CI-built image `sha-760363c` was deployed to dev via the automated
PR (#1), then promoted with the promote workflow: staging (PR #2), production
(PR #3, after approving the pending deployment on the `production` GitHub
environment). Same immutable tag in all three overlays; never rebuilt.

```
kubectl get pods -A -l app.kubernetes.io/name=terasky-backend
  dev:        1 pod Running   (HPA 1-3, cpu 6%/70%)
  staging:    2 pods Running  (HPA 2-4, cpu 5%/70%)
  production: 3 pods Running  (HPA 3-6, cpu 2%/70%)  spread across both nodes
kubectl top nodes -> metrics-server serving (HPA has live CPU metrics)
flux get kustomizations -A -> all 6 Ready at the same revision
```

### scripts/verify.sh

```
PASS=23 FAIL=0
```

Highlights:

- `/health` -> 200, `{"status":"ok","environment":"dev","secretLoaded":true}`
- `/nodes` -> `currentNode` = `ip-10-60-8-111.eu-west-1.compute.internal`,
  exactly matching `kubectl get pod -o wide`; both nodes listed, only the
  hosting node marked `"current": true`
- `/metrics` -> `http_requests_total{...}` counters live
- RBAC positive: backend SA CAN get/list nodes
- RBAC negative: delete pods / get secrets / list secrets / create deployments /
  delete nodes / create clusterroles / watch nodes -> ALL denied
- ExternalSecret `SecretSynced/Ready` and `backend-secrets` materialized in all
  three namespaces

### Admission control (negative tests, live cluster)

1. `kubectl run --image=nginx:latest` (no securityContext) -> **rejected by
   Pod Security Admission** (`restricted` namespace labels).
2. A PSA-compliant pod using `docker.io/library/nginx:latest` -> **rejected by
   Kyverno** with exactly the expected policy messages:
   `disallow-latest-tag` ("mutable `latest` tag is not allowed") and
   `restrict-image-registries` ("Images must come from
   647604014014.dkr.ecr.eu-west-1.amazonaws.com").

### Flux drift correction

```
kubectl set env deployment/backend -n dev DRIFT_DEMO=manual-change
  env: NODE_NAME POD_NAME POD_NAMESPACE API_KEY DRIFT_DEMO
flux reconcile kustomization backend-dev --with-source
  env: NODE_NAME POD_NAME POD_NAMESPACE API_KEY      <- drift reverted
```

(Replica-count drift is intentionally not the demo: the HPA owns
`spec.replicas`, which is why the field is absent from Git. See docs/demo.md.)

### Secret rotation

```
aws secretsmanager put-secret-value --secret-id terasky/dev/backend ... (value not shown)
Secret resourceVersion: before=4594 after=25853 within the 1m refreshInterval
ExternalSecret status: "secret synced"
```

### NetworkPolicy enforcement

VPC CNI node agent runs with `--enable-network-policy=true` (verified on the
aws-node DaemonSet), so the deployed NetworkPolicy objects are enforced, not
silently ignored.

### Rollback drill

A second image (`app` version 1.0.1) was built by CI, deployed to dev through
the automated PR, verified, and then rolled back with `git revert` of the
deploy commit; Flux reconciled dev back to the previous image. Evidence in the
git history (`git log -- apps/backend/overlays/dev`).


## Adversarial review round (2026-08-24, pre-submission)

A six-area adversarial review (application, manifests, Terraform/AWS, CI/CD,
GitOps/policy/secrets, docs-vs-reality) produced 35 findings
(10 major / 16 minor / 9 nit). All majors and nearly all minors were fixed and
re-verified; the notable ones:

- Prometheus middleware labeled metrics with the RAW request path (unbounded
  cardinality under bot scans) -> now labels with the matched route template,
  folds unmatched requests into one `unmatched` series, and records handler
  exceptions as 500s. Regression tests added (10 tests total).
- PR-time `terraform plan` ran with the WRITE-capable role while its trust
  allowed `pull_request` (a PR can edit the workflow it runs under) -> new
  dedicated `terasky-demo-gha-terraform-plan` role with ReadOnlyAccess for PR
  plans (`-lock=false`); `pull_request` removed from the write role's trust.
  Exercised live: plan dispatch run succeeded with the read-only role.
- Kyverno's fail-closed webhook intercepted every non-system namespace,
  contradicting the "cannot brick the platform" claim -> webhook now scoped
  via `config.webhooks.namespaceSelector` to dev/staging/production
  (verified on the live ValidatingWebhookConfiguration; enforcement re-tested).
- promote/build-push re-runs were not idempotent (immutable-tag push failure,
  empty-commit failure, stale branches) -> ECR tag pre-check, no-op guards,
  forced branch pushes, build concurrency group.
- `verify.sh` mis-reported RBAC denials as failures under stock macOS
  bash 3.2 (empty-array expansion with `set -u`) -> rewritten without arrays;
  re-run under /bin/bash 3.2: PASS=23 FAIL=0.
- Image policies ignored init/ephemeral containers (`kubectl debug` bypass) ->
  patterns extended; policy tests still 16/16.
- Doc corrections: stale dependency versions in DD-1, ALB/NetworkPolicy
  claim accuracy, cAdvisor vs node-exporter attribution, versioned-bucket
  cleanup procedure, action pin version comments, node-IP examples, typo.

Accepted (documented, not fixed): GITHUB_TOKEN-created PRs do not trigger CI
(GitHub App token is the production fix); admin-bypass merges for the solo
maintainer; self-approval of the production environment; demo bootstrap starts
on a placeholder tag until the first image lands.

Final state after remediation: all three environments promoted to
`sha-fde30ff` through the full chain (deploy PR #5, staging PR #6, production
PR #7 with environment approval), rollouts green, `verify.sh` 23/23 under both
bash 5 and stock bash 3.2, `terraform plan` workflow exercised via
workflow_dispatch using the read-only role (run succeeded), Terraform reports
zero pending changes.
