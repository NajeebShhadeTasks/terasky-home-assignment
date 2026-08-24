# Demo Runbook

A 5-minute guided walkthrough of the live cluster. The core idea to state up front: **Git is the desired state, Flux continuously reconciles actual state back to it**. Nothing in this demo deploys from a laptop or from CI; everything the cluster runs was pulled from this repository.

`scripts/demo.sh` runs the same sequence interactively (each step waits for Enter). This document is the annotated version with expected output.

## Prerequisites

```bash
# 1. Authenticated AWS CLI (account 647604014014, region eu-west-1)
aws sts get-caller-identity

# 2. Kubeconfig for the demo cluster
aws eks update-kubeconfig --region eu-west-1 --name terasky-demo

# 3. Flux CLI (for reconcile/status commands)
flux version --client
```

Also needed: `kubectl`, `curl`, `git`, `python3` (only for pretty-printing JSON).

## The 5-minute demo

### 1. Cluster and GitOps state

```bash
kubectl get nodes
```

Expected: 2 nodes, `Ready`, version `v1.33.x`.

```text
NAME                                        STATUS   ROLES    AGE   VERSION
ip-10-60-x-x.eu-west-1.compute.internal      Ready    <none>   ..    v1.33.x
ip-10-60-y-y.eu-west-1.compute.internal      Ready    <none>   ..    v1.33.x
```

```bash
flux get kustomizations -A
```

Expected: `flux-system`, `infra-controllers`, `infra-configs`, `backend-dev`, `backend-staging`, `backend-production`, all `Ready: True`, each showing `Applied revision: main@sha1:<commit>`. That commit hash is the proof point: the cluster state is pinned to a Git revision.

### 2. Application pods across the three environments

```bash
kubectl get pods -A -l app.kubernetes.io/name=terasky-backend -o wide
```

Expected: pods `Running` in `dev`, `staging`, and `production` namespaces, spread across both nodes (preferred podAntiAffinity), replica counts controlled by each environment's HPA (dev min 1, staging min 2, production min 3).

### 3. The application endpoints

```bash
kubectl port-forward -n dev svc/backend 18080:80 &
sleep 3

curl -s http://127.0.0.1:18080/health | python3 -m json.tool
```

Expected:

```json
{
    "status": "ok",
    "environment": "dev",
    "secretLoaded": true
}
```

`secretLoaded: true` proves the External Secrets Operator pulled the secret from AWS Secrets Manager into the container environment. It reports presence only, never the value.

```bash
curl -s http://127.0.0.1:18080/nodes | python3 -m json.tool
```

Expected: both nodes listed with `name`, `ready`, `current`, `kubeletVersion`, `architecture`, `os`; exactly one has `"current": true`. Cross-check it:

```bash
kubectl get pods -n dev -o wide
```

The `NODE` column for the backend pod matches `currentNode` in the JSON (the pod knows its node from the Downward API, `spec.nodeName`).

```bash
curl -s http://127.0.0.1:18080/metrics | grep http_requests_total | head
```

Expected: Prometheus counters labeled by method/path/status, plus `http_request_duration_seconds` histograms.

### 4. Least-privilege RBAC, positive and negative

```bash
kubectl auth can-i list nodes --as=system:serviceaccount:dev:backend
# yes

kubectl auth can-i delete pods -n dev --as=system:serviceaccount:dev:backend
# no

kubectl auth can-i get secrets -n dev --as=system:serviceaccount:dev:backend
# no
```

The `backend` ServiceAccount holds one ClusterRole (`terasky-backend-node-reader-dev`) granting `get`/`list` on `nodes` and nothing else. It is a ClusterRole because nodes are cluster-scoped, so a namespaced Role cannot grant access to them. `scripts/verify.sh` runs a fuller negative matrix (secrets, deployments, node deletion, clusterrole creation, watch).

### 5. Drift correction

```bash
# Introduce drift: hand-edit the live Deployment (not via Git)
kubectl set env deployment/backend -n dev DRIFT_DEMO=manual-change

# Show the drift landed
kubectl get deployment backend -n dev \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
# ... DRIFT_DEMO ... appears in the list

# Force Flux to reconcile now instead of waiting for the interval
flux reconcile kustomization backend-dev --with-source

sleep 5
kubectl get deployment backend -n dev \
  -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
# DRIFT_DEMO is gone: the Deployment matches Git again
```

**Why an env var and not `kubectl scale`?** This is deliberate, and worth saying out loud in the interview. The Deployment manifest intentionally omits `spec.replicas` because the HPA owns the replica count; if Git declared a replica count, every Flux reconcile would fight the HPA and revert its scaling decisions (flapping). The flip side: since Git does not manage replicas, a `kubectl scale` "drift" would be corrected by the **HPA**, not by Flux, which muddies the story. An env-var change is unambiguous: only Flux reverts it, so the revert demonstrates exactly the Git-to-cluster reconciliation loop.

### 6. Secret rotation (dev, ~1 minute)

Dev's ExternalSecret uses `refreshInterval: 1m` specifically to make this demonstrable live (staging/production use 1h).

```bash
# Rotate the value in AWS Secrets Manager. Never echo secret values.
aws secretsmanager put-secret-value \
  --secret-id terasky/dev/backend \
  --secret-string '{"apiKey":"'"$(openssl rand -hex 16)"'"}' \
  --query VersionId --output text

# Note the current Kubernetes Secret version, then wait ~60s
kubectl get secret backend-secrets -n dev -o jsonpath='{.metadata.resourceVersion}'; echo
sleep 65
kubectl get secret backend-secrets -n dev -o jsonpath='{.metadata.resourceVersion}'; echo
# resourceVersion changed: ESO picked up the new value

kubectl get externalsecret backend -n dev
# READY True, recent refresh

curl -s http://127.0.0.1:18080/health | python3 -m json.tool
# still {"status": "ok", ..., "secretLoaded": true}
```

No value is ever printed, committed, or stored in Terraform state; only the rotation mechanics are shown. (Running pods keep their injected env until the next rollout; the rotated value reaches new pods. A checksum annotation or Reloader would force an immediate rollout; documented trade-off, not needed for the demo.)

### 7. Promotion history and rollback

```bash
# History: promotion commits touch only the overlay kustomizations
git log --oneline -10 -- apps/backend/overlays

# The same immutable image tag moves dev -> staging -> production
grep -r newTag apps/backend/overlays/*/kustomization.yaml
```

Expected: each overlay pins `newTag: sha-<gitsha>`; staging and production only ever hold a tag that dev (respectively staging) already ran. The image is never rebuilt between environments.

Rollback is a Git operation:

```bash
git revert <promotion-commit>
git push
flux reconcile kustomization backend-production --with-source
```

Flux reconciles the cluster back to the previous pinned tag. `kubectl set image` is break-glass only: if used in an emergency, Git must be updated to match afterward, otherwise the next reconcile reverts the hand-rolled change (which is the system working as designed).

## Scripted version

```bash
./scripts/demo.sh     # the sequence above, step by step, Enter between steps
./scripts/verify.sh   # full read-only verification: Flux, ESO, RBAC matrix, endpoints
```

## Cleanup

See the cleanup section in the [README](../README.md) (`terraform destroy`, state bucket/lock table removal, ECR images handled by `force_delete`). The cluster costs roughly $8/day while running.
