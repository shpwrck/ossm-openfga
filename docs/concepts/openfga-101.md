# What is OpenFGA?

OpenFGA is an open-source **authorization engine** — a CNCF project inspired by
[Google's Zanzibar](https://research.google/pubs/pub48190/), the system that
decides every permission check for Drive, YouTube, and Cloud. Its job is to
answer one question, fast:

> **Is `user` related to `object` as `relation`?**
> e.g. *is `workload:demo/orders` related to `service:payments` as `can_call`?*

Your services ask that question over gRPC/HTTP (a **Check** call) and get back
`allowed: true/false`, typically in single-digit milliseconds.

## Relationships, not rules

Most authorization systems make you write *rules* (RBAC roles, OPA policies,
firewall entries). OpenFGA instead stores *relationships* — facts called
**tuples**:

```
user:alice        member     team:platform
team:platform#member  admin  route:storefront-admin
workload:demo/orders  can_call  service:payments
```

An **authorization model** (written in a small DSL) declares which relationships
exist and how they compose. This demo's entire model is ~40 lines
([`model/model.fga`](https://github.com/shpwrck/ossm-openfga/blob/main/model/model.fga)):

```dsl
type team
  relations
    define member: [user]

type route
  relations
    define viewer: [user, user:*, team#member]
    define admin: [user, team#member]
    define can_get: viewer or admin
    define can_admin: admin
```

Two things to notice — they're the reason this beats flat ACLs:

1. **Sets as subjects.** `team:platform#member` grants access to *whoever is a
   member of the platform team, now or later*. Add alice to the team and she can
   reach the admin route; remove her and she can't. No route policy changes.
2. **Computed relations.** `can_get: viewer or admin` means admins are never
   granted "viewer" separately — the graph computes it.

## Why put *network* policy in an authorization graph?

Because "which workload may call which service" **is** an authorization question —
we've just been forced to answer it with IP-level tooling. Once workloads have
cryptographic identities (which the mesh's mTLS provides via
[SPIFFE](https://spiffe.io)), the caller of every request is a first-class
identity, and the tuple

```
workload:demo/storefront  can_call  service:orders
```

is both the policy *and* the audit record. Changing policy is writing a tuple —
milliseconds, no rollout. Auditing policy is a query
(`ListObjects: what may storefront call?`), not a grep across YAML.

## The pieces you'll deploy

| Piece | Role in this demo |
|---|---|
| **OpenFGA server** | Holds the store (model + tuples), answers Check calls |
| **PostgreSQL** | The server's datastore |
| **`fga` CLI** | Bootstraps the store; also runs the model's test suite in CI |
| **ext_authz bridge** | Translates Envoy's per-request authz callout into OpenFGA Checks (built in this repo) |

!!! tip "The model is tested like code"
    [`model/store.fga.yaml`](https://github.com/shpwrck/ossm-openfga/blob/main/model/store.fga.yaml)
    contains assertions (`storefront can_call payments → false`) that run in CI
    with `fga model test` — offline, no server needed. Policy-as-data still gets
    a test suite.

**Next:** [What is Service Mesh?](ossm-101.md)
