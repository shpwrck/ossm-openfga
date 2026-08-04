#!/usr/bin/env bash
# Removes the demo (namespaces, mesh config changes). Leaves the operators and
# control planes installed; rerun the individual make targets to rebuild.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_login

info "reverting outbound policy"
oc patch istio default --type merge \
  -p '{"spec":{"values":{"meshConfig":{"outboundTrafficPolicy":{"mode":"ALLOW_ANY"}}}}}' 2>/dev/null || true

info "deregistering the openfga-ext-authz extensionProvider"
remaining="$(oc get istio default -o json 2>/dev/null | python3 -c '
import json, sys
spec = json.load(sys.stdin)["spec"]
providers = ((spec.get("values") or {}).get("meshConfig") or {}).get("extensionProviders") or []
print(json.dumps([p for p in providers if p.get("name") != "openfga-ext-authz"]))
' 2>/dev/null || true)"
[[ -n "$remaining" ]] && oc patch istio default --type merge \
  -p "{\"spec\":{\"values\":{\"meshConfig\":{\"extensionProviders\":${remaining}}}}}" 2>/dev/null || true

helm uninstall openfga -n openfga 2>/dev/null || true
for ns in demo ingress-demo istio-egress openfga perf perf-mesh; do
  oc delete namespace "$ns" --ignore-not-found
done
ok "demo removed (operators left installed)"
