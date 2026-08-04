#!/usr/bin/env bash
# Deploys PostgreSQL + OpenFGA (official Helm chart) + the ext_authz bridge,
# then bootstraps the store, model, and seed tuples from model/. Idempotent.
# Secrets are generated here at install time — nothing sensitive is in git.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_login
ensure_fga

# Namespace first: if the mesh scopes discovery (discoverySelectors), openfga
# must be labeled before sidecars try to resolve the ext_authz bridge service.
oc apply -f "$REPO_ROOT/deploy/openfga/namespace.yaml"
enroll_discovery openfga
apply_kustomize deploy/openfga

if ! oc -n openfga get secret openfga-postgres >/dev/null 2>&1; then
  oc -n openfga create secret generic openfga-postgres \
    --from-literal=password="$(openssl rand -hex 16)"
fi
if ! oc -n openfga get secret openfga-api-token >/dev/null 2>&1; then
  oc -n openfga create secret generic openfga-api-token \
    --from-literal=token="$(openssl rand -hex 24)"
fi
PGPW="$(oc -n openfga get secret openfga-postgres -o jsonpath='{.data.password}' | base64 -d)"
TOKEN="$(oc -n openfga get secret openfga-api-token -o jsonpath='{.data.token}' | base64 -d)"

info "installing OpenFGA via Helm"
helm repo add openfga https://openfga.github.io/helm-charts --force-update >/dev/null
helm upgrade --install openfga openfga/openfga \
  --namespace openfga \
  -f "$REPO_ROOT/deploy/openfga/values.yaml" \
  --set datastore.uri="postgres://openfga:${PGPW}@postgres.openfga.svc.cluster.local:5432/openfga?sslmode=disable" \
  --set authn.method=preshared \
  --set "authn.preshared.keys[0]=${TOKEN}"

oc -n openfga rollout status deploy/postgres --timeout=180s
oc -n openfga rollout status deploy/openfga --timeout=300s

info "bootstrapping store from model/"
port_forward openfga svc/openfga 18080:8080
export FGA_API_URL=http://127.0.0.1:18080 FGA_API_TOKEN="$TOKEN"

STORE_NAME=ossm-openfga-demo
STORE_ID="$("$FGA_BIN" store list | python3 -c '
import json, sys
stores = json.load(sys.stdin).get("stores", [])
match = [s["id"] for s in stores if s["name"] == "'"$STORE_NAME"'"]
print(match[0] if match else "")
')"
if [[ -z "$STORE_ID" ]]; then
  STORE_ID="$("$FGA_BIN" store create --name "$STORE_NAME" --model "$REPO_ROOT/model/model.fga" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["store"]["id"])')"
  ok "created store $STORE_ID"
else
  "$FGA_BIN" model write --store-id "$STORE_ID" --file "$REPO_ROOT/model/model.fga" >/dev/null
  ok "store exists ($STORE_ID); model refreshed"
fi

# Seed tuples live in model/store.fga.yaml (single source of truth, also used
# by `fga model test`); extract and write them, tolerating already-written ones.
python3 -c '
import json, yaml, sys
doc = yaml.safe_load(open("'"$REPO_ROOT"'/model/store.fga.yaml"))
json.dump(doc.get("tuples", []), sys.stdout)
' > /tmp/ossm-openfga-tuples.json
"$FGA_BIN" tuple write --store-id "$STORE_ID" --file /tmp/ossm-openfga-tuples.json >/dev/null 2>&1 || true
rm -f /tmp/ossm-openfga-tuples.json

# Verify the canonical decisions answer correctly from the LIVE store
check() {
  local expect="$1" user="$2" rel="$3" obj="$4" got
  got="$("$FGA_BIN" query check --store-id "$STORE_ID" "$user" "$rel" "$obj" |
    python3 -c 'import json,sys; print(str(json.load(sys.stdin)["allowed"]).lower())')"
  [[ "$got" == "$expect" ]] || die "live check $user $rel $obj: expected $expect, got $got"
}
check true  workload:demo/storefront can_call  service:orders
check false workload:demo/storefront can_call  service:payments
check true  workload:demo/payments   can_reach host:httpbingo.org
ok "store bootstrapped and verified (store id: $STORE_ID)"

oc -n openfga rollout status deploy/ext-authz-bridge --timeout=180s || \
  info "bridge not ready yet — it resolves the store and becomes ready on its own"
ok "OpenFGA ready"
