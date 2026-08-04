# 6. vs NetworkPolicy — a measured comparison

`NetworkPolicy` and mesh-level authorization **solve different problems** —
L3/L4 packet admission vs L7 per-request authorization — and a fair comparison
says so up front. What *is* comparable is how each approach behaves as the
number of policies, namespaces, and workloads grows:

| Dimension | NetworkPolicy (OVN-Kubernetes) | OpenFGA + ext_authz |
|---|---|---|
| Enforcement | per-node, packet admission | per-request, at the proxy |
| Policy change latency | control-plane propagation to every node | one tuple write |
| Cost of policy count N | grows with flows × policies programmed into OVN | store size; per-request cost ~flat |
| Per-request overhead | ~none once programmed | +1 Check RPC (measured below) |
| Expressiveness | IP/port/label reachability | identities, relations, inheritance |
| Auditability | grep N YAML objects across namespaces | query the graph |

Every cell of that table is a claim. This chapter measures the four that are
measurable, on a real cluster, with a harness you can re-run on yours.

## The harness

`make perf` (→ `scripts/run-perf.sh`) builds two identical fortio
client/server pairs — the **arenas** — and drives four phases:

- **`perf` namespace** — plain pods, no sidecars: the NetworkPolicy side.
- **`perf-mesh` namespace** — sidecar-injected, STRICT mTLS: the mesh side,
  toggled between "no authorization" and "CUSTOM `AuthorizationPolicy` →
  ext_authz bridge → OpenFGA Check per request".

Three design choices matter for trusting the numbers:

1. **Cross-node always.** The client is anti-affine to the server, so every
   measured request crosses the node boundary — the realistic case, held
   constant across all cases.
2. **Propagation is measured on a single clock.** A probe *inside the client
   pod* creates (or deletes) the one allow-policy via the Kubernetes API —
   or writes (or deletes) the one allow-tuple via the OpenFGA API — then
   polls the server until enforcement flips. "API acknowledged" and
   "enforcement observed" are timestamps from the same pod's clock; no
   cross-host skew enters the measurement. Poll resolution: ~50 ms for the
   NetworkPolicy apply direction (denied probes wait out a connect timeout —
   a *dropped packet* has no answer), ~10–25 ms elsewhere (a mesh denial is
   a fast HTTP 403 — an *answered* refusal; the difference is itself a
   property of the two systems).
3. **Fixed-QPS, uniform, no catch-up** fortio runs (60 s, 8 connections,
   5 s off-record warm-up), so a stall shows up as a latency outlier instead
   of being averaged away by a burst of catch-up requests.

Background scale is generated honestly: the N background NetworkPolicies all
select the *server pod* (each with a unique peer selector and port), so OVN
must program every one of them on the port group that the measured policy
also lands on. The 10,000 background tuples live in the same store the
measured Check queries.

!!! info "Where kube-burner went"
    The original design sketched kube-burner's `network-policy` workload for
    the propagation measurement. The shipped harness uses the in-pod
    single-clock probe instead: it measures *enforcement* (can the packet
    actually pass?), not object readiness, and it removes clock skew — at the
    price of ~50 ms resolution. If you need netpol churn at 100× this scale,
    kube-burner remains the right tool; the harness here is sized for a
    2-worker demo cluster.

## Run it yourself

```bash
make perf                      # setup → overhead → netpol-scale → tuple-scale → report
./scripts/run-perf.sh teardown # remove the perf namespaces afterwards
```

Knobs (env vars): `PERF_QPS_TIERS="100 1000"`, `PERF_DURATION=60s`,
`PERF_NETPOL_TIERS="0 100 1000 5000"`, `PERF_TUPLE_COUNT=10000`,
`PERF_TRIALS=5`. Raw fortio JSON, probe timestamps, and `kubectl top`
snapshots land in `perf-results/<timestamp>/`; `summary.md` is the collated
report. Phases are resumable — a rerun skips work whose results already
exist.

## Results from the reference cluster

Measured 2026-08-04 on a pristine ROSA cluster: OpenShift 4.20 (Kubernetes
1.33), **2 × m6a.xlarge workers** (4 vCPU / 16 GiB), OVN-Kubernetes CNI,
OSSM 3 (Istio v1.30), OpenFGA v1.18.2 — **one replica** on PostgreSQL
(one replica), one ext_authz bridge replica. No resource limits tuned;
everything as `make demo` deploys it.

### Per-request overhead (p50 / p99, ms)

| case | what's on the path | 100 QPS | 1000 QPS |
|---|---|---|---|
| base | plain pod → pod | 0.64 / 1.00 | 0.61 / 0.99 |
| netpol | + default-deny + allow policy | 0.64 / 1.00 | 0.61 / 1.00 |
| mesh | + both sidecars, STRICT mTLS | 1.27 / 1.99 | 0.88 / 1.98 |
| mesh_fga | + OpenFGA Check per request | 2.56 / 3.96 | 2.65 / 7.65 |

Zero non-200 responses in any run (~132,000 requests total across the
matrix).

- **NetworkPolicy per-request cost: unmeasurable.** The netpol row is the
  base row to the hundredth of a millisecond, at both rates — enforcement is
  compiled into OVN flows before the packet ever arrives.
- **The ext_authz hop costs +1.3 ms p50 at 100 QPS, +1.8 ms p50 at
  1000 QPS** (mesh_fga − mesh). The p99 gap widens to +5.7 ms at 1000 QPS —
  that is one un-tuned OpenFGA replica absorbing 1000 Checks/s.
