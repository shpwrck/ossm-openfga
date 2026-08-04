# On-cluster validation report

**Date:** 2026-08-04
**Result: all five phases pass end-to-end** (`make operators → openfga → mesh
→ ingress → egress`), each proving both its allow and its deny path.

## Environment

- OpenShift 4.21 (Kubernetes 1.34), single node, bare metal (no LoadBalancer
  implementation)
- OSSM operator 3.4.1 **pre-installed**, running a **pre-existing multi-cluster
  mesh** (Istio v1.28.5, `profile: openshift`, east-west gateway,
  `discoverySelectors`, restrictive root-namespace `Sidecar`) — deliberately
  *not* a blank cluster, which made this a coexistence test as much as a
  validation
- RHCL 1.4.2 installed by this repo's scripts during the run
- OpenFGA v1.18.2 via the official Helm chart; bridge image from ghcr

## What each phase proved

| Phase | Allow path | Deny path |
|---|---|---|
| mesh | `storefront → orders` 200, bridge logs `allow workload:demo/storefront can_call service:orders` | `storefront → payments` 403 from OpenFGA (no tuple); authorizer scaled to 0 ⇒ fail-closed 403 |
| ingress | bob `/` 200 (public route), alice `/admin` 200 (via `team:platform#member`) | no key 401; bob `/admin` 403 from OpenFGA |
| ingress (mesh hop) | bridge logs `allow workload:ingress-demo/demo-gw-istio can_call service:storefront` — the researched SA convention is correct | — |
| egress | `payments → httpbingo.org` 200 through the gateway, bridge logs `allow workload:demo/payments can_reach host:httpbingo.org` — **original identity preserved across the `ISTIO_MUTUAL` hop** | `storefront → httpbingo.org` 403; `example.com` unroutable (`REGISTRY_ONLY`) |

## Findings and fixes (in run order)

1. **`wait_csv` assumed the Subscription outlives the install.** This cluster
   prunes Subscription objects (governance-style pinning) after OLM has
   created the InstallPlan; the CSV installs and runs regardless. Fix:
   `wait_csv` falls back to matching CSVs by operator name (`scripts/lib.sh`).
2. **Blind `oc apply` over a pre-existing `Istio`/`IstioCNI` CR is
   destructive** — last-applied pruning would have stripped the version pin
   and multi-cluster config. Fix: `install-operators.sh` adopts an existing
   control plane and only registers the `openfga-ext-authz` extensionProvider,
   append-aware and idempotent (`ensure_extension_provider` in
   `scripts/lib.sh`).
3. **`IstioRevisionTag` named `default` can never work in this repo's shape.**
   With `InPlace` strategy the `Istio` CR named `default` already produces an
   `IstioRevision` named `default`, and a tag may not share a revision's name
   — true on a blank cluster too. Fix: manifest removed; `istio-injection:
   enabled` works via the revision name.
4. **`discoverySelectors` scope demo namespaces out of the mesh registry.**
   Fix: `enroll_discovery` in `scripts/lib.sh` labels each demo namespace into
   discovery (no-op on unscoped meshes), called namespace-first in every
   install script.
5. **A restrictive root-namespace `Sidecar` hides the ext_authz cluster** —
   every mesh request 403s with `ext_authz_error`/`UAEX` and the bridge is
   never called. Fix: `deploy/mesh/sidecar.yaml`, a namespace-level override
   whose egress list includes `openfga/*` (and `istio-egress/*` for chapter
   5). Harmless on pristine meshes; load-bearing on scoped ones.
6. **AuthPolicy `sharedSecretRef` resolves in `kuadrant-system`**, where the
   Kuadrant operator materializes AuthConfigs — not in the AuthPolicy's
   namespace. Until fixed, Authorino serves no config for the host and every
   request (any credentials) gets 404. Fix: `install-ingress.sh` mirrors the
   OpenFGA token into `kuadrant-system`.
7. **`apiKey.allNamespaces: true` is required** for API-key Secrets living
   outside `kuadrant-system`; without it every valid key is 401 "invalid".
   Fix: added to both AuthPolicies in the template.
8. **`Gateway` never reaches `Programmed` without a LoadBalancer** (bare
   metal). The gateway is functional regardless. Fix: `install-ingress.sh`
   waits on `Accepted` + rollout and falls back to the NodePort URL.
9. **httpbin.org is no longer a dependable demo host** — it shed load with
   its own 503s (verified from outside the mesh; the mesh delivered them
   end-to-end with `x-envoy-upstream-service-time` set). Fix: demo host is
   now **httpbingo.org** across model, manifests, scripts, and docs.

Confirmed-as-researched (no change needed): OpenFGA Helm `--set` keys; the
`demo-gw-istio` auto-deployment SA name; kuadrant.io/v1 CEL forms for
`body.expression` and `patternMatching` predicates; gateway-injection egress
gateway; `REGISTRY_ONLY` + NetworkPolicy bypass closure; fail-closed ext_authz.

## Not validated here

- **The blank-cluster path** of `install-operators.sh` (this cluster already
  had the OSSM operator and a mesh). The branch is unchanged from the
  researched shape minus the revision-tag removal, but has not run end-to-end
  on a pristine cluster since these changes.
- **Chapter 6** (NetworkPolicy comparison harness) — still a stretch goal.
- `TLSPolicy`/`DNSPolicy` (deliberately out of scope).
