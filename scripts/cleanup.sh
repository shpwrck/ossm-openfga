#!/usr/bin/env bash
# Removes the demo (namespaces, mesh config changes). Leaves the operators and
# control planes installed; rerun the individual make targets to rebuild.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_login

info "reverting outbound policy"
oc patch istio default --type merge \
  -p '{"spec":{"values":{"meshConfig":{"outboundTrafficPolicy":{"mode":"ALLOW_ANY"}}}}}' 2>/dev/null || true

helm uninstall openfga -n openfga 2>/dev/null || true
for ns in demo ingress-demo istio-egress openfga; do
  oc delete namespace "$ns" --ignore-not-found
done
ok "demo removed (operators left installed)"
