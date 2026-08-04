# Research notes (2026-08-04)

Condensed findings from the research pass that shaped the
[decisions](decisions.md), with primary sources. Useful when re-validating
against newer releases.

## OSSM 3

- OSSM 3.4 GA July 2026 (Istio 1.30, Kiali 2.27); 3.2 made ambient mode GA;
  OSSM 2.x EOL June 30, 2026.
- Subscription `servicemeshoperator3` / channel `stable` — the same operator
  OCP 4.19+'s ingress operator installs for native Gateway API
  (`openshift-default` GatewayClass); the demo tolerates a pre-existing
  subscription.
- Config: `Istio` CR (`sailoperator.io/v1`), meshConfig under
  `spec.values.meshConfig` (top-level `spec.meshConfig` does not exist).
  `IstioCNI` named `default` is mandatory on OpenShift. `istio-injection:
  enabled` only works when a revision or `IstioRevisionTag` is named `default`.
- No operator-managed ingress/egress gateways — gateway injection or Gateway
  API auto-deployment only.
- Sources: [OSSM 3.4 blog](https://www.redhat.com/en/blog/introducing-red-hat-openshift-service-mesh-34),
  [sail-operator docs](https://github.com/istio-ecosystem/sail-operator/blob/main/docs/README.adoc),
  [cluster-ingress-operator source](https://github.com/openshift/cluster-ingress-operator/blob/master/cmd/ingress-operator/start.go),
  [MeshConfig extensionProviders reference](https://istio.io/latest/docs/reference/config/istio.mesh.v1alpha1/#MeshConfig-ExtensionProvider-EnvoyExternalAuthorizationGrpcProvider).

## OpenFGA

- Server v1.18.2 (Aug 2026); official Helm chart is the recommended k8s
  install; chart's own security contexts are empty → fine under
  `restricted-v2`. The bundled Bitnami Postgres subchart is the classic
  OpenShift SCC trap — never enable it; bring your own Postgres.
- Memory engine + default `replicaCount: 3` is a trap (each replica gets its
  own store); we use Postgres + 1 replica.
- Auth: `preshared` bearer keys; HTTP 8080 / gRPC 8081; store ids are
  generated ULIDs → consumers must discover by name.
- `fga` CLI v0.7.x: `store create --name X --model m.fga` creates store+model
  in one call; distroless image (no shell) — which is why bootstrap runs from
  the install script, not an in-cluster Job.
- Sources: [chart values](https://raw.githubusercontent.com/openfga/helm-charts/main/charts/openfga/values.yaml),
  [production guide](https://openfga.dev/docs/best-practices/running-in-production),
  [k8s setup](https://openfga.dev/docs/getting-started/setup-openfga/kubernetes).

## ext_authz bridging

- `openfga/openfga-envoy` (the only official adapter) archived 2026-06-23,
  still WIP — its extractor design (SPIFFE / method / header → user, relation,
  object) is a good reference; Apache-2.0.
- Under Istio mTLS, `CheckRequest.attributes.source.principal` carries the
  caller's SPIFFE id **with** the `spiffe://` prefix (Istio's own policy syntax
  omits it — normalize). `destination.principal` identifies the target.
- Istio `CUSTOM` AuthorizationPolicy + `envoyExtAuthzGrpc` provider is the GA
  path; deny-on-provider-failure is the default (`failOpen: false`).
- OpenFGA per-query `consistency` (`MINIMIZE_LATENCY` vs `HIGHER_CONSISTENCY`)
  is the caching knob — don't hand-roll a cache in the adapter.
- Sources: [openfga-envoy](https://github.com/openfga/openfga-envoy),
  [authz-custom task](https://istio.io/latest/docs/tasks/security/authorization/authz-custom/),
  [AttributeContext](https://www.envoyproxy.io/docs/envoy/latest/api-v3/service/auth/v3/attribute_context.proto).

## Connectivity Link

- RHCL 1.4.2 current (July 2026); **1.4.0 deprecated by Red Hat** (auth/gateway
  instability). Subscription `rhcl-operator` / `stable` in `kuadrant-system`,
  then a `Kuadrant` CR. Supports OCP 4.19–4.22.
- With OSSM installed, RHCL auto-detects Istio as Gateway controller. Without
  it (OCP 4.19+), it uses `openshift-default`.
- `AuthPolicy` (kuadrant.io/v1) authorization evaluators: patternMatching, opa,
  kubernetesSubjectAccessReview, spicedb. **No OpenFGA evaluator**; the spicedb
  one is gRPC+SpiceDB-specific. OpenFGA path: `metadata.http` POST callout →
  CEL/pattern rule on the response. The
  [Authzed/SpiceDB user guide](https://docs.kuadrant.io/latest/authorino/docs/user-guides/authzed/)
  is the closest first-party analogue.
- HTTP-listener gateways need neither `TLSPolicy` (cert-manager) nor
  `DNSPolicy` (cloud DNS creds) — docs explicitly permit this.
- Sources: [RHCL 1.4 release notes](https://docs.redhat.com/en/documentation/red_hat_connectivity_link/1.4/html-single/release_notes/index),
  [AuthPolicy reference](https://docs.kuadrant.io/latest/kuadrant-operator/doc/reference/authpolicy/),
  [Authorino features](https://docs.kuadrant.io/latest/authorino/docs/features/).

## Egress

- Identity preservation: with the egress-gateway listener on
  `tls.mode: ISTIO_MUTUAL` (+ client DestinationRule `ISTIO_MUTUAL` with SNI),
  `source.principal` **at the gateway** is the original workload — the fact the
  whole egress chapter rests on. Plain HTTP listener would lose it.
- TLS origination at the gateway (DR `portLevelSettings` 443 `SIMPLE`) keeps
  L7 attributes visible for authz while the external wire is HTTPS.
  Passthrough degrades decisions to SNI-only.
- Istio "cannot securely enforce" gateway transit — `REGISTRY_ONLY` +
  NetworkPolicy are required to close the bypass.
- Sources: [egress-gateway task](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway/),
  [TLS origination task](https://istio.io/latest/docs/tasks/traffic-management/egress/egress-gateway-tls-origination/),
  [Tetrate egress authorization walkthrough](https://tetrate.io/blog/istio-how-to-enforce-egress-traffic-using-istios-authorization-policies),
  [OSSM 3.2 gateways guide](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.2/html/gateways/ossm-directing-outbound-traffic-through-a-gateway).

## NetworkPolicy at scale

- Red Hat perfscale (Aug 2025, ROSA 4.16, 24 workers): ~48K policies → ~4.38M
  OVS flows/node; enforcement-readiness latency 5.5s at 412K flows/node; OVN
  memory not released after cleanup (OCPBUGS-44430).
- ANP/BANP (GA OCP 4.16, still `v1alpha1` API) is the in-family scale answer
  for cluster-wide rules — the honest comparison includes it.
- Tooling: kube-burner-ocp `network-policy` workload + `netpolLatency`
  measurement; fortio (Istio's own load tool) for per-request overhead; Istio
  publishes proxy cost (~0.2 vCPU/60MB at 1krps) but **no** ext_authz overhead
  numbers — must be measured here.
- Sources: [scaling netpol study](https://developers.redhat.com/blog/2025/08/11/scaling-openshift-network-policies-results-and-takeaways),
  [kube-burner-ocp](https://kube-burner.github.io/kube-burner-ocp/latest/),
  [Istio perf page](https://istio.io/latest/docs/ops/deployment/performance-and-scalability/),
  [istio/tools ext_authz benchmark configs](https://github.com/istio/tools/tree/master/perf/benchmark/configs/istio/ext_authz).
