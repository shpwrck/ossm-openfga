#!/usr/bin/env bash
# Routes external traffic through an egress gateway with OpenFGA deciding
# which workloads may reach which hosts, then locks the mesh down to
# REGISTRY_ONLY and closes the network-level bypass. Ends with a smoke test.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_login

# Namespace first: the gateway-injection webhook needs istiod to see this
# namespace (matters when the mesh scopes discovery via discoverySelectors).
oc apply -f "$REPO_ROOT/deploy/egress/namespace.yaml"
enroll_discovery istio-egress
apply_kustomize deploy/egress
oc -n istio-egress rollout status deploy/egress-gateway --timeout=300s

info "setting mesh outbound policy to REGISTRY_ONLY"
oc patch istio default --type merge \
  -p '{"spec":{"values":{"meshConfig":{"outboundTrafficPolicy":{"mode":"REGISTRY_ONLY"}}}}}'

info "smoke-testing egress (allow + deny + unregistered)"
curl_as() {
  oc -n demo exec "deploy/$1" -c debug -- \
    curl -s -o /dev/null -w '%{http_code}' -m 10 "$2" || true
}
retry 12 5 test "$(curl_as payments http://httpbingo.org/get)" = "200"
ok "payments -> httpbingo.org allowed (tuple exists)"
[[ "$(curl_as storefront http://httpbingo.org/get)" == "403" ]] ||
  die "storefront -> httpbingo.org was NOT denied"
ok "storefront -> httpbingo.org denied by OpenFGA (no tuple)"
code="$(curl_as storefront http://example.com/)"
[[ "$code" != "200" ]] || die "unregistered host reachable — REGISTRY_ONLY not active"
ok "unregistered hosts unroutable (REGISTRY_ONLY) — got $code"
ok "egress authorization active"
