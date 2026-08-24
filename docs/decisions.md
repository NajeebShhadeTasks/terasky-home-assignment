# Design Decisions

Numbered decision records for the choices that shaped this repository. Each record states the decision, the context it was made in, the reasoning, and the alternatives that were considered. Demo trade-offs are marked explicitly, with the production recommendation alongside.

Format per record: **Decision** / **Context** / **Why** / **Alternatives considered**.

---

## DD-1: FastAPI on Python for the backend

**Decision.** Implement the backend as a Python FastAPI service (`app/`), served by uvicorn, with the full dependency tree pinned in `app/requirements.txt` (fastapi 0.141.1, uvicorn 0.52.4, kubernetes 36.0.3, prometheus-client 0.26.0 at the time of writing; the file is the source of truth - it was regenerated during the starlette CVE remediation).

**Context.** The assignment needs a small HTTP service with three endpoints: `/health`, `/nodes` (talks to the Kubernetes API), and `/metrics` (Prometheus format). The service itself is a vehicle for the platform work, not the point of the exercise.

**Why.** The official `kubernetes` Python client and `prometheus-client` cover the two non-trivial requirements with minimal code. FastAPI gives typed request handling, an async-capable middleware hook for metrics, and a test story (pytest + TestClient, 8 tests) in very few lines. Everything version-pinned keeps builds reproducible.

