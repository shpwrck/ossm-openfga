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
oc exec deploy/payments -c app -- curl -s -o /dev/null -w '%{http_code}' http://httpbin.org/get   # 200

# storefront does not — denied at the egress gateway
oc exec deploy/storefront -c app -- curl -s -o /dev/null -w '%{http_code}' http://httpbin.org/get # 403

# and a host nobody registered is simply unroutable (REGISTRY_ONLY)
oc exec deploy/storefront -c app -- curl -s -m 5 http://example.com/   # connection failure
```

Two layers, deliberately: `REGISTRY_ONLY` is the blunt "nothing leaves unless
declared" backstop; OpenFGA is the fine-grained "*who* may use each declared
exit" — per-workload, per-host, changeable at runtime with a tuple.

!!! info "🚧 Section pending validation"
    The identity-propagation details (how the original workload's SPIFFE
    identity is preserved across the egress-gateway hop) and full manifests land
    here once validated on-cluster. First iteration demos HTTP egress; the
    HTTPS/TLS-origination story is tracked in
    [Decisions](../reference/decisions.md).

**Next:** [The NetworkPolicy comparison](06-netpol-comparison.md)
