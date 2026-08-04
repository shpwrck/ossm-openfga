# 2. Deploy OpenFGA

This chapter stands up the decision engine every later chapter calls:
**PostgreSQL → OpenFGA server → store bootstrap** (model + seed tuples).

```bash
make openfga
```

## What just happened

1. **PostgreSQL** started — a deliberately simple single-replica Deployment
   (`deploy/openfga/postgres.yaml`) whose password is generated at install
   time. Nothing secret lives in this repository.
2. The **OpenFGA server** (official Helm chart, pinned `v1.18.2`) came up with
   its schema migration Job, exposing the HTTP (8080) and gRPC (8081) APIs
   inside the cluster, authenticated by a generated preshared token.
3. The **ext_authz bridge** deployed alongside it (`deploy/openfga/bridge.yaml`)
   — idle until chapter 3 points the mesh at it.
4. The install script bootstrapped the store with the **`fga` CLI** (downloaded
   to `bin/fga`): created a store named `ossm-openfga-demo`, wrote the
   [authorization model](../concepts/openfga-101.md), loaded the seed tuples
   from `model/store.fga.yaml`, and **verified live Check answers** before
   declaring success.

## Poke the store

The store is now the single source of authorization truth. Ask it things:

```bash
# terminal 1 — reach OpenFGA from your workstation
oc -n openfga port-forward svc/openfga 18080:8080

# terminal 2
export FGA_API_URL=http://127.0.0.1:18080
export FGA_API_TOKEN=$(oc -n openfga get secret openfga-api-token -o jsonpath='{.data.token}' | base64 -d)
export STORE=$(bin/fga store list | python3 -c 'import json,sys; print([s["id"] for s in json.load(sys.stdin)["stores"] if s["name"]=="ossm-openfga-demo"][0])')

bin/fga query check --store-id $STORE workload:demo/storefront can_call service:orders
# {"allowed":true}
bin/fga query check --store-id $STORE workload:demo/storefront can_call service:payments
# {"allowed":false}

# the reverse question — everything storefront may call:
bin/fga query list-objects --store-id $STORE workload:demo/storefront can_call service
```

Nothing is *enforcing* these answers yet — that's the next three chapters. But
notice the demo's entire policy already exists, complete and queryable, before
a single enforcement resource has been created. That inversion (policy first,
enforcement attached later) is the core of the argument.

!!! tip "Hardening notes"
    Single replica, plain HTTP inside the cluster, emptyDir Postgres — all
    demo choices. Production: multiple OpenFGA replicas behind the same
    Postgres, TLS to the API, and a real database (or managed Postgres).

**Next:** [Authorization in the mesh](03-mesh.md)
