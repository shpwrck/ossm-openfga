# Troubleshooting

Every entry below was hit for real during the on-cluster validation pass.
Format: symptom → cause → check → fix.

## General diagnostic entry points

```bash
# Is the mesh healthy?
oc get istio,istiorevision -A

# Is Connectivity Link healthy?
oc get kuadrant -A -o yaml | grep -A5 status

# Is OpenFGA answering?
oc -n openfga port-forward svc/openfga 8080:8080 &
curl -s localhost:8080/healthz

# What did the ext_authz bridge decide? (every Check is logged)
oc -n openfga logs deploy/ext-authz-bridge --tail=50

# What did Authorino decide at ingress?
oc -n kuadrant-system logs deploy/authorino --tail=50
```

## Mesh: every request is 403 and the bridge logs nothing

**Symptom.** All east-west traffic in `demo` returns 403; the bridge's log
shows no `DECISION` lines. The denied request's sidecar access log shows
`"response_code_details":"ext_authz_error"` and response flag `UAEX`.

**Cause.** The proxy cannot reach the ext_authz provider cluster — the
`openfga` namespace's services are not visible to it. Two known ways in:
a restrictive default `Sidecar` in the mesh's root namespace (its egress
list wins unless overridden), or `meshConfig.discoverySelectors` scoping
the `openfga` namespace out of istiod's registry entirely.

**Check.**

```bash
oc -n demo exec deploy/orders -c istio-proxy -- \
  pilot-agent request GET clusters | grep ext-authz-bridge   # empty = not visible
oc -n istio-system get sidecar                               # root-namespace default?
oc get istio default -o jsonpath='{.spec.values.meshConfig.discoverySelectors}'
```

**Fix.** Both are handled by the repo: `deploy/mesh/sidecar.yaml` overrides
the root default with an egress list that includes `openfga/*`, and the
install scripts label the demo namespaces into discovery when the mesh uses
`discoverySelectors`. If you removed either, put it back.

## Ingress: every request is 404, even without credentials

**Symptom.** The gateway answers 404 for all paths; the gateway's access log
shows the route matched (`route_name` set) but no `upstream_host`.

**Cause.** The 404 is Authorino's: it has no ready `AuthConfig` for the
host, most often because the AuthPolicy's `sharedSecretRef` cannot be
resolved. The Kuadrant operator materializes AuthConfigs in
`kuadrant-system`, and Authorino resolves secret references **there** — not
in the AuthPolicy's namespace.

**Check.**

```bash
oc -n ingress-demo get authpolicy    # Enforced: False, "waiting ... AuthConfig"
oc -n kuadrant-system get authconfig # READY false
oc -n kuadrant-system logs deploy/authorino --tail=20   # Secret "..." not found
```

**Fix.** Put the referenced secret in `kuadrant-system` (the install script
mirrors the OpenFGA token there). Authorino retries with backoff — annotate
the AuthConfig to force an immediate reconcile.

## Ingress: valid API keys get 401 "the API Key provided is invalid"

**Symptom.** Authentication itself fails for keys that demonstrably exist.

**Cause.** `apiKey.allNamespaces` defaults to false, so Authorino looks for
API-key Secrets only in the AuthConfig's namespace (`kuadrant-system`) —
the demo's keys live in `ingress-demo`.

**Check.** `oc -n kuadrant-system get authconfig -o yaml | grep allNamespaces`

**Fix.** `allNamespaces: true` in the AuthPolicy's `apiKey` block (already in
the repo's template; requires a cluster-wide Authorino, which is RHCL's
default deployment).

## Ingress: Gateway never reaches Programmed

**Symptom.** `oc wait gateway/demo-gw --for=condition=Programmed` times out;
the Gateway's status says `AddressNotAssigned`; the `demo-gw-istio` Service's
`EXTERNAL-IP` stays `<pending>`.

**Cause.** No LoadBalancer implementation on the cluster (typical bare
metal). The gateway itself is fine — `Accepted` is True and the deployment
is Available.

**Fix.** Reach the gateway at `<node-internal-ip>:<nodeport>` — the install
script detects the situation and prints that URL.

## Operators: install waits forever on the Subscription

**Symptom.** The CSV reaches `Succeeded` but the install loop keeps waiting.

**Cause.** Something on the cluster prunes `Subscription` objects (some
governance/pinning setups do) after OLM has already created the InstallPlan —
the operator installs and runs fine without its Subscription.

**Fix.** The script's `wait_csv` falls back to matching CSVs by operator
name, so this resolves itself; nothing to do beyond knowing why the
Subscription is missing.

## Egress: the allow path returns 5xx or times out

**Symptom.** `payments → external host` should be 200 but isn't; the deny
path (403) still works.

**Cause.** Usually the external service itself, not the mesh. httpbin.org —
this demo's original external host — sheds load with 503s regularly.

**Check.** A 5xx whose response carries `x-envoy-upstream-service-time` was
delivered end-to-end from the external host: the mesh, gateway, and
authorization all worked. Confirm by curling the host from outside the mesh.

**Fix.** Wait it out, or switch the demo host (the repo moved to
httpbingo.org for this reason — the tuple, ServiceEntry, DestinationRules,
and VirtualService must all name the same host).
