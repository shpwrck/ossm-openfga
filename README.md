# OpenFGA + OpenShift Service Mesh + Red Hat Connectivity Link

A self-guided demonstration of [OpenFGA](https://openfga.dev) — relationship-based,
fine-grained authorization — enforcing policy at **three enforcement points** on
OpenShift:

| Plane | Question OpenFGA answers | Enforced by |
|---|---|---|
| **Ingress** | Which *users* may call which *routes*? | Red Hat Connectivity Link (Kuadrant `AuthPolicy`) |
| **Mesh (east-west)** | Which *workloads* may call which *services*? | OpenShift Service Mesh 3 (`AuthorizationPolicy` → ext_authz) |
| **Egress** | Which *workloads* may reach which *external hosts*? | Service Mesh egress gateway (`AuthorizationPolicy` → ext_authz) |

One authorization model, one store, three planes. Every allow/deny decision in the
demo is a relationship query against the same OpenFGA store — which is the point:
authorization policy as *data* you can query, audit, and change at runtime, instead
of policy scattered across NetworkPolicies, RBAC rules, and app code.

**Measured:** a performance comparison against Kubernetes `NetworkPolicy` at
scale — per-request overhead, propagation latency, and resource cost as policy
count grows (`make perf`; results in walkthrough chapter 6).

## Start here

📖 **The walkthrough lives at the GitHub Pages site** (or locally: `make docs-serve`).
It assumes no prior familiarity with OpenFGA, Service Mesh, or Connectivity Link —
the concepts pages build up everything you need.

## Prerequisites

- An OpenShift 4.19+ cluster with cluster-admin access (everything else is automated)
- `oc`, `helm`, and `make` on your workstation

## Repository layout

```
docs/         The self-guided walkthrough (mkdocs → GitHub Pages)
model/        The OpenFGA authorization model (.fga DSL) and seed tuples
deploy/       Kustomize bases: operators, openfga, mesh, ingress, egress, perf
ext-authz/    The Envoy ext_authz → OpenFGA bridge deployed at mesh sidecars
              and the egress gateway
scripts/      Install/demo/cleanup automation driven by the Makefile
```

## Quick start

```bash
make operators     # install OSSM 3 + Connectivity Link operators (OLM)
make openfga       # deploy OpenFGA + datastore, bootstrap store/model/tuples
make mesh          # demo app + mesh authz (east-west)
make ingress       # gateway + AuthPolicy (north-south in)
make egress        # egress gateway + authz (north-south out)
```

Each target is idempotent; the walkthrough explains what every step does and how
to verify it.

## Status

Core demo (chapters 1–5: operators, OpenFGA, mesh, ingress, egress) validated
end-to-end on-cluster — see `VALIDATION.md` for the report. The NetworkPolicy
comparison harness (chapter 6) is still a stretch goal. See
`docs/reference/decisions.md` for the architecture decisions.

This is a public demo repository: it contains no credentials, no cluster
addresses, and no customer-specific information — keep it that way in PRs.
