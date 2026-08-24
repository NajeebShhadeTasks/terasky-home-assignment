#!/usr/bin/env bash
# Guided 5-minute interview demo. Each step waits for Enter.
set -uo pipefail

step() { echo; echo "──────────────────────────────────────────────"; echo "DEMO: $*"; read -r -p "[Enter to run] "; }

step "Cluster + GitOps state"
kubectl get nodes
flux get kustomizations -A

step "Application pods across the three environments"
kubectl get pods -A -l app.kubernetes.io/name=terasky-backend -o wide

step "App endpoints (port-forward to dev)"
kubectl port-forward -n dev svc/backend 18080:80 >/dev/null 2>&1 &
PF=$!; sleep 3
curl -s http://127.0.0.1:18080/health | python3 -m json.tool
curl -s http://127.0.0.1:18080/nodes | python3 -m json.tool

step "Cross-check: currentNode vs kubectl get pod -o wide"
kubectl get pods -n dev -o wide

step "Least-privilege RBAC: allowed vs denied"
kubectl auth can-i list nodes --as=system:serviceaccount:dev:backend
kubectl auth can-i delete pods -n dev --as=system:serviceaccount:dev:backend
kubectl auth can-i get secrets -n dev --as=system:serviceaccount:dev:backend

step "Drift correction: manually add an env var to the dev Deployment (drift), then let Flux revert it"
kubectl set env deployment/backend -n dev DRIFT_DEMO=manual-change
kubectl get deployment backend -n dev -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
flux reconcile kustomization backend-dev --with-source
sleep 5
echo "After reconcile:"
kubectl get deployment backend -n dev -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo

step "Promotion history: the same immutable tag moved through the environments"
git log --oneline -10 -- apps/backend/overlays
grep -r newTag apps/backend/overlays/*/kustomization.yaml

kill $PF 2>/dev/null
echo; echo "Demo complete."
