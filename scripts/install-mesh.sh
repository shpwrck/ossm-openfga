#!/usr/bin/env bash
# Deploys the demo app into the mesh and turns on OpenFGA enforcement for all
# east-west traffic in the demo namespace. Ends with a smoke test that proves
# both the allow and the deny path.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_login

# Namespace first: on a mesh that scopes discovery (discoverySelectors), demo
# must be discoverable BEFORE pods start, or their sidecars get no config.
oc apply -f "$REPO_ROOT/deploy/mesh/namespace.yaml"
enroll_discovery demo
apply_kustomize deploy/mesh

for d in storefront orders payments inventory; do
  oc -n demo rollout status "deploy/$d" --timeout=300s
done

info "smoke-testing enforcement (allow + deny)"
curl_as() { # curl_as <workload> <url> -> http code
  oc -n demo exec "deploy/$1" -c debug -- \
    curl -s -o /dev/null -w '%{http_code}' -m 10 "$2"
}
retry 12 5 test "$(curl_as storefront http://orders.demo:8080/)" = "200"
ok "storefront -> orders allowed (tuple exists)"
[[ "$(curl_as storefront http://payments.demo:8080/)" == "403" ]] ||
  die "storefront -> payments was NOT denied — enforcement is not active"
ok "storefront -> payments denied by OpenFGA (no tuple)"
ok "mesh authorization active"
