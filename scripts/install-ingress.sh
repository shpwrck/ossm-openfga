#!/usr/bin/env bash
# Creates the Gateway, HTTPRoutes, demo users (API-key Secrets), and the
# AuthPolicies that delegate ingress authorization to OpenFGA. Idempotent.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_login
ensure_fga

# Namespace first: the Gateway's auto-deployment only happens in a namespace
# istiod can see (matters when the mesh scopes discovery via discoverySelectors).
oc apply -f "$REPO_ROOT/deploy/ingress/namespace.yaml"
enroll_discovery ingress-demo
apply_kustomize deploy/ingress

# Authorino's OpenFGA callout authenticates with the same preshared token.
# The AuthPolicy's sharedSecretRef is resolved in the namespace of the
# AuthConfig that Authorino serves — kuadrant-system, where the Kuadrant
# operator materializes AuthPolicies — NOT the AuthPolicy's own namespace.
TOKEN="$(oc -n openfga get secret openfga-api-token -o jsonpath='{.data.token}' | base64 -d)"
oc -n kuadrant-system create secret generic openfga-api-token \
  --from-literal=token="$TOKEN" \
  --dry-run=client -o yaml | oc apply -f -

# Demo users: API-key Secrets labeled for Authorino discovery. Keys are
# generated here — retrieve them with the commands the walkthrough shows.
for user in alice bob; do
  if ! oc -n ingress-demo get secret "api-key-$user" >/dev/null 2>&1; then
    oc -n ingress-demo create secret generic "api-key-$user" \
      --from-literal=api_key="$(openssl rand -hex 16)"
    oc -n ingress-demo label secret "api-key-$user" \
      authorino.kuadrant.io/managed-by=authorino app=demo-api-keys
    oc -n ingress-demo annotate secret "api-key-$user" userid="$user"
  fi
done

# The AuthPolicies need the runtime store id (a generated ULID)
port_forward openfga svc/openfga 18080:8080
export FGA_API_URL=http://127.0.0.1:18080 FGA_API_TOKEN="$TOKEN"
FGA_STORE_ID="$("$FGA_BIN" store list | python3 -c '
import json, sys
print(next(s["id"] for s in json.load(sys.stdin)["stores"] if s["name"] == "ossm-openfga-demo"))
')"
export FGA_STORE_ID
envsubst '$FGA_STORE_ID' < "$REPO_ROOT/deploy/ingress/authpolicies.yaml.tmpl" | oc apply -f -

info "waiting for the gateway"
oc -n ingress-demo wait gateway/demo-gw --for=condition=Accepted --timeout=300s
# auto-deployment name follows the <gateway-name>-istio convention
oc -n ingress-demo rollout status deploy/demo-gw-istio --timeout=300s

# Reach the gateway via its LoadBalancer address where the cluster provides
# one; on clusters without a LoadBalancer implementation (bare metal) the
# Gateway never reaches Programmed — fall back to the Service's NodePort.
GW="$(oc -n ingress-demo get gateway demo-gw -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)"
if [[ -z "$GW" ]]; then
  node_ip="$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
  node_port="$(oc -n ingress-demo get svc demo-gw-istio -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')"
  GW="$node_ip:$node_port"
  info "no LoadBalancer address (bare metal?) — using NodePort $GW"
fi

cat <<EOF

Ingress ready. Try it (chapter 4 of the walkthrough):

  ALICE_KEY=\$(oc -n ingress-demo get secret api-key-alice -o jsonpath='{.data.api_key}' | base64 -d)
  BOB_KEY=\$(oc -n ingress-demo get secret api-key-bob -o jsonpath='{.data.api_key}' | base64 -d)

  curl -H "Authorization: APIKEY \$BOB_KEY"   http://$GW/        # 200 (viewer)
  curl -H "Authorization: APIKEY \$BOB_KEY"   http://$GW/admin   # 403 (not admin)
  curl -H "Authorization: APIKEY \$ALICE_KEY" http://$GW/admin   # 200 (platform team)
EOF
