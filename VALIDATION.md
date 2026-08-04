# On-cluster validation report

Two passes, both fully green (`make operators → openfga → mesh → ingress →
egress`, each phase proving both its allow and its deny path):

- **Pass 1 (2026-08-04) — coexistence:** a cluster already running the OSSM
  operator and a multi-cluster mesh; exercised the adoption branches.
- **Pass 2 (2026-08-04) — blank cluster:** a pristine ROSA cluster (issue #2);
  exercised the fresh-install branches. **Zero script changes needed.**

## Pass 1 — coexistence with a pre-existing mesh

### Environment

- OpenShift 4.21 (Kubernetes 1.34), single node, bare metal (no LoadBalancer
  implementation)
- OSSM operator 3.4.1 **pre-installed**, running a **pre-existing multi-cluster
  mesh** (Istio v1.28.5, `profile: openshift`, east-west gateway,
  `discoverySelectors`, restrictive root-namespace `Sidecar`) — deliberately
  *not* a blank cluster, which made this a coexistence test as much as a
  validation
- RHCL 1.4.2 installed by this repo's scripts during the run
- OpenFGA v1.18.2 via the official Helm chart; bridge image from ghcr

### What each phase proved

| Phase | Allow path | Deny path |
|---|---|---|
| mesh | `storefront → orders` 200, bridge logs `allow workload:demo/storefront can_call service:orders` | `storefront → payments` 403 from OpenFGA (no tuple); authorizer scaled to 0 ⇒ fail-closed 403 |
| ingress | bob `/` 200 (public route), alice `/admin` 200 (via `team:platform#member`) | no key 401; bob `/admin` 403 from OpenFGA |
| ingress (mesh hop) | bridge logs `allow workload:ingress-demo/demo-gw-istio can_call service:storefront` — the researched SA convention is correct | — |
| egress | `payments → httpbingo.org` 200 through the gateway, bridge logs `allow workload:demo/payments can_reach host:httpbingo.org` — **original identity preserved across the `ISTIO_MUTUAL` hop** | `storefront → httpbingo.org` 403; `example.com` unroutable (`REGISTRY_ONLY`) |

### Findings and fixes (in run order)

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

## Pass 2 — blank cluster (ROSA, issue #2)

A single unattended `make demo` on a pristine cluster: no OSSM operator, no
mesh, no Kuadrant, no demo namespaces. **All five phases passed on the first
run, unmodified — total wall time ~3.5 minutes** (OSSM CSV created
15:42:46Z, egress smoke test green 15:45:47Z).

### Environment

- OpenShift 4.20.30 (Kubernetes 1.33) on ROSA — AWS, two worker nodes, with
  a real LoadBalancer implementation (unlike pass 1)
- OSSM operator 3.4.1 and RHCL 1.4.2 installed **fresh from OLM
  subscriptions** by `install-operators.sh` (the untested branch)
- Istio **v1.30.3** from the fresh `Istio` CR — the operator's current
  default, newer than pass 1's adopted v1.28.5, so the demo is proven across
  both versions
- OpenFGA v1.18.2 via Helm chart 0.3.10

### What each phase proved (beyond pass 1)

| Phase | Blank-cluster branch exercised |
|---|---|
| operators | Fresh `servicemeshoperator3` + `rhcl-operator` Subscriptions → CSVs `Succeeded`; fresh `IstioCNI` + `Istio` applies → both `Ready`. **The IstioRevisionTag removal is correct on a blank cluster too**: one `IstioRevision` named `default`, no tag, and `istio-injection: enabled` injects sidecars via the revision name. |
| openfga | Fresh store created (no adopt-existing branch): `created store 01KZ6Q5ZZBH2R6DT90KK1K0Y1H`, model + tuples written, live checks verified. `enroll_discovery` correctly no-ops (the fresh CR sets no `discoverySelectors`). |
| mesh | Same allow/deny as pass 1 (`storefront → orders` 200, `storefront → payments` 403), now with the `deploy/mesh/sidecar.yaml` override applied to a pristine mesh — harmless, as predicted in pass 1 finding 5. |
| ingress | **The LoadBalancer branch ran for the first time**: `Gateway` reached `Accepted=True` *and* `Programmed=True`, `status.addresses[0]` carried the AWS ELB hostname, no NodePort fallback. Verified via the ELB from outside the cluster: no key 401, bob `/` 200, bob `/admin` 403 (OpenFGA deny), alice `/admin` 200; bridge logged the mesh hop `allow workload:ingress-demo/demo-gw-istio can_call service:storefront`. |
| egress | Same allow/deny as pass 1: `payments → httpbingo.org` 200 (bridge logs the original workload identity across the `ISTIO_MUTUAL` hop), `storefront → httpbingo.org` 403, unregistered `example.com` 502 (`REGISTRY_ONLY` black-hole). |

### Findings

No script or manifest changes were needed — every pass-1 coexistence
accommodation (CSV fallback, adopt-vs-apply, discovery enrollment, Sidecar
override, NodePort fallback) proved to be a clean no-op on the blank path.
Observations worth keeping:

1. **ELB DNS lags Gateway `Programmed`.** The Gateway is `Programmed` with an
   address as soon as AWS assigns the ELB hostname, but public DNS for it took
   another ~2 minutes to resolve. `install-ingress.sh` only prints the try-it
   commands, so nothing failed — just expect the first curl to wait.
2. **The unregistered-host code under `REGISTRY_ONLY` is 502** (Envoy
   BlackHoleCluster) on this cluster; the smoke test's "anything but 200"
   check is the right shape.

## Pass 3 — perf harness (chapter 6) on the ROSA cluster

Run 2026-08-04 on the same pristine ROSA cluster as pass 2 (2 × m6a.xlarge,
OpenShift 4.20 / Kubernetes 1.33), after `make demo`. Full matrix green:
`run-perf.sh setup → overhead → netpol-scale → tuple-scale → report`, zero
non-200s across ~132k measured requests. Headline numbers (details and
methodology in `docs/walkthrough/06-netpol-comparison.md`):

- Per-request p50: base 0.64 ms = netpol 0.64 ms; mesh 1.27 ms; mesh+ext_authz
  2.56 ms (the OpenFGA Check adds ~1.3 ms p50 at 100 QPS, ~1.8 ms at 1000 QPS;
  bridge-observed Check p50 1 ms).
- NetworkPolicy apply→enforced: ~65 ms flat to N=1000 background policies,
  177 ms at N=5000; bulk delete of 5000 took 210 s; ovnkube-node grew
  19 m/377 MiB → 66 m/657 MiB per node.
- OpenFGA tuple write→enforced: ~12 ms, flat from seed to +10,000 tuples;
  10k tuples written in 14 s, deleted in 13 s.

Findings during harness bring-up (both fixed in the harness itself): the
fortio client needs `-redirect-port disabled` (its default https redirector
collides with a second server on 8081), and OSSM 3 injects `istio-proxy` as a
**native sidecar** (`spec.initContainers`) — anything asserting on
`spec.containers` alone misses it.

**Pass 3 addendum — `ipBlock.except` sweep** (same cluster, same day): the
`netpol-except` phase confirmed the known OVN-K guidance against `except`
with numbers. The negated ACL match is live on this version
(`ip4.src != {…}`), and OpenFlow cost follows **2 × complement-CIDR-pieces
per policy**: 500 one-rule policies with 8 *scattered* excepts = +8,000
flows on the selected pod's node (+32,004 at 2000 policies, 10× the node's
baseline table) while the same excepts packed *contiguously* aggregate away
to +1,000. Propagation latency stayed ~66 ms at this scale — flow count is
the early-warning metric, not latency. Bring-up finding, fixed in the
harness: a mis-indented `except` (sibling of `ipBlock`) is an unknown field
the API server **silently prunes** — the policy applies with no carve-out;
the generator now read-back-asserts every batch's excepts landed.

## Not validated

- `TLSPolicy`/`DNSPolicy` (deliberately out of scope).
