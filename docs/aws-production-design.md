# AWS Production Architecture Design

This document describes how the platform in this repository would be run in production, and contrasts it with what the demo actually deploys. The demo (account 647604014014, region eu-west-1, prefix `terasky-demo`) is a deliberately cost- and time-boxed version of the same design. Every section states the demo reality first, then the production recommendation. A summary table at the end maps each topic.

The guiding rule: nothing in the demo is architecturally incompatible with the production design. The trade-offs are sizing, redundancy, and account topology, not structure.

## 1. EKS architecture

**Demo:** One EKS cluster `terasky-demo`, Kubernetes 1.33, created by `terraform-aws-modules/eks ~> 20.37` (`infra/terraform/main.tf`). One managed node group, 2x t3.large (min 2, max 3), AL2023 AMIs, on-demand, in private subnets. Access entries (`authentication_mode = "API"`), no aws-auth ConfigMap. Control-plane logs `api`, `audit`, `authenticator` to CloudWatch. IRSA enabled. VPC CNI addon with `enableNetworkPolicy = "true"` so NetworkPolicy objects are actually enforced. The API endpoint is public so the assignment can be driven from a laptop.

**Production:**
- Private-only API endpoint, reached via VPN or a bastion in the VPC (or `cluster_endpoint_public_access_cidrs` locked to office egress IPs as an intermediate step).
- Separate node groups (or Karpenter NodePools, section 18) for system workloads vs application workloads, with taints so critical addons are not evicted by app churn.
- All control-plane log types enabled (`api`, `audit`, `authenticator`, `controllerManager`, `scheduler`).
- A defined Kubernetes version upgrade cadence: EKS supports each minor for roughly 14 months of standard support; upgrade one minor at a time, addons first in a non-prod cluster.
- One cluster per environment (section 12); the demo's three-namespaces-in-one-cluster layout is the compromise, not the design.

## 2. Multiple availability zones

