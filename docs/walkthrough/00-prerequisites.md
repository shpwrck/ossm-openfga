# 0. Prerequisites

## You need

- An **OpenShift 4.19+** cluster and a `cluster-admin` login. Any footprint
  works (SNO included) if it has ~8 GiB spare for the mesh, gateways, OpenFGA,
  and the demo app.
- Workstation tools: `oc`, `helm`, `make`, and optionally the
  [`fga` CLI](https://github.com/openfga/cli) if you want to poke the store
  directly (the automation runs it in-cluster for you).

```bash
oc whoami                 # logged in, cluster-admin
oc version                # client + server 4.19+
```

## Get the repo

```bash
git clone https://github.com/shpwrck/ossm-openfga.git
cd ossm-openfga
```

## The route ahead

| Chapter | You will end up with |
|---|---|
| [1. Operators](01-operators.md) | OSSM 3 + Connectivity Link operators installed |
| [2. OpenFGA](02-openfga.md) | OpenFGA + PostgreSQL running, store & model bootstrapped, tuples loaded |
| [3. Mesh](03-mesh.md) | Demo app in the mesh; east-west calls allowed/denied by OpenFGA |
| [4. Ingress](04-ingress.md) | A Gateway with `AuthPolicy`; users allowed/denied by OpenFGA |
| [5. Egress](05-egress.md) | Outbound traffic gated through an egress gateway by OpenFGA |
| [6. vs NetworkPolicy](06-netpol-comparison.md) | (Stretch) a measured comparison at scale |

!!! warning "Demo, not production"
    Choices here optimize for legibility: single OpenFGA replica, no TLS between
    enforcers and OpenFGA (in-mesh mTLS covers it), permissive fga API auth
    inside the cluster. Each chapter's *Hardening* notes point at the
    production-shaped alternative.
