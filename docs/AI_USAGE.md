# AI Usage Statement

I used AI assistance (Claude) while building this assignment. This page states plainly what it was used for, what it was not used for, and how I verified the results.

## How AI was used

AI acted as an accelerator and a review partner, not as the author of record. The main areas:

- **Repository scaffolding.** Initial layout of the repo (Terraform module structure, Kustomize base plus overlays, Flux directory structure) was drafted with AI and then adjusted by hand as the design evolved.
- **Boilerplate.** First drafts of Kubernetes manifests, Terraform resource blocks, Kyverno policies, and GitHub Actions workflows. These are verbose, well-known formats where generation saves time and the review cost is low.
- **Documentation drafting.** The docs in this repo were drafted with AI from the actual code and my design decisions, then edited and fact-checked against the repo and the live cluster.
- **Debugging partner.** Rubber-ducking failures and reading error output. One concrete example: the first GitHub Actions OIDC AssumeRole failed because this GitHub account issues immutable OIDC subject claims, so a trust policy written for the legacy `repo:org/repo:ref` subject format did not match. Working through the STS error and the token claims led to the fix (trusting both the exact legacy and immutable subject formats, never a wildcard subject).
- **Design review.** Asking for counterarguments to my own choices (for example, why the Deployment omits `spec.replicas` when an HPA owns the count, and why the readiness probe deliberately does not depend on the Kubernetes API).

## What required human judgment regardless

Some things cannot be delegated, and were not:

- **AWS account safety.** Everything touching a real account (IAM trust policies, reusing the account's existing OIDC provider without modifying it, `terraform apply`, secret values set out-of-band) was reviewed line by line and executed by me, not pasted blind.
- **Trade-off decisions.** Single NAT gateway, public EKS endpoint, one cluster with three namespaces, Enforce-mode Kyverno, no ALB controller on the demo cluster. These are cost and time trade-offs I chose and can defend, with the production alternative documented in each case.
- **What to actually deploy.** Scope decisions (what ships to the cluster versus what stays as documented design, such as the monitoring stack) were mine.
- **Verification against reality.** Every claim in these docs was checked against the live cluster and CI, not against generated text.

## How everything was verified

Nothing generated was trusted as-is. Every file was reviewed and then exercised:

- `pytest` (8/8) and `ruff` clean, run locally and in CI
- `terraform fmt`, `validate`, `plan` reviewed, then applied (73 resources, clean first apply)
- `kustomize build` on all overlays validated with kubeconform
- `kyverno test` 16/16 assertions against good and bad fixtures
- Trivy filesystem scan clean at HIGH/CRITICAL
- Live cluster checks: nodes Ready, Flux Kustomizations and HelmReleases reconciled, RBAC verified with positive and negative `kubectl auth can-i` checks (`scripts/verify.sh`)
- CI iterated until green, including fixing the OIDC trust issue above

## What was not done

No credentials, secret values, or account-sensitive material were shared with the AI beyond what appears in this public repo. No AI-generated claim was published without being executed or checked. I understand every design decision in this repo and can explain or change any of it without assistance.
