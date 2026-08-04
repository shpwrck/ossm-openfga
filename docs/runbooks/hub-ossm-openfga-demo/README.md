---
leave-behind: v1
state-scope: hub-ossm-openfga-demo
status: current
---

# Runbook: ossm-openfga demo on the hub cluster

The live deployment created by the 2026-08-04 validation session. State scope:
the demo's namespaces and mesh configuration on the operator's lab cluster
(kubeconfig context `hub` — this repo never records cluster addresses).

## Operability

### State and access

- Access: `oc config use-context hub` with cluster-admin; check `oc whoami`
  before assuming the context is live.
- Demo namespaces on the cluster: `openfga` (OpenFGA + Postgres + ext_authz
  bridge), `demo` (four echo services, mesh-enrolled), `ingress-demo`
  (Gateway `demo-gw` + AuthPolicies), `istio-egress` (egress gateway),
  `kuadrant-system` (RHCL operator + Authorino/Limitador + the mirrored
  `openfga-api-token` Secret — installed by this session).
- The mesh control plane was **pre-existing and is not the demo's**: a
  multi-cluster `Istio` CR `default` (v1.28.5, hub/spoke networks, root
  `Sidecar` in `istio-system`, `discoverySelectors` on the label
  `istio-discovery: enabled`). This session's only writes to it: the
  `openfga-ext-authz` extensionProvider (append-aware) and
  `outboundTrafficPolicy: REGISTRY_ONLY` (set by `make egress`).
- Cluster quirks that shaped the scripts: Subscription objects get pruned
  after install (CSVs keep running); no LoadBalancer implementation, so the
  demo gateway is reached via NodePort; ACM hub with governance policies
  that target the `spoke` cluster only.
- Generated secrets (never in git): `openfga/openfga-postgres`,
  `openfga/openfga-api-token` (mirrored to `kuadrant-system`),
  `ingress-demo/api-key-{alice,bob}`.
- OpenFGA store `ossm-openfga-demo`; the id is a runtime ULID — discover it
  by name (`bin/fga store list` via port-forward), never hardcode it.

### Template map

- `scripts/install-*.sh` + `scripts/lib.sh` — the five idempotent phases;
  every coexistence accommodation (adoption, discovery enrollment, CSV
  fallback, NodePort fallback) lives here, not in one-off cluster edits.
- `deploy/<phase>/` — kustomize bases the scripts apply; the AuthPolicies
  are the one template (`deploy/ingress/authpolicies.yaml.tmpl`, filled with
  the runtime store id by `install-ingress.sh`).
- `model/store.fga.yaml` — the entire security policy (tuples) + offline
  tests; changing access = changing tuples here, then `make openfga`.

### Re-run

- Full rebuild: `make demo` (or the five phase targets in order:
  `operators openfga mesh ingress egress`). All idempotent; safe to re-run
  any single phase.
- After tuple changes only: `make openfga` (rewrites tuples, reruns live
  checks). Note it does not delete removed tuples — delete those with
  `bin/fga tuple delete` (see VALIDATION.md for the worked example).

### Verify and recover

- Mesh: `oc -n demo exec deploy/storefront -c debug -- curl -s -o /dev/null
  -w '%{http_code}' http://orders.demo:8080/` → 200, and payments → 403.
- Ingress: the script prints the gateway URL (NodePort here); bob `/` 200,
  bob `/admin` 403, alice `/admin` 200, no key 401.
- Egress: payments → `http://httpbingo.org/get` 200; storefront → 403;
  `example.com` unroutable. If the allow path 5xxes, curl httpbingo.org from
  outside the mesh first (see troubleshooting: external host SLA).
- Every authorization decision: `oc -n openfga logs deploy/ext-authz-bridge`.
- Recover from any wedged state: `make clean` (removes demo namespaces,
  restores `ALLOW_ANY`, deregisters the extensionProvider — the pre-existing
  mesh keeps everything else), then re-run the phases.

## Decision log

### Decisions

- **Adopt, never overwrite, the pre-existing mesh.** A blind `oc apply` of
  the repo's `Istio` CR would prune the hub's version pin and multi-cluster
  config via last-applied pruning. The scripts detect and patch additively.
- **Coexistence fixes went into the public repo, not cluster one-offs** —
  discovery enrollment, the `demo` namespace `Sidecar`, NodePort fallback:
  all generic behavior a real customer cluster could also need
  (`VALIDATION.md` is the full findings list).
- **`REGISTRY_ONLY` is acceptable on this shared mesh** because nothing
  outside the demo namespaces runs sidecars; `make clean` reverts it.
- **httpbingo.org replaced httpbin.org** as the external host — httpbin.org
  sheds load with 503s (verified from outside the mesh).

### How to drive it

- Work through the Makefile/scripts only; do not hand-edit the demo's
  cluster state (the scripts are the source of truth and stay idempotent).
- Never write cluster URLs, node IPs, or kubeconfig content into this repo
  (public); the `hub` context name is the only cluster reference allowed.
- When tuples change, keep `make model-test` green in the same change.
- The blank-cluster path this cluster could not exercise has since been
  validated on a pristine ROSA cluster (VALIDATION.md pass 2, issue #2;
  see `docs/runbooks/rosa-ossm-openfga-demo/`).
