# Architecture decisions

Running log of the decisions this demo is built on, so you can disagree with us
efficiently.

## Version pins (researched 2026-08-04)

| Component | Version | Install path |
|---|---|---|
| OpenShift | 4.19+ | assumed present |
| OSSM | 3.4.x (Istio 1.30) | OLM `servicemeshoperator3`, channel `stable` |
| Connectivity Link | 1.4.2 | OLM `rhcl-operator`, channel `stable` (1.4.0 is deprecated by Red Hat — never pin to it) |
| OpenFGA | v1.18.2 | official Helm chart (0.3.x), image tag pinned |
| `fga` CLI | v0.7.x | downloaded to `bin/` by the install scripts |

RHCL 1.4's release notes name OSSM 3.3 as the supported Gateway API provider
while channel `stable` installs OSSM 3.4; if you hit a compatibility wall, pin
the OSSM subscription to the versioned channel for 3.3. See
[research notes](research-notes.md) for sources.

## Decided

**OSSM 3 (not 2.6).** All of OSSM 2.x reached end-of-life June 30, 2026. OSSM 3
is Istio-tracking and Gateway-API-native; config lives in the `Istio` CR at
`spec.values.meshConfig` (the `ServiceMeshControlPlane` CRD is gone).

**One OpenFGA store for all three planes.** Splitting stores per plane would be
more "production-shaped" for large orgs, but the single store *is* the demo's
thesis: one queryable policy surface. The model keeps planes separate by type
(`route`/`service`/`host`), so splitting later is mechanical.

**Own ext_authz bridge for mesh + egress (`ext-authz/`).** The only official
adapter, `openfga/openfga-envoy`, was archived June 2026 while still WIP —
there is no production-shaped OpenFGA↔Envoy bridge upstream. Ours is ~250 lines
of Go, reads the caller from `source.principal` (more robust than XFCC header
parsing under Istio mTLS), fails closed, and doubles as teaching material.
OPA-envoy-plugin calling OpenFGA from Rego was considered and rejected: an
extra network hop and the FGA mapping hidden inside `http.send`.

**Authorino calls OpenFGA via `metadata.http` + pattern matching at ingress.**
`AuthPolicy` has no native OpenFGA evaluator (its ReBAC integration is
SpiceDB-specific and gRPC-only), so the supported shape is an HTTP POST callout
to OpenFGA's `/check` from the metadata stage, then a CEL predicate on
`allowed`. Keeps ingress 100% RHCL-native — no second enforcement component.

**Ingress gateway on the `istio` GatewayClass.** On OCP 4.19+ two Gateway API
providers coexist (`openshift-default` from the ingress operator, `istio` from
our mesh). The demo's gateway uses `istio` deliberately: one Envoy data plane
for mesh, ingress, and egress, and the gateway is a mesh workload whose calls
to `storefront` are themselves subject to OpenFGA (see the
`workload:ingress-demo/demo-gw-istio` tuple).

**Plain-HTTP gateway listener.** Skips `TLSPolicy`/`DNSPolicy` and their
prerequisites (cert-manager operator, cloud DNS credentials). Reach the gateway
by LB address. Red Hat's docs explicitly permit this shape.

**Egress: self-deployed gateway, `ISTIO_MUTUAL` inside, TLS origination
outside.** OSSM 3 has no operator-managed egress gateway — gateway injection
(a Deployment that is entirely an Istio proxy) is the documented pattern. The
mesh→gateway leg uses `ISTIO_MUTUAL` so the *original workload's* SPIFFE
identity is what ext_authz sees at the gateway; the gateway originates TLS to
the external host so apps speak HTTP (L7 attributes available for authz) while
the wire outside is HTTPS. HTTPS passthrough was rejected for the main path:
it degrades decisions to SNI-only. `REGISTRY_ONLY` + a NetworkPolicy close the
bypass — Istio alone cannot force traffic through an egress gateway.

**Sidecar mode, not ambient.** Ambient is GA since OSSM 3.2, but its L7 policy
requires waypoints and its egress story is waypoint-only — a different (and
less documented) identity path. Sidecar mode keeps every enforcement point on
the well-trodden pattern. Revisit once the demo is stable.

**Secrets are generated at install time.** Postgres password, OpenFGA API
token, demo-user API keys — all created by the scripts on the cluster, never
committed. The public repo contains no credentials by construction.

**Demo app is echo containers with meaningful names.** storefront/orders/
payments/inventory under distinct ServiceAccounts, each pod carrying a
`debug` container (ubi-minimal) so the walkthrough can `curl` *as* that
workload's identity. No app code to maintain.

**Deny-first demo rhythm.** Every chapter shows the request *denied* before
writing the tuple that allows it, and chapter 3 kills the authorizer to prove
fail-closed. A demo that only shows green checkmarks proves nothing.

**Docs: mkdocs-material on GitHub Pages, deployed by Actions.** The walkthrough
is the product; it gets CI (`mkdocs build --strict`). The FGA model gets CI too
(`fga model test`), as does the bridge (`go vet`/`test`/image build).

**Public repo hygiene.** No cluster URLs, no kubeconfigs, no credentials, no
customer names anywhere — including in git history and demo data. Identities in
examples are `alice`/`bob`; the external host is `httpbin.org`.

## Open items

- **On-cluster validation pass** — the manifests encode researched, documented
  patterns but have not yet run against a live cluster. Highest-risk spots are
  marked 🚧 in the walkthrough: the `AuthPolicy` callout field shapes
  (kuadrant.io/v1 CEL forms), the gateway auto-deployment ServiceAccount name
  (`demo-gw-istio`), and the Helm chart `--set` key names.
- **NetworkPolicy comparison harness** (stretch): kube-burner-ocp
  `network-policy` workload + `netpolLatency` measurement vs tuple-write
  propagation; fortio fixed-QPS ladder (baseline / netpol / mesh /
  mesh+ext_authz); resource sampling. Design in
  [chapter 6](../walkthrough/06-netpol-comparison.md).
- **HTTPS ingress + real hostnames** — optional follow-up introducing
  `TLSPolicy`/`DNSPolicy` once the core demo is validated.
