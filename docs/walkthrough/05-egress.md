# 5. Authorization at egress

**Prove:** traffic *leaving* the mesh is allowed or denied by OpenFGA —
`workload:X can_reach host:Y` — enforced at an egress gateway. Only `payments`
may call the external provider; nothing else may.

```bash
make egress
```

This switches the mesh's outbound policy to `REGISTRY_ONLY` (unknown external
hosts are unroutable — the coarse backstop), registers the external host with a
`ServiceEntry`, routes it through an **egress gateway**, and applies the same
`CUSTOM` ext_authz policy at that gateway.

## Deny first

```bash
# payments has the can_reach tuple — allowed out
oc -n demo exec deploy/payments -c debug -- curl -s -o /dev/null -w '%{http_code}' http://httpbingo.org/get   # 200

# storefront does not — denied at the egress gateway
oc -n demo exec deploy/storefront -c debug -- curl -s -o /dev/null -w '%{http_code}' http://httpbingo.org/get # 403

# and a host nobody registered is simply unroutable (REGISTRY_ONLY)
oc -n demo exec deploy/storefront -c debug -- curl -s -m 5 http://example.com/   # connection failure
```

Two layers, deliberately: `REGISTRY_ONLY` is the blunt "nothing leaves unless
declared" backstop; OpenFGA is the fine-grained "*who* may use each declared
exit" — per-workload, per-host, changeable at runtime with a tuple.

## How the caller's identity survives the hop

The subtle part — and the reason this design was chosen — is that the check at
the egress gateway is `workload:demo/payments can_reach host:httpbingo.org`,
**not** "the gateway may reach the host". Watch it:

```bash
oc -n openfga logs deploy/ext-authz-bridge --tail=5
# DECISION allow user=workload:demo/payments relation=can_reach object=host:httpbingo.org ...
```

Three pieces line up to make that true
(`deploy/egress/istio-routing.yaml`):

- The mesh→gateway leg uses **`ISTIO_MUTUAL`** (DestinationRule on the
  gateway Service + the gateway server's TLS mode), so the *original
  workload's* SPIFFE certificate — not the gateway's — is what terminates at
  the gateway, and `source.principal` in the ext_authz check carries
  `demo/payments`.
- The bridge recognizes the hop as an egress-gateway check (the destination
  matches `EGRESS_GATEWAY_PRINCIPALS`) and authorizes workload→**host** (from
  the `Host` header) instead of workload→service.
- The gateway then **originates TLS** to the external host (DestinationRule
  `SIMPLE` at :443): apps speak plain HTTP so L7 attributes are available for
  authorization, while the wire outside the cluster is HTTPS.

!!! tip "External demo hosts are someone else's SLA"
    If the allow path returns 5xx, check the external service from outside the
    mesh before debugging the mesh — a response with
    `x-envoy-upstream-service-time` set was delivered end-to-end from the
    external host. (This demo originally used httpbin.org, which now sheds
    load with 503s often enough to break the walkthrough; httpbingo.org is
    its maintained successor.)

**Next:** [The NetworkPolicy comparison](06-netpol-comparison.md)
