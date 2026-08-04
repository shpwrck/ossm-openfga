# 6. vs NetworkPolicy — a measured comparison (stretch)

`NetworkPolicy` and mesh-level authorization **solve different problems** —
L3/L4 packet admission vs L7 per-request authorization — and a fair comparison
says so up front. What *is* comparable is how each approach behaves as the
number of policies, namespaces, and workloads grows:

| Dimension | NetworkPolicy (OVN-Kubernetes) | OpenFGA + ext_authz |
|---|---|---|
| Enforcement | per-node, packet admission | per-request, at the proxy |
| Policy change latency | control-plane propagation to every node | one tuple write |
| Cost of policy count N | grows with flows × policies programmed into OVN | store size; per-request cost ~flat |
| Per-request overhead | ~none once programmed | +1 Check RPC (measured here) |
| Expressiveness | IP/port/label reachability | identities, relations, inheritance |
| Auditability | grep N YAML objects across namespaces | query the graph |

## What the harness measures

1. **Policy propagation at scale** — time from policy creation to enforcement,
   at N ∈ {100, 1k, 5k, …} policies (kube-burner network-policy workloads).
2. **Per-request overhead** — request latency with and without the ext_authz
   hop (fortio), including OpenFGA Check latency distribution.
3. **Resource cost** — OVN control plane / node CPU at policy scale vs OpenFGA +
   bridge CPU at request scale.

!!! info "🚧 Stretch goal — harness not yet built"
    `deploy/perf` will hold the kube-burner + fortio harness and this page will
    hold real numbers from a reference cluster, with methodology to reproduce
    them on yours.

## The honest conclusion (preview)

If your problem is "packets from anywhere shouldn't reach my database," you want
NetworkPolicy (or its scale-conscious successor, AdminNetworkPolicy). If your
problem is "*this* service may call *that* API, and the rules change faster than
your GitOps pipeline converges" — reachability lists compiled into every node
stop being the right data structure, and a relationship store queried
per-request starts being one. The demo's claim is not "replace NetworkPolicy";
it's "put the policy that *is* authorization where authorization lives."
