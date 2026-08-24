#!/usr/bin/env bash
# End-to-end verification of the demo environment.
# Read-only except for one temporary port-forward. Safe to run repeatedly.
set -uo pipefail

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }
hdr()  { echo; echo "== $* =="; }

hdr "Cluster"
kubectl get nodes -o wide || bad "kubectl get nodes"
kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed" {print "  not-ready:", $0}'
kubectl get deployments -A -l app.kubernetes.io/part-of=terasky-home-assignment
kubectl get svc,hpa,pdb,networkpolicy -n dev
kubectl get serviceaccount -n dev backend eso-backend >/dev/null && ok "serviceaccounts exist" || bad "serviceaccounts"
kubectl get clusterrole terasky-backend-node-reader-dev >/dev/null && ok "clusterrole exists" || bad "clusterrole"
kubectl get clusterrolebinding terasky-backend-node-reader-dev >/dev/null && ok "clusterrolebinding exists" || bad "clusterrolebinding"

hdr "Flux"
flux get kustomizations -A
flux get helmreleases -A
if flux get kustomizations -A --status-selector ready=false 2>/dev/null | grep -q .; then
  bad "some Flux kustomizations not ready"
else
  ok "all Flux kustomizations ready"
fi

hdr "HPA metrics (metrics-server)"
if kubectl top nodes >/dev/null 2>&1; then ok "kubectl top nodes works"; else bad "metrics-server not serving"; fi
kubectl get hpa -A

hdr "External Secrets"
kubectl get externalsecret -A
for ns in dev staging production; do
  status=$(kubectl get externalsecret backend -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [ "$status" = "True" ] && ok "ExternalSecret ready in $ns" || bad "ExternalSecret NOT ready in $ns"
  kubectl get secret backend-secrets -n "$ns" >/dev/null 2>&1 && ok "Secret materialized in $ns" || bad "Secret missing in $ns"
done

hdr "RBAC - positive (allowed: get/list nodes)"
for verb in get list; do
  if [ "$(kubectl auth can-i "$verb" nodes --as=system:serviceaccount:dev:backend)" = "yes" ]; then
    ok "backend SA can $verb nodes"
  else
    bad "backend SA cannot $verb nodes"
  fi
done

hdr "RBAC - negative (must all be denied)"
while read -r verb res ns; do
  if [ -n "$ns" ]; then extra=(-n "$ns"); else extra=(); fi
  if [ "$(kubectl auth can-i "$verb" "$res" "${extra[@]}" --as=system:serviceaccount:dev:backend 2>/dev/null)" = "no" ]; then
    ok "denied: $verb $res ${ns:+(ns $ns)}"
  else
    bad "NOT denied: $verb $res ${ns:+(ns $ns)}"
  fi
done <<'EOF'
delete pods dev
get secrets dev
list secrets dev
create deployments dev
delete nodes
create clusterroles
watch nodes
EOF

hdr "Application endpoints (via port-forward)"
POD=$(kubectl get pod -n dev -l app.kubernetes.io/name=terasky-backend -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n dev svc/backend 18080:80 >/dev/null 2>&1 &
PF=$!
sleep 3
H=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/health)
[ "$H" = "200" ] && ok "/health -> 200" || bad "/health -> $H"
curl -s http://127.0.0.1:18080/health | python3 -m json.tool || true
NODES_JSON=$(curl -s http://127.0.0.1:18080/nodes)
echo "$NODES_JSON" | python3 -m json.tool || true
CURRENT=$(echo "$NODES_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("currentNode",""))')
ACTUAL=$(kubectl get pod -n dev "$POD" -o jsonpath='{.spec.nodeName}')
if [ -n "$CURRENT" ] && [ "$CURRENT" = "$ACTUAL" ]; then
  ok "/nodes currentNode ($CURRENT) matches kubectl ($ACTUAL)"
else
  bad "/nodes currentNode ($CURRENT) != kubectl ($ACTUAL)"
fi
curl -s http://127.0.0.1:18080/metrics | grep -q http_requests_total && ok "/metrics exposes counters" || bad "/metrics"
kill $PF 2>/dev/null

hdr "Summary"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
