---
leave-behind: v1
state-scope: rosa-ossm-openfga-demo
status: current
---

# Runbook: ossm-openfga demo on the ROSA cluster

The live deployment created by the 2026-08-04 blank-cluster validation
(issue #2, VALIDATION.md pass 2). State scope: everything `make demo` created
on the pristine ROSA cluster (kubeconfig context `rosa` — this repo never
records cluster addresses). Unlike the hub, **every piece of mesh state here
was created by this repo's scripts** — there is no pre-existing mesh to
protect.

## Operability

### State and access

- Access: `oc config use-context rosa` with cluster-admin; check `oc whoami`
  before assuming the context is live. ROSA workshop clusters are ephemeral —
  if the API is gone, the state is gone with it and nothing needs cleanup.
- Created by this session, all via `make demo` (no hand edits): the
  `servicemeshoperator3` and `rhcl-operator` OLM Subscriptions + CSVs
  (3.4.1 / 1.4.2), `IstioCNI` + `Istio` `default` (Istio v1.30.3, InPlace,
  no IstioRevisionTag), and the namespaces `istio-system`, `istio-cni`,
  `kuadrant-system`, `openfga`, `demo`, `ingress-demo`, `istio-egress`.
- The `Istio` CR carries the `openfga-ext-authz` extensionProvider from
  `deploy/operators/instances/istio.yaml` and, after `make egress`,
  `outboundTrafficPolicy: REGISTRY_ONLY`.
- The ingress Gateway `demo-gw` has a real AWS ELB (`Programmed=True`);
  its hostname is in `oc -n ingress-demo get gateway demo-gw -o
  jsonpath='{.status.addresses[0].value}'` — never write it into the repo.
- Generated secrets (never in git): `openfga/openfga-postgres`,
  `openfga/openfga-api-token` (mirrored to `kuadrant-system`),
  `ingress-demo/api-key-{alice,bob}`.
- OpenFGA store `ossm-openfga-demo`; the id is a runtime ULID — discover it
  by name (`bin/fga store list` via port-forward), never hardcode it.
- **Perf arenas (2026-08-04 perf run, VALIDATION.md pass 3):** namespaces
  `perf` (plain pods) and `perf-mesh` (injected, STRICT mTLS) from
  `deploy/perf/`, plus the tuple
  `workload:perf-mesh/fortio-client can_call service:fortio-server` in the
  store. All background scale objects (5000 NetworkPolicies, 10k tuples) were
  created and removed by the harness; steady state is just the two arenas.
  Remove with `./scripts/run-perf.sh teardown` (results stay in the
  gitignored `perf-results/`).

### Template map

- `scripts/install-*.sh` + `scripts/lib.sh` — the five idempotent phases;
  on this cluster every coexistence branch (adopt, CSV fallback, discovery
  enrollment, NodePort fallback) no-ops and the fresh-install branches run.
- `deploy/<phase>/` — kustomize bases the scripts apply; the AuthPolicies
  are the one template (`deploy/ingress/authpolicies.yaml.tmpl`, filled with
  the runtime store id by `install-ingress.sh`).
- `model/store.fga.yaml` — the entire security policy (tuples) + offline
  tests; changing access = changing tuples here, then `make openfga`.

### Re-run

- Full rebuild: `make demo` (~3.5 minutes on this cluster). All phases
  idempotent; safe to re-run any single phase.
- After tuple changes only: `make openfga` (rewrites tuples, reruns live
  checks). It does not delete removed tuples — use `bin/fga tuple delete`.
- On a *new* pristine cluster, `make demo` is the whole procedure — pass 2
  proved it needs nothing else.

### Verify and recover

- Mesh: `oc -n demo exec deploy/storefront -c debug -- curl -s -o /dev/null
  -w '%{http_code}' http://orders.demo:8080/` → 200, and payments → 403.
- Ingress: curl the ELB hostname (above): no key 401, bob `/` 200, bob
  `/admin` 403, alice `/admin` 200 (keys: `oc -n ingress-demo get secret
  api-key-<user> -o jsonpath='{.data.api_key}' | base64 -d`). Fresh ELB DNS
  can take ~2 minutes to resolve after the Gateway is `Programmed`.
- Egress: payments → `http://httpbingo.org/get` 200; storefront → 403;
  `example.com` → 502 (`REGISTRY_ONLY`).
- Every authorization decision: `oc -n openfga logs deploy/ext-authz-bridge`.
- Perf harness healthy: `./scripts/run-perf.sh setup` ends with "arenas
  ready"; a full re-measure is `make perf` (~30 min; phases resume, so a
  fresh run needs a fresh `PERF_RESULTS_DIR` or an empty `perf-results/latest`).
- Recover from any wedged state: `make clean` (removes demo namespaces,
  restores `ALLOW_ANY`, deregisters the extensionProvider), then re-run the
  phases — or simply let the ephemeral cluster expire.

## Decision log

### Decisions

- **Ran the validation with an isolated kubeconfig** (`kubectl config view
  --flatten --minify --context=rosa` to a scratch file) so the shared
  kubeconfig's current-context stayed untouched — repeat this pattern for
  multi-context validation runs.
- **No script changes for pass 2** — deliberate: the point of issue #2 was to
  prove the blank-cluster branches as they stood. Findings that were
  observations (ELB DNS lag, 502 under `REGISTRY_ONLY`) went into
  VALIDATION.md, not code.
- **The fresh `Istio` CR pins no version** — the operator's default (v1.30.3
  today) is the demo's version on a blank cluster; drift from the docs'
  screenshots is expected and fine.
- **Ingress allow/deny was verified manually from outside the cluster** via
  the ELB; the script's smoke coverage ends at printing the commands.
- **Perf numbers in chapter 6 are from THIS cluster** (pass 3): 2 × m6a.xlarge
  is the reference environment those tables cite. Re-measuring on a different
  shape belongs in a new results section, not an edit of the existing numbers.
- **Propagation is measured in-pod on one clock** (probe scripts in
  `deploy/perf/probes/`, RBAC-scoped to the one policy in `perf`) — chosen
  over kube-burner to measure observed *enforcement* without cross-host clock
  skew; resolution caveats are documented in the chapter.

### How to drive it

- Work through the Makefile/scripts only; do not hand-edit the demo's
  cluster state (the scripts are the source of truth and stay idempotent).
- Never write cluster URLs, ELB hostnames, or kubeconfig content into this
  repo (public); the `rosa` context name is the only cluster reference
  allowed.
- When tuples change, keep `make model-test` green in the same change.
- Both install paths are now validated (VALIDATION.md passes 1 and 2); a
  first-run failure report on a fresh cluster now points at environment
  drift, not at the scripts' untested branches.
