# 3. Authorization in the mesh (east-west)

**Prove:** every service-to-service call inside the mesh is allowed or denied by
an OpenFGA relationship — `workload:X can_call service:Y`.

```bash
make mesh
```

This deploys the four demo services (each under its own ServiceAccount) with
sidecars, the **ext_authz bridge**, registers the bridge as an authorization
provider in the mesh, and applies a `CUSTOM` `AuthorizationPolicy` covering the
`demo` namespace.

## The rhythm: deny first

The seed tuples sanction `storefront → orders → payments` but **not**
`storefront → payments`. So:

```bash
# sanctioned hop — allowed (the install script already smoke-tested this)
oc -n demo exec deploy/storefront -c debug -- curl -s http://orders.demo:8080/
# {"service": "orders", ...}

# skipping the chain — denied by OpenFGA, enforced by Envoy
oc -n demo exec deploy/storefront -c debug -- \
  curl -s -o /dev/null -w '%{http_code}' http://payments.demo:8080/   # 403
```

That 403 came from `payments`' *sidecar*, which asked the bridge, which asked
OpenFGA: `workload:demo/storefront can_call service:payments?` → `false`.
Watch the decision happen:

```bash
oc -n openfga logs deploy/ext-authz-bridge --tail=5
# DECISION deny user=workload:demo/storefront relation=can_call object=service:payments ...
```

The one enforcement resource behind all of this:

```yaml title="deploy/mesh/authorization-policy.yaml"
--8<-- "deploy/mesh/authorization-policy.yaml"
```

## Fix it with a tuple, not a rollout

(Uses the `$STORE`/port-forward environment from [chapter 2](02-openfga.md#poke-the-store).)

```bash
bin/fga tuple write --store-id $STORE workload:demo/storefront can_call service:payments
oc -n demo exec deploy/storefront -c debug -- \
  curl -s -o /dev/null -w '%{http_code}' http://payments.demo:8080/   # 200

bin/fga tuple delete --store-id $STORE workload:demo/storefront can_call service:payments
# ...and it's a 403 again. Put the demo back the way you found it. :)
```

No manifest changed. No pod restarted. The *data* changed, and enforcement
followed at the next request.

## Break the authorizer (fail-closed)

```bash
oc -n openfga scale deploy/ext-authz-bridge --replicas=0
oc -n demo exec deploy/storefront -c debug -- \
  curl -s -o /dev/null -w '%{http_code}' http://orders.demo:8080/     # 403 — even the sanctioned hop
oc -n openfga scale deploy/ext-authz-bridge --replicas=1
```

The provider's `failOpen` defaults to false: no authorizer, no traffic. A
security demo that fails open would be proving the wrong thing.

## Hardening notes

- Bridge fail-mode: fail-closed (deny on OpenFGA unavailability) is the default
  here; know your availability budget before copying that.
- Scope the `CUSTOM` policy tighter than "whole namespace" in real estates.

**Next:** [Authorization at ingress](04-ingress.md)
