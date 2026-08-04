#!/usr/bin/env bash
# Creates the Gateway, HTTPRoutes, demo users (API-key Secrets), and the
# AuthPolicies that delegate ingress authorization to OpenFGA. Idempotent.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_login
ensure_fga

apply_kustomize deploy/ingress

# Authorino's OpenFGA callout authenticates with the same preshared token —
# mirror the secret into the AuthPolicy namespace.
TOKEN="$(oc -n openfga get secret openfga-api-token -o jsonpath='{.data.token}' | base64 -d)"
oc -n ingress-demo create secret generic openfga-api-token \
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

info "waiting for the gateway to be programmed"
oc -n ingress-demo wait gateway/demo-gw --for=condition=Programmed --timeout=300s
GW="$(oc -n ingress-demo get gateway demo-gw -o jsonpath='{.status.addresses[0].value}')"

cat <<EOF

Ingress ready. Try it (chapter 4 of the walkthrough):

  ALICE_KEY=\$(oc -n ingress-demo get secret api-key-alice -o jsonpath='{.data.api_key}' | base64 -d)
  BOB_KEY=\$(oc -n ingress-demo get secret api-key-bob -o jsonpath='{.data.api_key}' | base64 -d)

  curl -H "Authorization: APIKEY \$BOB_KEY"   http://$GW/        # 200 (viewer)
  curl -H "Authorization: APIKEY \$BOB_KEY"   http://$GW/admin   # 403 (not admin)
  curl -H "Authorization: APIKEY \$ALICE_KEY" http://$GW/admin   # 200 (platform team)
EOF