**Demo:** Two AZs (`main.tf` slices the region's AZ list to 2), the minimum for high availability. Private and public subnets exist in both; the node group spans both; the app uses preferred pod anti-affinity across hostnames plus a PDB so replicas spread and survive a single-node drain.

**Production:** Three AZs. With two AZs, losing one halves capacity and can leave etcd-style quorum-shaped workloads (or any 2-replica deployment with `minAvailable: 1`) one failure from outage. Three AZs also let ALB and NAT redundancy work as intended. Use topology spread constraints (`topology.kubernetes.io/zone`) in addition to hostname anti-affinity so replicas spread across zones, not just nodes.

## 3. Public and private subnets

**Demo:** Standard two-tier VPC (`terraform-aws-modules/vpc ~> 5.21`, CIDR 10.60.0.0/16): public subnets hold only the NAT gateway (and would hold internet-facing ALBs), private subnets hold all nodes. Subnets carry the `kubernetes.io/role/elb` and `kubernetes.io/role/internal-elb` discovery tags so the AWS Load Balancer Controller can place load balancers correctly when installed.

**Production:** Same structure, three AZs. Size private subnets generously (a /20 or larger per AZ): the VPC CNI assigns a routable IP per pod, and undersized subnets are the classic EKS scaling wall. Consider secondary CIDR blocks or IPv6 for pod addressing at scale. Nothing except load balancers and NAT ever lives in public subnets.

## 4. Private worker nodes

**Demo:** Already done properly. Nodes have no public IPs, live in private subnets, and reach the internet (ECR, GitHub, Helm repos) only through the NAT gateway. This is not a demo shortcut; it is the production posture.

**Production:** Keep it, and reduce even NAT exposure by routing ECR, S3, STS, Secrets Manager, and CloudWatch traffic over VPC endpoints (section 19). Restrict node security groups to cluster-required traffic (the EKS module defaults are a good baseline). No SSH key pairs on nodes; use SSM Session Manager for break-glass node access.

## 5. Ingress: ALB and the AWS Load Balancer Controller

**Demo:** The Ingress manifest ships in `apps/backend/base/ingress.yaml` (class `alb`, internet-facing, `target-type: ip`, HTTPS 443, per-env host patched in the overlays), but the AWS Load Balancer Controller is **not installed**, because there is no registered domain and the assignment is time-boxed. The manifest applies cleanly and simply receives no address. Demo access is `kubectl port-forward`.

**Production:** Install the AWS Load Balancer Controller (Helm, IRSA role with the controller's published IAM policy). Path: client -> Route53 -> ALB (ACM TLS termination) -> `target-type: ip` directly to pod IPs -> Service -> pods. Use `internet-facing` only for genuinely public services; internal services get `internal` scheme ALBs in private subnets. Add WAF (AWS WAFv2 web ACL association) on the public ALB and enable ALB access logs to S3.

## 6. Route53

**Demo:** Not used; no domain. The overlay hostnames (`backend.dev.terasky-demo.example.com` etc.) are placeholders.

**Production:** A public hosted zone for the product domain, with per-environment subdomains delegated to per-environment accounts (e.g. `dev.example.com` zone in the dev account, delegated by NS records from the parent zone in a shared network/DNS account). Alias A records to the ALBs, either managed by external-dns (IRSA-scoped to the one zone) or by Terraform. Health-checked failover routing only if multi-region is adopted (section 20).

## 7. TLS and ACM

**Demo:** No certificates (no domain). The Ingress annotations are already written for ACM discovery: `listen-ports: [{"HTTPS":443}]` with the certificate ARN intentionally omitted so the Load Balancer Controller discovers the certificate from ACM by hostname.

**Production:** ACM public certificates per environment domain, DNS-validated against the Route53 zone (validation records managed by Terraform so renewal is automatic and hands-off). TLS 1.2 minimum on ALB security policy. ACM certificates never expire unattended because DNS validation auto-renews; that is the main reason to prefer ACM over imported certificates.

## 8. IAM

**Demo:** Small and least-privilege by construction:
- `terasky-demo-gha-ecr`: GitHub Actions role that can authenticate to ECR and push/pull only the one project repository; trusted only for `main` of this exact repo.
- `terasky-demo-gha-terraform`: PowerUserAccess plus IAM actions scoped to the `terasky-demo-*` prefix (create/delete/tag roles and policies, PassRole) so it cannot touch IAM entities of anything else in the account; trusted for PRs (plan), `main` (plan), and the protected `production` GitHub environment (apply).
- `terasky-demo-eso-{dev,staging,production}`: per-environment IRSA roles for External Secrets, each able to read exactly one secret ARN.
- Zero stored AWS access keys anywhere; GitHub->AWS is OIDC only, reusing the account's existing OIDC provider via a data source. Trust policies pin both the legacy and the immutable GitHub subject formats exactly (never `sub: *`).

**Production:**
- Per-environment accounts make most prefix-scoping unnecessary: the Terraform role in the dev account simply cannot reach production (section 12).
- Replace PowerUserAccess on the Terraform role with a policy enumerating the services the stacks actually manage, plus a permissions boundary.
- Human access via IAM Identity Center (SSO) with short-lived sessions; no IAM users.
- Service control policies at the organization level: deny leaving the region set, deny disabling CloudTrail/GuardDuty, deny IAM user creation.
- IAM Access Analyzer and credential reports as standing hygiene.

## 9. Workload identity: IRSA vs EKS Pod Identity

**Demo:** IRSA. Each namespace's `eso-backend` ServiceAccount is annotated with its per-env role ARN; the role trust is the cluster OIDC provider with `sub` pinned to `system:serviceaccount:<env>:eso-backend`. The pattern (per-namespace SecretStore, not ClusterSecretStore) means a compromised dev namespace cannot read staging or production secrets even in the shared demo cluster.

**Production:** Either works; the isolation model carries over unchanged.
- **EKS Pod Identity** is the newer mechanism: no OIDC provider per cluster in IAM trust policies, role associations are an EKS API call, and roles are reusable across clusters without editing trust policies. Prefer it for new clusters where every consuming component supports it.
- **IRSA** remains required for some third-party controllers and for cross-account assume patterns those controllers expect. External Secrets, the Load Balancer Controller, and Karpenter all support both today.
- Recommendation: Pod Identity by default for new production clusters, IRSA where a component requires it. Never node-instance-profile permissions for workloads.

## 10. ECR

**Demo:** One repository `terasky-demo/backend`: immutable tags (a pushed `sha-<gitsha>` can never be overwritten, which is what makes Git-based promotion and rollback trustworthy), scan-on-push, AES256 encryption, lifecycle policy (expire untagged after 7 days, keep last 15 `sha-*` images), `force_delete = true` as a teardown convenience. The same immutable image digest is promoted dev -> staging -> production, never rebuilt.

**Production:**
- Keep tag immutability and the sha-tag promotion model exactly as-is.
- Host ECR in a central shared-services account; grant per-environment accounts pull via repository policies. Build once, pull everywhere.
- KMS (CMK) encryption instead of AES256 for auditable key control.
- Enhanced scanning (Inspector) with findings routed to the security team, not just scan-on-push.
- Longer retention in the lifecycle policy (production must retain every tag still referenced by Git history within the rollback window), and no `force_delete`.
- Optionally cross-region replication for the DR region (section 20).

## 11. Secrets Manager

**Demo:** Terraform creates only the secret **containers** `terasky/{dev,staging,production}/backend`; values are set out-of-band with `aws secretsmanager put-secret-value` so they never appear in Terraform state, plan output, or Git. External Secrets Operator (per-namespace SecretStore, IRSA-authenticated) materializes them as Kubernetes Secrets; rotation is demonstrated by updating the value and letting ESO's `refreshInterval` (1m in dev, 1h elsewhere) pick it up. `recovery_window_in_days = 0` for instant teardown.

**Production:**
- Same container-only Terraform pattern; it is correct.
- Default 30-day recovery window (delete protection), CMK encryption per environment.
- Native Secrets Manager rotation Lambdas for credentials that support it (database credentials especially); ESO propagates rotated values automatically.
- Secrets live in the same account as the workload that consumes them (per-env accounts), so IAM scoping is structural, not string-matched.
- Resource policies denying access from outside the owning account/roles, and CloudTrail data events on secret reads for audit.

## 12. Environment and account separation

**Demo:** One AWS account, one cluster, three namespaces (dev/staging/production) with PSA `enforce=restricted`, per-namespace NetworkPolicy, per-namespace IRSA/secret scoping, and per-env Kyverno-policed admission. This is an explicit cost/time trade-off, and the per-namespace isolation work (secrets, RBAC, network) was done as if the namespaces were hostile to each other.

**Production:** AWS Organizations with one account per environment (at minimum: production isolated in its own account), plus a management account, a security/log-archive account, and a shared-services account (ECR, CI roles, central DNS):
- Blast radius: a compromised dev credential or a bad Terraform apply cannot touch production by construction.
- Independent service quotas, cost boundaries, and CloudTrail/GuardDuty per account.
- Separate clusters per environment, so cluster upgrades and addon changes rehearse in dev/staging on genuinely identical infrastructure before production.
- The Flux layout in this repo already supports it: `clusters/demo` becomes `clusters/dev`, `clusters/staging`, `clusters/production`, each bootstrapped into its own cluster, each pointing at the corresponding overlay.

## 13. Kubernetes audit logs

**Demo:** Enabled. Control-plane logging ships `api`, `audit`, and `authenticator` streams to CloudWatch Logs (`cluster_enabled_log_types` in `main.tf`), so every API request against the demo cluster is recorded.

**Production:** Keep audit logging on everywhere, add `controllerManager` and `scheduler`, set explicit CloudWatch retention (for example 13 months) or export to the log-archive account's S3 for long-term retention. Alert on high-signal events: exec/attach into pods, secrets read by unexpected principals, RBAC changes, access-entry changes. Feed the streams into the SIEM alongside CloudTrail.

## 14. CloudTrail

**Demo:** No project-managed trail. The account's default 90-day CloudTrail event history exists, and it was actually used during the build (verifying which OIDC subject format GitHub sent when the first AssumeRole failed), but nothing durable is configured by this repo.

**Production:** An organization trail (all accounts, all regions) delivering to a locked-down S3 bucket in the log-archive account: KMS-encrypted, log file validation enabled, MFA-delete/object-lock on the bucket, SCP denying trail modification. Management events everywhere; data events at least for the Terraform state bucket and Secrets Manager. GuardDuty (with the EKS audit-log source) and Security Hub consume it organization-wide.

## 15. Encryption at rest

**Demo:**
- EKS secrets: envelope-encrypted with a KMS key (EKS module default encryption config for the `secrets` resource).
- Terraform state: S3 with `encrypt = true`.
- ECR: AES256.
- EBS node volumes: provider defaults.
- Secrets Manager: AWS-managed key.

**Production:** Customer-managed KMS keys (CMKs) per environment for EKS secrets, EBS (account-level "EBS encryption by default" plus a CMK), ECR, S3 buckets, CloudWatch log groups, and Secrets Manager. CMKs give key rotation control, usage audit via CloudTrail, and the ability to revoke access cleanly. Key policies grant use to the specific roles, not the account root shortcut.

## 16. Encryption in transit

**Demo:** kubectl/API traffic, ESO -> Secrets Manager, CI -> AWS, and Flux -> GitHub (SSH) are all TLS/SSH already. The hop that is plain HTTP is inside the cluster: Service -> pod on port 8000, and there is no ALB at all (port-forward).

**Production:** TLS 1.2+ terminated at the ALB with ACM certificates (sections 5-7). For in-cluster encryption and workload-to-workload mTLS, adopt a service mesh or CNI-level encryption only if a compliance requirement demands it; for this app's profile, ALB termination plus NetworkPolicy segmentation is the right default, and mesh complexity is documented as opt-in, not baseline.

## 17. Backups and restore: Velero and EBS snapshots

**Demo:** No backup tooling, and deliberately so: the workload is stateless. Everything on the cluster is reconstructible from Git (Flux re-applies it) and everything in AWS from Terraform; secrets live in Secrets Manager, not only in the cluster. The only unmanaged state is the Terraform state file itself, which sits in S3 (versioning via the bootstrap script's bucket).

**Production:**
- **Velero** installed via IRSA/Pod Identity, backing up cluster API objects to S3 and volume data via EBS CSI snapshots, on a schedule (for example hourly incremental volume snapshots, daily full object backups) with retention tiers.
- **EBS snapshots** additionally governed by AWS Backup or Data Lifecycle Manager policies at the account level, cross-account-copied to the log-archive/backup account so a compromised workload account cannot delete its own backups.
- Even in a GitOps world Velero earns its place: it captures what Git does not (PVC data, generated Secrets, controller-written status/state) and makes cluster rebuild a restore, not an archaeology exercise.
- **Restore is a practiced operation, not a document**: scheduled game-days restoring into a scratch cluster, with the restore time measured against the RTO target (section 20). An untested backup is a hypothesis.

## 18. Scaling: HPA plus Karpenter vs Cluster Autoscaler

**Demo:** Pod-level scaling is real: HPA per environment (dev 1-3, staging 2-4, production 3-6, CPU 70%) against metrics-server, and the Deployment deliberately omits `spec.replicas` so Flux never fights the HPA. Node-level scaling is not: the managed node group is min 2 / max 3 with no autoscaler installed, so `max_size` only permits manual scaling.

**Production:** Keep HPA for pods (add memory or custom metrics where CPU is a poor proxy). For nodes, **Karpenter is the recommendation over Cluster Autoscaler**:
- Karpenter provisions right-sized instances directly from pending-pod requirements in seconds, instead of stepping predefined ASGs up and down.
- Flexible instance-type and capacity-type selection per NodePool makes the Spot strategy (section 19) declarative.
- Consolidation actively bin-packs and retires underutilized nodes, which Cluster Autoscaler does far more conservatively.
- Cluster Autoscaler remains reasonable where ASG-based uniformity is mandated or the team already operates it well, but for a new EKS build Karpenter is the better default.
- Run Karpenter's controller itself on a small static managed node group (or Fargate) so the autoscaler never depends on capacity it manages.

## 19. Cost

**Demo:** Roughly $8/day while running: EKS control plane ~$0.10/h, 2x t3.large ~$0.18/h, single NAT gateway ~$0.048/h plus data processing, EBS negligible. Cost-driven choices already made: 2 AZs, single NAT, single-replica demo sizing for controllers, ECR lifecycle policy, `terraform destroy` teardown when idle.

**Production:**
- **Spot for non-production**: dev and staging node capacity on Spot via Karpenter NodePools (diverse instance types, on-demand fallback), commonly 60-90% off on-demand. Production stays on-demand/reserved for the baseline, with Spot only for interruption-tolerant workloads.
- **Savings Plans**: Compute Savings Plans covering the measured steady-state production baseline (start around 1-year no-upfront, tune with Cost Explorer coverage reports).
- **NAT costs**: one NAT per AZ in production (availability), but cut the bill the correct way: **VPC endpoints**. S3 and DynamoDB gateway endpoints are free; interface endpoints for ECR (api + dkr), STS, Secrets Manager, CloudWatch Logs, and EC2 remove the bulk of per-GB NAT processing, since image pulls are usually the dominant NAT traffic on EKS.
- Tag-based cost allocation (`Project`, `Environment` are already default-tagged by the Terraform provider) and per-account billing boundaries from the Organizations layout.

## 20. Disaster recovery: RTO, RPO, multi-AZ vs multi-region

**Demo:** Single region, two AZs. DR story is "rebuild from source": Git holds all cluster config, Terraform holds all infrastructure, Secrets Manager holds secret values. Effective RPO for configuration is ~0 (Git); RTO is the time to run bootstrap + terraform apply + flux bootstrap + image push, realistically an hour or two, and it has effectively been rehearsed once, because that is how the demo was built.

**Production:**
1. **Set targets first.** RTO (how long until service is restored) and RPO (how much data loss is acceptable) are business decisions per workload; the architecture is chosen to meet them, not the reverse.
2. **Multi-AZ is the default and is not DR.** Three AZs (section 2) absorb instance and zone failure transparently. Region failure is a different event class.
3. **Multi-AZ vs multi-region trade-off:** multi-region roughly doubles infrastructure cost and adds real engineering weight (data replication, ECR replication, Route53 failover, config drift between regions, regular failover testing without which the second region is fiction). AWS regional outages are rare. For a stateless service like this one, a **pilot-light** posture usually hits sensible targets (for example RTO 4h / RPO 1h) at a fraction of active-active cost: Terraform modules already region-parameterized, ECR cross-region replication on, Velero backups copied cross-region, state and backups in cross-region-replicated S3, and a documented, periodically executed runbook that stands the stack up in the second region. Full active-active multi-region is justified only when the business quantifies downtime cost above the (large) standing cost of the second region.
4. **Measure, don't assume:** DR game-days that actually execute the runbook, with the measured times fed back into the stated RTO/RPO.

## Summary table

| Topic | Demo state | Production recommendation |
|---|---|---|
| EKS architecture | 1 cluster v1.33, 1 managed node group (2x t3.large), public API endpoint, access entries, IRSA, 3 log types | Cluster per environment, private endpoint + VPN/bastion, separated system/app node capacity, all 5 log types, planned upgrade cadence |
| Availability zones | 2 AZs | 3 AZs, zone topology spread constraints |
| Subnets | Public/private two-tier VPC, LBC discovery tags in place | Same structure, 3 AZs, larger private subnets (pod IP headroom) |
| Worker nodes | Private subnets, no public IPs (production posture already) | Keep; add VPC endpoints, SSM-only node access |
| Ingress (ALB/LBC) | Ingress manifests ship; LBC not installed (no domain); access via port-forward | Install AWS Load Balancer Controller; Route53 -> ACM -> ALB -> pods; WAF + access logs |
| Route53 | Not used (placeholder hostnames) | Hosted zones per env account, delegated subdomains, external-dns or Terraform records |
| TLS / ACM | None (no domain); annotations ready for ACM discovery | DNS-validated ACM certs per env, auto-renewing, TLS 1.2+ at ALB |
| IAM | OIDC-only CI roles (ECR-scoped; Terraform prefix-scoped), per-env ESO roles, zero stored keys | Per-account isolation replaces prefix scoping, enumerated policies + permission boundaries, Identity Center, SCP guardrails |
| Workload identity | IRSA (per-namespace SA -> per-env role -> one secret ARN) | EKS Pod Identity by default, IRSA where components require it; never node instance profiles |
| ECR | Immutable tags, scan-on-push, AES256, lifecycle policy, force_delete | Central shared-services registry, CMK encryption, enhanced scanning, longer retention, no force_delete, optional cross-region replication |
| Secrets Manager | TF creates containers only; values out-of-band; ESO + IRSA; 0-day recovery window | Same pattern; 30-day recovery window, CMKs, rotation Lambdas, per-account secrets, data-event auditing |
| Environment separation | 1 account, 1 cluster, 3 hardened namespaces (explicit trade-off) | AWS Organizations, account per env (prod isolated at minimum), cluster per env, shared-services + log-archive accounts |
| Kubernetes audit logs | Enabled (api/audit/authenticator -> CloudWatch) | Keep everywhere, all log types, retention policy, alerting on exec/RBAC/secret events, SIEM integration |
| CloudTrail | Account default 90-day event history only; no project trail | Organization trail to locked log-archive S3, KMS + validation, data events for state bucket and secrets, GuardDuty/Security Hub |
| Encryption at rest | EKS secrets via KMS, S3 state encrypted, ECR AES256, default EBS/Secrets Manager keys | CMKs per environment for EKS, EBS-by-default, ECR, S3, logs, Secrets Manager |
| Encryption in transit | TLS/SSH on all external hops; in-cluster HTTP; no ALB (port-forward) | ACM TLS at ALB; mesh/mTLS only if compliance requires |
| Backups / restore | None (stateless; Git + Terraform + Secrets Manager are the sources of truth) | Velero (objects + EBS CSI snapshots) on schedule, AWS Backup policies, cross-account snapshot copies, rehearsed restore game-days |
| Scaling | HPA per env (replicas omitted from Deployment for Flux/HPA coexistence); fixed node group, no node autoscaler | Keep HPA; Karpenter (recommended over Cluster Autoscaler) for right-sized just-in-time nodes and consolidation |
| Cost | ~$8/day; 2 AZs, single NAT, destroy when idle | Spot via Karpenter for non-prod, Compute Savings Plans for prod baseline, NAT per AZ plus VPC endpoints to cut NAT data charges |
| Disaster recovery | Single region; rebuild-from-Git-and-Terraform (config RPO ~0, RTO hours) | Business-defined RTO/RPO; 3-AZ default; pilot-light second region for stateless tiers; DR runbook executed on game-days |
