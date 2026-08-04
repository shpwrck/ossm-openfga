# 1. Install the operators

Everything in this chapter is one command:

```bash
make operators
```

What it does, and why — worth reading while it runs (~5 minutes):

## Service Mesh 3

Two OLM objects and three custom resources:

```yaml title="deploy/operators/subscriptions/ossm-subscription.yaml"
--8<-- "deploy/operators/subscriptions/ossm-subscription.yaml"
```

!!! note "Already installed on your cluster?"
    On OpenShift 4.19+ the cluster ingress operator installs this same operator
    to back its native Gateway API support (`openshift-default` GatewayClass).
    The install script detects an existing subscription — or an operator
    installed with no Subscription at all — and leaves it alone. Likewise a
    pre-existing `Istio`/`IstioCNI` control plane is **adopted, not
    overwritten**: the script only registers the `openfga-ext-authz`
    extensionProvider on it (a blind `oc apply` would prune fields like a
    version pin or multi-cluster config). If the mesh scopes discovery with
    `discoverySelectors`, each install script labels the demo namespaces into
    discovery automatically.

OSSM 3 is operator-driven: you declare an `Istio` resource and the operator
runs the matching control plane (this replaced OSSM 2's
`ServiceMeshControlPlane`). Ours carries one demo-critical setting — the
registration of the OpenFGA bridge as an **external authorizer**:

```yaml title="deploy/operators/instances/istio.yaml"
--8<-- "deploy/operators/instances/istio.yaml"
```

Registering a provider enforces nothing by itself; it just gives
`AuthorizationPolicy` objects a name to delegate to. Note `failOpen` defaults
to false: **if the authorizer is down, requests are denied.** For an
authorization system that's the right failure mode, and chapter 3 demonstrates
it live.

Alongside the `Istio` CR goes one companion:

- **`IstioCNI`** (`deploy/operators/instances/istio-cni.yaml`) — required on
  OpenShift; sets up pod networking hooks for sidecar injection.

Namespaces join the mesh with the classic `istio-injection: enabled` label
because the `Istio` CR is named `default` with the `InPlace` update strategy,
so its active revision is also named `default`. (An `IstioRevisionTag` is only
needed with the `RevisionBased` strategy — and a tag may not share a name with
an existing revision, so creating one here would fail.)

## Connectivity Link

```yaml title="deploy/operators/subscriptions/rhcl-subscription.yaml"
--8<-- "deploy/operators/subscriptions/rhcl-subscription.yaml"
```

Then a single `Kuadrant` resource instantiates its components — Authorino
(authorization, our ingress enforcer), Limitador (rate limiting), and the DNS
operator:

```yaml title="deploy/operators/instances/kuadrant.yaml"
--8<-- "deploy/operators/instances/kuadrant.yaml"
```

With Service Mesh present, Connectivity Link **auto-detects Istio as its
Gateway controller** — the same Envoy data plane serves the mesh and the
gateway policies. We deliberately skip `TLSPolicy` and `DNSPolicy` (they'd
pull in cert-manager and cloud DNS credentials); the demo gateway listens on
plain HTTP at its load-balancer address — or, on clusters without a
LoadBalancer implementation (bare metal), at the NodePort the install script
prints.

## Verify

```bash
oc get csv -n openshift-operators | grep servicemesh   # Succeeded
oc get csv -n kuadrant-system | grep rhcl              # Succeeded
oc get istio,istiocni                                  # Ready
oc -n kuadrant-system get kuadrant kuadrant            # Ready
```

**Next:** [Deploy OpenFGA](02-openfga.md)