**Alternatives considered.** Go (smaller image, static binary, but more boilerplate for the same three endpoints and slower to iterate under time constraints). Flask (fine, but FastAPI's middleware and dependency model made the metrics instrumentation cleaner). Node.js (weaker official Kubernetes client story).

---

## DD-2: ClusterRole, not Role, for node access

**Decision.** Grant the app ServiceAccount `get` and `list` on `nodes` via a ClusterRole and ClusterRoleBinding (`apps/backend/base/rbac.yaml`), with exactly those two verbs and no others.

**Context.** `GET /nodes` lists cluster nodes through the Kubernetes API using the pod's ServiceAccount.

**Why.** Nodes are cluster-scoped resources. A namespaced Role is structurally incapable of granting access to them, so a ClusterRole is not a convenience here, it is the only mechanism that works. The blast radius is contained by the rule itself: `get`/`list` on `nodes` only, no `watch`, no secrets, no wildcards.

**Alternatives considered.** Role + RoleBinding (does not work for cluster-scoped resources, rejected on correctness). A broader ClusterRole such as the built-in `view` (grants far more than needed, rejected on least privilege). Having the app read node data from a sidecar or cache maintained by a more privileged component (needless indirection at this scale).

---

## DD-3: `spec.replicas` omitted from the Deployment

**Decision.** The Deployment (`apps/backend/base/deployment.yaml`) deliberately does not set `spec.replicas`. The HPA is the sole owner of replica count.

**Context.** The Deployment is continuously reconciled by Flux from Git, and an HPA (per-env ranges: dev 1-3, staging 2-4, production 3-6) scales the same Deployment.

**Why.** If `replicas` were in Git, two controllers would fight over one field: the HPA scales up, the next Flux reconcile applies the Git value and scales back down, and the workload flaps forever. Omitting the field removes the conflict at the source; server-side apply then leaves replica count to the HPA. This decision also shapes the drift demo: drift is demonstrated with an env-var change (`kubectl set env`, reverted by Flux) rather than `kubectl scale`, because a scale change would be corrected by the HPA, not Flux, and would muddy the GitOps story.

**Alternatives considered.** Set `replicas` and drop the HPA (loses autoscaling). Set `replicas` and tell Flux to ignore the field via managed-field/patch exceptions (works, but is per-field configuration that every future reader must know about; omission is self-evident). Flux `HelmRelease` with HPA-aware chart logic (this app is not Helm-packaged).

---

## DD-4: Both probes on `/health`, and readiness does not check the Kubernetes API

**Decision.** Liveness and readiness probes both target `GET /health`, which is cheap, dependency-free, and intentionally never calls the Kubernetes API. It reports `secretLoaded` as a boolean (presence of `API_KEY`, never the value).

**Context.** The app's main endpoint (`/nodes`) depends on the Kubernetes API. A naive readiness probe would test that dependency.

**Why.** If readiness checked the Kubernetes API, a control-plane hiccup would mark every replica unready simultaneously and take the whole service out, converting a partial upstream degradation into a full outage. Instead, `/health` answers "is this process alive and able to serve" and `/nodes` itself returns 503 when the API is unavailable, so the failure is visible per-request without the probe amplifying it. Liveness on the same cheap endpoint avoids restart loops caused by external dependencies.

**Alternatives considered.** Readiness on a `/ready` that exercises the Kubernetes API (rejected for the cascade above). Separate liveness/readiness endpoints with different logic (nothing meaningful to differentiate for this process; one endpoint is less to maintain). Startup probe (unnecessary, the app starts in well under the initial delay).

---

## DD-5: Kustomize overlays, with JSON-patch renames for cluster-scoped RBAC

**Decision.** One base (`apps/backend/base`) plus three overlays (dev/staging/production). Overlays set the namespace, env config (APP_ENV, LOG_LEVEL), resources, HPA/PDB sizing, ingress host, ESO secret path and refresh interval, and the per-env IRSA role annotation. Each overlay renames the ClusterRole and ClusterRoleBinding via JSON patches (for example `terasky-backend-node-reader-dev`) and repoints the binding's `roleRef`.

**Context.** Three environments run on one cluster as three namespaces. The kustomize `namespace` transformer handles namespaced resources, but the RBAC pair is cluster-scoped.

**Why.** Cluster-scoped resource names must be unique cluster-wide; without the rename, the three overlays would collide on one ClusterRole/ClusterRoleBinding and the last-applied binding's subject would win. The JSON patch also rewrites `roleRef.name` (immutable in-cluster, so it must be correct at build time) and the overlay's namespace transformer rewrites the ServiceAccount subject namespace. Kustomize keeps this as plain, diffable YAML with no templating language.

**Alternatives considered.** Helm chart with values per env (templating power not needed for one app, and raw YAML is easier to review in an assignment). Three fully copied manifest trees (drift magnet). `nameSuffix` in kustomize (would rename every resource in the overlay, including namespaced ones that do not need it; targeted patches change only what must change).

---

## DD-6: Pod Security Admission `restricted` on all three namespaces

**Decision.** Each environment namespace carries `pod-security.kubernetes.io/enforce: restricted` (plus `audit` and `warn` at the same level).

**Context.** The workload already runs non-root (uid 10001), with seccomp `RuntimeDefault`, no privilege escalation, read-only root filesystem, and all capabilities dropped.

**Why.** PSA is built into the API server: zero components to install, and it fails closed at admission for the exact hardening the manifests already implement. It is a second, independent enforcement layer under Kyverno, so a policy-engine outage or misconfiguration does not silently open the namespaces. Labeling `enforce` (not just `warn`) is safe because every manifest in Git already complies.

**Alternatives considered.** PSA `baseline` (weaker, and nothing in the workload needs the exceptions). Kyverno only (single point of enforcement). OPA Gatekeeper (a second policy engine adds nothing PSA does not already provide here).

---

## DD-7: Kyverno ClusterPolicies in Enforce, scoped to the three app namespaces only

**Decision.** Six ClusterPolicies (`policies/kyverno/`) run with `validationFailureAction: Enforce`, matched only against namespaces `dev`, `staging`, `production`: require-run-as-non-root, disallow-privilege-escalation, require-resources, require-probes, disallow-latest-tag, restrict-image-registries (only `647604014014.dkr.ecr.eu-west-1.amazonaws.com`).

**Context.** Kyverno 3.9.0 is installed by Flux as a HelmRelease, single replica (demo sizing). Policies are tested with the Kyverno CLI (16 assertions over good/bad/untagged pod fixtures) in CI and locally.

**Why.** Enforce is justified because the three namespaces are fully owned by this project and every manifest in Git complies, so a rejection is always a genuine violation, never friction for a teammate. Scoping to the app namespaces means a policy rollout can never brick system controllers (kube-system, flux-system, kyverno, external-secrets stay out of scope). Demo trade-off, documented: the admission controller is single-replica and its webhook fails closed, so Kyverno downtime blocks pod admission in the three namespaces; production runs Kyverno with multiple replicas and a PDB.

**Alternatives considered.** `Audit` mode (produces reports nobody is forced to read; in a fully owned namespace, Enforce is strictly better). Cluster-wide scope with exclusions (an exclusion list is a standing risk of catching a system component; an inclusion list cannot). ValidatingAdmissionPolicy (CEL) (native, but Kyverno's test CLI and readable YAML policies fit the review-oriented context better).

---

## DD-8: Per-namespace SecretStore with per-environment IRSA roles

**Decision.** Each namespace gets its own ESO SecretStore (not a ClusterSecretStore) authenticating via `jwt` with that namespace's `eso-backend` ServiceAccount. Terraform creates one IAM role per environment (`terasky-demo-eso-<env>`), trust limited to `system:serviceaccount:<env>:eso-backend` on the cluster OIDC provider, permissions limited to `GetSecretValue`/`DescribeSecret` on that environment's secret ARN only.

**Context.** Secret values live in AWS Secrets Manager under `terasky/<env>/backend`. Terraform creates the secret containers; values are set out-of-band with `aws secretsmanager put-secret-value` so they never enter Terraform state or Git. ESO materializes them as the `backend-secrets` Kubernetes Secret; rotation propagates via `refreshInterval` (dev 1m for the rotation demo, otherwise 1h).

**Why.** This chain makes environment isolation structural rather than conventional: the dev namespace's ServiceAccount can assume only the dev role, which can read only the dev secret. A compromised dev pod cannot read production secrets even in principle, despite all three environments sharing a cluster. A ClusterSecretStore would concentrate one credential able to read every environment's secrets.

**Alternatives considered.** ClusterSecretStore with a single broad role (simpler, rejected on blast radius). Secrets Store CSI driver (mounts files, no native rotation-to-env-var story, and the ExternalSecret -> Secret -> `secretKeyRef` flow demos cleanly). Sealed Secrets (puts encrypted secret material in Git; Secrets Manager keeps values out of the repo entirely and gives rotation and audit).

---

## DD-9: Flux bootstrap with an SSH deploy key, not a PAT

**Decision.** `flux bootstrap github --path clusters/demo --token-auth=false`, so the cluster authenticates to the repo with a repository-scoped SSH deploy key rather than a stored personal access token.

**Context.** Flux needs read (and, during bootstrap, write) access to the Git repository. The GitRepository source pulls `ssh://git@github.com/NajeebShhadeTasks/terasky-home-assignment` on `main` every minute.

**Why.** A PAT stored in the cluster is a user-account credential: it carries whatever scopes it was minted with, usually across many repositories, and outlives its purpose. A deploy key is scoped to exactly this one repository and dies with it. The PAT used interactively during bootstrap never lands in the cluster with `--token-auth=false`.

**Alternatives considered.** `--token-auth=true` (PAT in-cluster, broader blast radius). GitHub App credentials for Flux (the strongest production option, more setup than a one-repo demo warrants). Pull-only public HTTPS access (would work for a public repo but removes Flux's ability to manage its own sync manifests at bootstrap, and breaks if the repo goes private).

---

## DD-10: CI-created deploy PRs instead of Flux image automation

**Decision.** After building and pushing an image, `build-push.yml` opens a pull request that updates the dev overlay's image tag via `kustomize edit set image`. Flux deploys only after the PR merges. Flux's image-automation controllers are not installed.

**Context.** The pipeline must never touch the cluster (no kubectl/helm anywhere in CI); Git is the only deployment interface.

**Why.** A PR is a visible, reviewable, revertible unit of deployment: the diff shows exactly which immutable tag enters which environment, the merge commit is the audit record, and rollback is `git revert`. Flux image automation commits directly to the branch, which bypasses review and hides deployments inside controller-generated commits. It would also add two controllers and an in-cluster write credential for the repo. Known limitation, documented honestly: PRs created with the workflow `GITHUB_TOKEN` do not trigger other workflows (a GitHub safeguard), so CI checks do not auto-run on bot-created deploy/promotion PRs. The solo-maintainer flow is admin review + merge; the production recommendation is a GitHub App installation token for CI-created PRs so checks run normally.

**Alternatives considered.** Flux ImageRepository/ImagePolicy/ImageUpdateAutomation (fully automatic, rejected for auditability and the extra in-cluster write credential). CI running `kubectl set image` (violates the GitOps boundary outright; cluster state would no longer equal Git). Direct push to `main` from CI (no review point at all).

---

## DD-11: Immutable `sha-` tags and enforced promotion chain

**Decision.** Images are tagged `sha-<7-char git sha>` in an ECR repository with tag immutability enabled. Promotion (`promote.yml`, mirrored by `scripts/promote.sh`) moves the same tag dev -> staging -> production, never rebuilding. The workflow rejects any tag not currently running in the source environment (staging accepts only what dev runs, production only what staging runs) and any non-`sha-*` tag; production promotion is additionally gated by the `production` GitHub environment with a required reviewer. The output is a PR only.

**Context.** ECR is configured immutable with scan-on-push and a lifecycle policy (untagged after 7 days, keep 15 `sha-*` images).

**Why.** An immutable content-addressed tag makes "what is running" a git-answerable question and makes promotion a metadata change rather than a rebuild, so the artifact that passed staging is byte-identical to the one entering production. The chain check turns the dev -> staging -> production path from a convention into a mechanical invariant: nobody can promote an untested tag to production, including by accident. Rollback is a git revert of the promotion commit; `kubectl set image` is break-glass only and must be re-reconciled with Git afterward.

**Alternatives considered.** Mutable environment tags like `:staging` (unanswerable "what exactly is deployed", and a re-push silently changes production). Rebuilding per environment (the promoted artifact is no longer the tested artifact). Semantic version tags (adds a release process this assignment does not need; the git sha is already the meaningful identity).

---

## DD-12: Reuse the account's existing GitHub OIDC provider

**Decision.** Terraform consumes the existing `token.actions.githubusercontent.com` IAM OIDC provider through a data source (`iam-github.tf`) instead of creating one, and never modifies it.

**Context.** AWS account 647604014014 already had a GitHub OIDC provider, created by an unrelated project.

**Why.** AWS permits one OIDC provider per URL per account, so creating a second is impossible and importing the existing one would put a shared, foreign-owned resource into this project's state (a later `terraform destroy` would delete it out from under the other project). A data source expresses the real relationship: this project trusts the provider but does not own it. All authorization scoping lives in this project's role trust policies, not in the shared provider.

**Alternatives considered.** `aws_iam_openid_connect_provider` resource (fails on the duplicate-URL constraint). Terraform `import` of the existing provider (ownership and destroy-hazard problem above). Stored AWS access keys in GitHub secrets (long-lived credentials, exactly what OIDC exists to eliminate; the repo stores zero AWS keys).

---

## DD-13: Trust both legacy and immutable OIDC subject formats

**Decision.** Both GitHub Actions roles trust two exact `sub` values per context, for example `repo:NajeebShhadeTasks/terasky-home-assignment:ref:refs/heads/main` and `repo:NajeebShhadeTasks@176375566/terasky-home-assignment@1344950844:ref:refs/heads/main`. Never `sub: *`.

**Context.** This is a debugging story, recorded so the fix is not mistaken for cargo cult. The first OIDC `AssumeRoleWithWebIdentity` from the build workflow failed with the trust policy written in the standard legacy format that virtually all documentation shows. Inspecting the repository's OIDC subject customization (`gh api repos/.../actions/oidc/customization/sub`) revealed a `sub_claim_prefix` of `repo:NajeebShhadeTasks@176375566/terasky-home-assignment@1344950844`: this GitHub account issues immutable subject claims that embed the numeric account and repository IDs.

**Why.** GitHub is rolling out immutable subject claims (the numeric IDs survive account and repo renames, closing a rename-hijack class of attack), and this account is already on them, so the legacy-only trust could never match. Trusting both exact strings makes the trust policy correct on this account today and portable to accounts still issuing legacy claims, with no wildcard. Both formats still pin the exact repository and ref/environment, so nothing is loosened.

**Alternatives considered.** Wildcarding the subject (`sub: repo:owner/*` or worse) (would have "fixed" the error by destroying the security property; rejected immediately). Trusting only the immutable format (breaks if GitHub's rollout state changes or the pattern is copied to a legacy-claim account). Disabling the subject customization on the repo (fights the platform's security direction to preserve an old string format).

---

## DD-14: Community Terraform modules for VPC and EKS, raw resources for the rest

**Decision.** `terraform-aws-modules/vpc/aws ~> 5.21` and `terraform-aws-modules/eks/aws ~> 20.37` build the network and cluster; ECR, Secrets Manager, and all IAM (GitHub roles, ESO roles) are raw `aws_*` resources. AWS provider `~> 5.100`, Terraform `>= 1.5.7`.

**Context.** The infra is one VPC, one EKS cluster with a managed node group and addons (including the VPC CNI with `enableNetworkPolicy=true`), IRSA, KMS secrets encryption, and control-plane logging.

**Why.** VPC and EKS are the two places where raw resources explode into hundreds of lines of subnet/route-table/security-group/access-entry wiring that the community modules encode correctly, including the subtle parts (IRSA provider, access entries, addon ordering via `before_compute`). Version-pinned with `~>`, they are reviewable and reproducible. Everything else stays raw because the resources are few and the details are the point: the IAM trust policies and secret ARN scoping are exactly what a reviewer should read line by line, not hidden behind a module interface.

**Alternatives considered.** All raw resources (maximum transparency, but the EKS wiring would dominate the diff and reimplement well-tested logic under time pressure). All modules including IAM (obscures the security-relevant policies this assignment is judged on). eksctl or CDK (different toolchains; the assignment context is Terraform).

---

## DD-15: S3 + DynamoDB remote state, bootstrapped by script

**Decision.** Remote state in S3 (`terasky-demo-tfstate-647604014014`, encrypted) with a DynamoDB lock table (`terasky-demo-tf-lock`), created once by `scripts/bootstrap-state.sh` outside Terraform.

**Context.** Terraform runs both locally and from CI (`terraform.yml`: plan on PRs, apply only via workflow_dispatch behind the `production` environment approval).

**Why.** Two runners (laptop and CI) sharing local state is how state gets forked or lost; remote state with locking makes concurrent runs safe and the state durable. The bucket and lock table are bootstrapped by script because of the chicken-and-egg problem: the backend must exist before `terraform init` can use it, so state storage cannot manage itself. The account ID in the bucket name guarantees global uniqueness.

**Alternatives considered.** Local state (single-operator only, no CI story). Terraform Cloud (an external dependency and account for a self-contained assignment). Managing the state bucket in the same Terraform root (circular; a second bootstrap root just relocates the same problem for two resources a 30-line script creates idempotently).

---

## DD-16: Single NAT gateway

**Decision.** One NAT gateway for both private subnets (`single_nat_gateway = true`).

**Context.** Demo cost trade-off, explicit. Nodes live in private subnets across two AZs and need egress for image pulls (ECR), AWS APIs, and GitHub. A NAT gateway costs about $0.048/hour plus data, roughly $32/month each; the whole running demo is about $8/day.

**Why.** For a cluster that exists for days and serves a demo, a second NAT buys resilience against an AZ outage of the NAT's AZ, which is not a risk worth ~$32/month here. The trade-off is stated in the code comment where it is made. Production recommendation: one NAT per AZ so an AZ failure does not sever egress for the surviving AZ, or VPC endpoints for ECR/S3/STS to take most traffic off NAT entirely (which also reduces data processing cost).

**Alternatives considered.** NAT per AZ (the production answer, double the cost for no demo benefit). VPC endpoints only (ECR/S3/STS endpoints cover the cluster's own traffic but not arbitrary HTTPS egress such as GitHub for Flux). Public subnets for nodes (rejected outright; nodes stay private).

---

## DD-17: 2x t3.large managed nodes

**Decision.** One managed node group, `t3.large`, AL2023, on-demand, min 2 / desired 2 / max 3.

**Context.** The cluster runs the Flux controllers, ESO, Kyverno, metrics-server, and three environments of a small app (HPA floors: dev 1, staging 2, production 3), with pod anti-affinity preferring to spread app replicas across nodes.

**Why.** Two nodes is the minimum that makes the multi-node story real: `/nodes` shows something worth marking, anti-affinity has somewhere to spread to, and a node drain does not take down every replica at once. t3.large (2 vCPU, 8 GiB) fits the controller overhead plus all three environments with headroom at roughly $0.18/hour for the pair; smaller burstable types get memory-tight once Kyverno and ESO are running. Max 3 leaves the node group room if the HPAs scale out.

**Alternatives considered.** t3.medium (4 GiB gets tight under the controller stack plus three namespaces). m5.large (similar shape, higher price, no burst credits; nothing here needs sustained full CPU). Spot capacity (cheaper, but an interruption during the live demo or interview is a bad trade). Karpenter (more capable autoscaling, unjustifiable setup for a fixed two-node demo).

---

## DD-18: Public repository

**Decision.** The repository (`github.com/NajeebShhadeTasks/terasky-home-assignment`) is public.

**Context.** This is a home assignment: reviewers must be able to read it without access provisioning. The repo contains no secret values by construction (DD-8: secret values are set out-of-band and never enter Git or Terraform state; the app reports only a `secretLoaded` boolean).

**Why.** Zero-friction review, and it forces the hygiene the repo claims: everything in it must be safe to publish. What is visible (account ID, role names, ECR registry hostname) is identifier, not credential; none of it grants access. The OIDC trust policies pin exact repository identity and refs (DD-13), so a fork or a stranger's workflow cannot assume the roles, and the Flux deploy key is read-scoped to this one repo.

**Alternatives considered.** Private repo with reviewer invites (access friction, and it invites the sloppy assumption that "private" excuses committed secrets). Public repo with the Terraform in a private sibling (splits the story the assignment is meant to tell in one place).
