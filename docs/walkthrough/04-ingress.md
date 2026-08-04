# 4. Authorization at ingress

**Prove:** requests entering the cluster are allowed or denied by OpenFGA —
`user:X can_get/can_admin route:Y` — enforced by Connectivity Link's
`AuthPolicy` at the Gateway, before traffic ever reaches a workload.

```bash
make ingress
```

This creates a Gateway API `Gateway`, `HTTPRoute`s for `storefront` and
`storefront-admin`, and an `AuthPolicy` whose pipeline is:

1. **authentication** — establish the caller (demo: API keys for `alice`, `bob`)
2. **metadata** — HTTP callout to OpenFGA `/check` with the caller + route
3. **authorization** — pattern match: proceed only if `allowed: true`

The API keys for the demo users are generated at install time (nothing secret
lives in this public repo):

```bash
# LoadBalancer address; on bare metal (no LB implementation) use the
# NodePort URL the install script printed instead
GW=$(oc -n ingress-demo get gateway demo-gw -o jsonpath='{.status.addresses[0].value}')
ALICE_KEY=$(oc -n ingress-demo get secret api-key-alice -o jsonpath='{.data.api_key}' | base64 -d)
BOB_KEY=$(oc -n ingress-demo get secret api-key-bob -o jsonpath='{.data.api_key}' | base64 -d)
```

## Deny first

```bash
# bob is a viewer of route:storefront (via the user:* public tuple) — allowed
curl -s -H "Authorization: APIKEY $BOB_KEY" http://$GW/            # 200

# bob is not an admin — denied at the gateway by OpenFGA
curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: APIKEY $BOB_KEY" http://$GW/admin             # 403

# alice is admin via team:platform#member — allowed
curl -s -H "Authorization: APIKEY $ALICE_KEY" http://$GW/admin     # 200

# no key at all — rejected at authentication, before OpenFGA is ever asked
curl -s -o /dev/null -w '%{http_code}' http://$GW/                 # 401
```

## The team is the policy

Alice's admin access flows through a *relationship chain*:
`alice → member → team:platform → admin → route:storefront-admin`. Watch what
firing alice from the team does (uses the `$STORE`/port-forward environment
from [chapter 2](02-openfga.md#poke-the-store)):

```bash
bin/fga tuple delete --store-id $STORE user:alice member team:platform
curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: APIKEY $ALICE_KEY" http://$GW/admin           # 403 — at the edge

bin/fga tuple write --store-id $STORE user:alice member team:platform   # rehire alice
```

One tuple deletion revoked her access to *every* route the platform team holds —
that's the ReBAC composition NetworkPolicy/RBAC can't express.

## The AuthPolicy, field by field

```yaml title="deploy/ingress/authpolicies.yaml.tmpl"
--8<-- "deploy/ingress/authpolicies.yaml.tmpl"
```

The parts that earn their place (all validated on-cluster against RHCL 1.4.2):

- **`apiKey.allNamespaces: true`** — the api-key Secrets live in
  `ingress-demo`, but Authorino resolves selectors relative to the generated
  `AuthConfig`, which the Kuadrant operator materializes in `kuadrant-system`.
  Without this flag every valid key is rejected as invalid (401).
- **`metadata.http`** — the OpenFGA callout: a POST to
  `/stores/<store-id>/check` whose `body.expression` is CEL building the
  check JSON from the authenticated identity
  (`auth.identity.metadata.annotations["userid"]`). The store id is a
  runtime-generated ULID, which is why this file is a template the install
  script fills in.
- **`sharedSecretRef`** — resolved in the AuthConfig's namespace too, so the
  install script mirrors the OpenFGA API token into `kuadrant-system`, not
  into the AuthPolicy's own namespace.
- **`patternMatching.patterns[].predicate`** — CEL over the metadata
  response: `auth.metadata.openfga.allowed == true`. Deny is the default;
  this is the only path to allow.

**Next:** [Authorization at egress](05-egress.md)