- The bridge's own log-derived view of the Check (bridge → OpenFGA →
  verdict): **p50 1 ms** at both rates; p95 grows 1 ms → 3 ms, p99
  2 ms → 5 ms at 1000 QPS. The rest of the measured delta is the extra
  Envoy filter round-trip.
- **Authorizer footprint** (max observed, `kubectl top`): at 100 QPS the
  whole authorization plane runs on ~0.18 vCPU (openfga 108 m + bridge 50 m
  + postgres 17 m). At 1000 QPS: ~1.4 vCPU (866 m + 438 m + 99 m) and
  ~75 MiB of memory, total, still on single replicas. Cost scales with
  *request rate* — horizontal scaling (more openfga/bridge replicas) is the
  lever, and nothing here is per-policy.

### Policy propagation: NetworkPolicy

Median (min–max) over 5 trials per direction, single-clock in-pod probe:

| background policies | batch create (API-accepted) | allow: apply→enforced | revoke: delete→enforced |
|---|---|---|---|
| 0 | — | 66 ms (64–68) | 58 ms (57–88) |
| 100 | 100 in 1 s | 65 ms (64–67) | 86 ms (86–87) |
| 1000 | 900 in 5 s | 66 ms (65–67) | 86 ms (86–88) |
| 5000 | 4000 in 23 s | **177 ms (176–179)** | **147 ms (145–174)** |

- Flat at ~65 ms through N=1000, then **2.7× at N=5000** — the propagation
  path (kube-apiserver → ovnkube → OVN logical flows → per-node OpenFlow)
  does more work per change as the port group grows. The curve bends where
  the *shared state* gets big; expect the knee to move with node count and
  flow count, not just policy count.
- **The control plane pays even when idle**: ovnkube-node grew from
  19 m / 377 MiB (no policies) to 66 m / 657 MiB at 5000 policies —
  per node. That memory is the compiled reachability state the table's
  "cost of policy count N" row talks about.
- **Un-programming is the expensive direction**: bulk-deleting the 5000
  policies took **210 s** and pushed ovnkube-node to 243–509 m CPU while it
  recompiled flows. Policy churn, not policy existence, is what hurts OVN.
- Per-request latency **with all 5000 policies programmed**: p50 0.64 ms —
  identical to the empty namespace. The data plane genuinely does not care.

### Policy propagation: OpenFGA tuple write

| store size | grant: write→enforced | revoke: delete→enforced |
|---|---|---|
| seed (demo tuples) | 12 ms (11–13) | 11 ms (11–14) |
| +10,000 tuples | 12 ms (11–18) | 11 ms (11–13) |

- **A grant or revoke is enforced in ~12 ms** — write-acknowledged to
  verdict-flip observed *through the mesh*, and that figure is dominated by
  the probe's own 10 ms poll interval. There is no propagation step: the
  next Check simply reads the new tuple.
- **Flat at 10,000 tuples**, in propagation (12 ms), per-request latency
  (p50 2.57 ms vs 2.56 ms at seed), bridge-observed Check (p50 1 ms), and
  footprint (postgres +12 MiB). Store size is not on the hot path.
- Bulk policy change moves at API speed: 10,000 tuples written in 14 s
  (~700/s in 100-tuple batches), deleted in 13 s. Compare: 5000
  NetworkPolicies took 23 s to *accept* and 210 s to *remove* — and every
  change in between re-propagates to every node.

## Reading the numbers

The two systems put their cost in different places, and the harness makes
the trade concrete:

- **NetworkPolicy** is free per-request and cheap per-change at small N, but
  the *change path* degrades with scale (2.7× propagation at 5000 policies,
  3.5 minutes to unwind them) and the compiled state occupies every node's
  memory permanently. It is the right shape when policy is **static
  infrastructure**: written rarely, enforced constantly.
- **OpenFGA + ext_authz** charges ~1.3–1.8 ms p50 on every request —
  forever — but policy changes are data writes: ~12 ms to enforcement,
  independent of how much policy already exists, at 700 changes/s in bulk.
  It is the right shape when policy is **live data**: identities, grants and
  revocations that move faster than a GitOps pipeline converges.

Caveats, honestly: this is a quiet 2-worker cluster; the netpol knee at
5000 will sit elsewhere on a 50-node cluster (propagation fans out per
node, and kube-burner-scale tooling is the right instrument there). The
authorizer numbers are one un-tuned replica of everything, with no Envoy
ext_authz result caching — both deltas are *ceilings*, not floors: replicas,
connection pooling, and check caching all buy the tail down.

## The honest conclusion

If your problem is "packets from anywhere shouldn't reach my database," you
want NetworkPolicy (or its scale-conscious successor, AdminNetworkPolicy) —
zero marginal request cost is unbeatable, and 65 ms propagation is fine for
policy that changes weekly. If your problem is "*this* service may call
*that* API, and the rules change faster than your GitOps pipeline
converges" — reachability lists compiled into every node stop being the
right data structure, and a relationship store queried per-request starts
being one: 12 ms from decision to enforcement, at any scale the store has
yet reached. The demo's claim is not "replace NetworkPolicy"; it's "put the
policy that *is* authorization where authorization lives" — and now the
price tag on each side is measured, not asserted.
