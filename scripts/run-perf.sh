#!/usr/bin/env bash
# The NetworkPolicy-vs-OpenFGA comparison harness (walkthrough chapter 6).
#
#   run-perf.sh [all|setup|overhead|netpol-scale|tuple-scale|report|teardown]
#
# Phases (all = setup → overhead → netpol-scale → tuple-scale → report):
#   setup        deploy the perf arenas (deploy/perf), record environment
#   overhead     fixed-QPS fortio matrix: base / netpol / mesh / mesh_fga
#   netpol-scale policy propagation latency at N background NetworkPolicies,
#                plus OVN resource snapshots and per-request flatness at max N
#   tuple-scale  tuple propagation latency at seed vs bulk tuple count,
#                plus OpenFGA/bridge resource snapshots
#   report       collate everything into summary.md (scripts/perf-report.py)
#   teardown     delete the perf namespaces (results stay on disk)
#
# Knobs (env): PERF_QPS_TIERS="100 1000"  PERF_DURATION=60s  PERF_CONNS=8
#              PERF_NETPOL_TIERS="0 100 1000 5000"  PERF_TUPLE_COUNT=10000
#              PERF_TRIALS=5  PERF_RESULTS_DIR=<dir>
#
# Requires: the demo through `make mesh` (OpenFGA + bridge + extensionProvider
# registered). Assumes the current oc context, like every other script here.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_login

QPS_TIERS="${PERF_QPS_TIERS:-100 1000}"
DURATION="${PERF_DURATION:-60s}"
CONNS="${PERF_CONNS:-8}"
NETPOL_TIERS="${PERF_NETPOL_TIERS:-0 100 1000 5000}"
TUPLE_COUNT="${PERF_TUPLE_COUNT:-10000}"
TRIALS="${PERF_TRIALS:-5}"

SERVER_PLAIN=http://fortio-server.perf.svc.cluster.local:8080/
SERVER_MESH=http://fortio-server.perf-mesh.svc.cluster.local:8080/
FGA_SVC_URL=http://openfga.openfga.svc.cluster.local:8080
PERF_TUPLE='{"user":"workload:perf-mesh/fortio-client","relation":"can_call","object":"service:fortio-server"}'

# ── results directory: one per run, perf-results/latest symlinks the newest ──
RESULTS_ROOT="$REPO_ROOT/perf-results"
if [[ -n "${PERF_RESULTS_DIR:-}" ]]; then
  RESULTS="$PERF_RESULTS_DIR"
elif [[ "${1:-all}" != "all" && -L "$RESULTS_ROOT/latest" ]]; then
  RESULTS="$(readlink -f "$RESULTS_ROOT/latest")"
else
  RESULTS="$RESULTS_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$RESULTS"
ln -sfn "$RESULTS" "$RESULTS_ROOT/latest"

# ── helpers ─────────────────────────────────────────────────────────────────

client_exec() { # client_exec <ns> <cmd...> — run in the client's debug container
  local ns="$1"; shift
  oc -n "$ns" exec deploy/fortio-client -c debug -- "$@"
}

wait_probe() { # wait_probe <ns> <url> <want-code>
  local ns="$1" url="$2" want="$3" i code=""
  for ((i = 0; i < 45; i++)); do
    code="$(client_exec "$ns" curl -s -o /dev/null -w '%{http_code}' \
      --max-time 2 "$url" 2>/dev/null || true)"
    [[ "$code" == "$want" ]] && return 0
    sleep 2
  done
  die "expected HTTP $want from $url (ns $ns); last saw '$code'"
}

wait_probe_denied() { # any non-200 counts: netpol denial is a timeout (000)
  local ns="$1" url="$2" i code
  for ((i = 0; i < 45; i++)); do
    code="$(client_exec "$ns" curl -s -o /dev/null -w '%{http_code}' \
      --max-time 2 "$url" 2>/dev/null || true)"
    [[ -n "$code" && "$code" != "200" ]] && return 0
    sleep 2
  done
  die "traffic to $url (ns $ns) was never denied"
}

top_snap() { # top_snap <out-file> <ns...> — timestamped kubectl-top append
  local out="$1"; shift
  {
    date -u +%FT%TZ
    for ns in "$@"; do
      echo "-- $ns"
      oc -n "$ns" adm top pods --no-headers 2>/dev/null || true
    done
    echo "-- nodes"
    oc adm top nodes --no-headers 2>/dev/null || true
    echo
  } >> "$out"
}

pf_stop() { # kill the current port-forward AND reap it, so the port is free
  [[ -n "${PF_PID:-}" ]] || return 0
  kill "$PF_PID" 2>/dev/null || true
  wait "$PF_PID" 2>/dev/null || true
  PF_PID=""
}

fga_env() { # resolve FGA_TOKEN + FGA_STORE_ID once per run
  [[ -n "${FGA_TOKEN:-}" && -n "${FGA_STORE_ID:-}" ]] && return 0
  FGA_TOKEN="$(oc -n openfga get secret openfga-api-token \
    -o jsonpath='{.data.token}' | base64 -d)"
  port_forward openfga svc/openfga 18080:8080
  FGA_STORE_ID="$(curl -s -H "Authorization: Bearer $FGA_TOKEN" \
    'http://127.0.0.1:18080/stores?page_size=100' | python3 -c '
import json, sys
stores = json.load(sys.stdin).get("stores", [])
print(next((s["id"] for s in stores if s["name"] == "ossm-openfga-demo"), ""))
')"
  pf_stop
  [[ -n "$FGA_STORE_ID" ]] || die "store ossm-openfga-demo not found (run make openfga)"
}

fga_api() { # fga_api <path> <json-body> -> response body; dies on non-200
  local out code
  out="$(mktemp)"
  code="$(curl -s -o "$out" -w '%{http_code}' \
    -H "Authorization: Bearer $FGA_TOKEN" -H 'Content-Type: application/json' \
    -X POST -d "$2" "http://127.0.0.1:18080/stores/$FGA_STORE_ID$1")"
  [[ "$code" == "200" ]] ||
    { cat "$out" >&2; rm -f "$out"; die "FGA API $1 returned HTTP ${code:-none}"; }
  cat "$out"
  rm -f "$out"
}

ensure_perf_tuple() { # write the client→server tuple unless already effective
  fga_env
  port_forward openfga svc/openfga 18080:8080
  local allowed
  allowed="$(fga_api /check "{\"tuple_key\":$PERF_TUPLE}" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("allowed", False))')"
  if [[ "$allowed" != "True" ]]; then
    fga_api /write "{\"writes\":{\"tuple_keys\":[$PERF_TUPLE]}}" >/dev/null
    ok "wrote tuple: perf-mesh/fortio-client can_call fortio-server"
  fi
  pf_stop
}

fortio_run() { # fortio_run <ns> <case> <qps> <out-json> [bridge-latency-file]
  local ns="$1" case="$2" qps="$3" out="$4" bridge="${5:-}" url t
  [[ "$ns" == perf ]] && url="$SERVER_PLAIN" || url="$SERVER_MESH"
  if [[ -s "$out" ]]; then
    info "fortio: case=$case qps=$qps — $out exists, skipping (resume)"
    return 0
  fi
  # 5s off-record warm-up — deliberately BEFORE the bridge-log window opens,
  # so warm-up Checks never pollute the captured latency distribution
  oc -n "$ns" exec deploy/fortio-client -c fortio -- \
    fortio load -qps 50 -c "$CONNS" -t 5s -quiet "$url" >/dev/null 2>&1 || true
  t="$(date -u +%FT%TZ)"
  info "fortio: case=$case qps=$qps t=$DURATION c=$CONNS (cross-node)"
  oc -n "$ns" exec deploy/fortio-client -c fortio -- \
    fortio load -qps "$qps" -c "$CONNS" -t "$DURATION" -uniform -nocatchup \
    -p "50,75,90,99,99.9" -labels "$case-q$qps" -json - "$url" \
    > "$out" 2> "$out.log"
  if [[ -n "$bridge" ]]; then
    # raw Go-duration tokens ("5ms", "0s", "1.2s") — perf-report.py parses
    # all forms, so ≥1s and sub-ms Checks are not silently dropped
    oc -n openfga logs deploy/ext-authz-bridge --since-time="$t" 2>/dev/null |
      grep -oP 'latency=\K\S+' > "$bridge" || true
  fi
  python3 - "$out" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
h = d["DurationHistogram"]
pc = {p["Percentile"]: p["Value"] * 1000 for p in h["Percentiles"]}
codes = d.get("RetCodes") or {}
print(f"    p50={pc.get(50,0):.2f}ms p99={pc.get(99,0):.2f}ms "
      f"avg={h['Avg']*1000:.2f}ms n={h['Count']} codes={codes}")
PY
}

bg_count() { oc -n perf get netpol -l perf-scale=bg --no-headers 2>/dev/null | wc -l; }

create_bg() { # create_bg <count> <start-index> <time-file>
  local count="$1" start="$2" out="$3" tmp t0 f pids=()
  tmp="$(mktemp -d)"
  python3 - "$count" "$start" "$tmp" <<'PY'
import sys, os
count, start, outdir = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
files = [open(os.path.join(outdir, f"chunk-{j}.yaml"), "w") for j in range(8)]
for k in range(count):
    i = start + k
    files[k % 8].write(f"""---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: perf-bg-{i:05d}
  namespace: perf
  labels: {{perf-scale: bg}}
spec:
  podSelector:
    matchLabels: {{app: fortio-server}}
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels: {{bg-src: "src-{i}"}}
      ports:
        - port: {9000 + (i % 50000)}
          protocol: TCP
""")
for f in files:
    f.close()
PY
  info "creating $count background NetworkPolicies (8 parallel oc streams)"
  t0=$SECONDS
  for f in "$tmp"/chunk-*.yaml; do
    [[ -s "$f" ]] || continue
    oc create -f "$f" >/dev/null & pids+=("$!")
  done
  for f in "${pids[@]}"; do wait "$f"; done
  echo "$count $((SECONDS - t0))" >> "$out"
  ok "$count policies accepted in $((SECONDS - t0))s"
  rm -rf "$tmp"
}

bulk_tuples() { # bulk_tuples write|delete <count> <time-file>
  local mode="$1" count="$2" out="$3" t0
  fga_env
  port_forward openfga svc/openfga 18080:8080
  info "$mode-ing $count bulk tuples (batches of 100)"
  t0=$SECONDS
  python3 - "$mode" "$count" "$FGA_STORE_ID" "$FGA_TOKEN" <<'PY'
import json, sys, urllib.request
mode, count, store, token = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
url = f"http://127.0.0.1:18080/stores/{store}/write"
tuples = [{"user": f"workload:perf/bg-src-{i}", "relation": "can_call",
           "object": f"service:bg-{i:05d}"} for i in range(count)]
tolerated = 0
for b in range(0, count, 100):
    body = json.dumps({mode + "s": {"tuple_keys": tuples[b:b + 100]}}).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req).read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        # tolerate ONLY idempotent re-runs (duplicate write / absent delete);
        # any other 400 is a real failure and must surface
        if e.code == 400 and ("already existed" in detail or "did not exist" in detail):
            tolerated += 1
            continue
        sys.exit(f"tuple batch at offset {b} failed: HTTP {e.code}: {detail[:300]}")
if tolerated:
    print(f"WARNING: {tolerated} batch(es) were no-ops (already applied)", file=sys.stderr)
PY
  echo "$count $((SECONDS - t0))" >> "$out"
  ok "$mode of $count tuples done in $((SECONDS - t0))s"
  pf_stop
}

# ── phases ──────────────────────────────────────────────────────────────────

phase_setup() {
  info "phase: setup → $RESULTS"
  oc apply -f "$REPO_ROOT/deploy/perf/namespace.yaml"
  enroll_discovery perf-mesh
  for ns in perf perf-mesh; do
    oc -n "$ns" create configmap perf-probes \
      --from-file="$REPO_ROOT/deploy/perf/probes" \
      --dry-run=client -o yaml | oc -n "$ns" apply -f - >/dev/null
  done
  apply_kustomize deploy/perf
  # clean slate for case toggles
  oc -n perf-mesh delete authorizationpolicy openfga-perf-authz --ignore-not-found
  oc -n perf delete netpol perf-default-deny perf-allow-client --ignore-not-found
  for ns in perf perf-mesh; do
    oc -n "$ns" rollout status deploy/fortio-server --timeout=300s
    oc -n "$ns" rollout status deploy/fortio-client --timeout=300s
  done
  # OSSM 3 injects istio-proxy as a native (init) sidecar — check both lists
  [[ "$(oc -n perf-mesh get pod -l app=fortio-server -o jsonpath=\
'{.items[0].spec.containers[*].name} {.items[0].spec.initContainers[*].name}')" == *istio-proxy* ]] ||
    die "perf-mesh pods have no sidecar — is injection enabled?"
  {
    echo "# perf run $(date -u +%FT%TZ)"
    echo "## nodes"
    oc get nodes -o custom-columns=\
NAME:.metadata.name,INSTANCE:'.metadata.labels.node\.kubernetes\.io/instance-type',\
CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory,VERSION:.status.nodeInfo.kubeletVersion
    echo "## versions"
    oc version 2>/dev/null | head -3
    echo "istiod: $(oc -n istio-system get deploy istiod \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
    echo "openfga: $(oc -n openfga get deploy openfga \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
    echo "## placement"
    oc -n perf get pods -o wide --no-headers | awk '{print "perf", $1, $7}'
    oc -n perf-mesh get pods -o wide --no-headers | awk '{print "perf-mesh", $1, $7}'
  } > "$RESULTS/meta.txt"
  ok "arenas ready (client and server on different nodes by anti-affinity)"
}

phase_overhead() {
  info "phase: overhead (fixed-QPS fortio matrix)"
  local od="$RESULTS/overhead" q t
  mkdir -p "$od"

  # base: plain pods, no policy of any kind
  oc -n perf delete netpol perf-default-deny perf-allow-client --ignore-not-found
  sleep 3
  wait_probe perf "$SERVER_PLAIN" 200
  for q in $QPS_TIERS; do fortio_run perf base "$q" "$od/base-q$q.json"; done

  # netpol: default-deny + the allow policy admitting exactly this traffic
  oc apply -f "$REPO_ROOT/deploy/perf/netpol/default-deny.yaml" \
           -f "$REPO_ROOT/deploy/perf/netpol/allow-client.yaml"
  sleep 3
  wait_probe perf "$SERVER_PLAIN" 200
  for q in $QPS_TIERS; do fortio_run perf netpol "$q" "$od/netpol-q$q.json"; done

  # mesh: sidecars + STRICT mTLS, no authorization
  oc -n perf-mesh delete authorizationpolicy openfga-perf-authz --ignore-not-found
  sleep 5 # let xDS drop the ext_authz filter
  wait_probe perf-mesh "$SERVER_MESH" 200
  for q in $QPS_TIERS; do fortio_run perf-mesh mesh "$q" "$od/mesh-q$q.json"; done

  # mesh_fga: + CUSTOM AuthorizationPolicy → bridge → OpenFGA Check per request
  oc apply -f "$REPO_ROOT/deploy/perf/authorization-policy.yaml"
  ensure_perf_tuple
  sleep 5
  wait_probe perf-mesh "$SERVER_MESH" 200
  for q in $QPS_TIERS; do
    ( for _ in 1 2 3; do sleep 15; top_snap "$od/top-mesh_fga-q$q.txt" openfga; done ) &
    local sampler=$!
    # the bridge logs one DECISION line per Check, with its own latency view
    fortio_run perf-mesh mesh_fga "$q" "$od/mesh_fga-q$q.json" \
      "$od/bridge-latency-q$q.txt"
    wait "$sampler" 2>/dev/null || true
  done
  ok "overhead matrix complete"
}

phase_netpol_scale() {
  info "phase: netpol-scale (propagation at N background policies)"
  local nd="$RESULTS/netpol-scale" tier_dir cur delta n t t0 maxn=0
  mkdir -p "$nd"
  oc apply -f "$REPO_ROOT/deploy/perf/netpol/default-deny.yaml" >/dev/null
  oc -n perf delete netpol perf-allow-client --ignore-not-found
  sleep 3
  wait_probe_denied perf "$SERVER_PLAIN"
  top_snap "$nd/top-ovn-baseline.txt" openshift-ovn-kubernetes

  for n in $NETPOL_TIERS; do
    (( n > maxn )) && maxn=$n
    tier_dir="$nd/tier-$(printf '%05d' "$n")"
    mkdir -p "$tier_dir"
    cur="$(bg_count)"
    (( n < cur )) &&
      info "tier $n is below the $cur policies already present — tiers must ascend; measuring at $cur"
    if (( n > cur )); then
      create_bg "$((n - cur))" "$cur" "$tier_dir/create-time.txt"
      info "settling 30s"
      sleep 30
    fi
    top_snap "$tier_dir/top-ovn.txt" openshift-ovn-kubernetes
    info "propagation trials at N=$n ($TRIALS × apply+delete)"
    for ((t = 1; t <= TRIALS; t++)); do
      client_exec perf /probe/measure-netpol.sh apply "$SERVER_PLAIN" \
        >> "$tier_dir/trials-apply.txt"
      sleep 1
      client_exec perf /probe/measure-netpol.sh delete "$SERVER_PLAIN" \
        >> "$tier_dir/trials-delete.txt"
      sleep 1
    done
    ok "tier N=$n done"
  done

  # per-request flatness while max-tier policies are still programmed
  oc apply -f "$REPO_ROOT/deploy/perf/netpol/allow-client.yaml" >/dev/null
  wait_probe perf "$SERVER_PLAIN" 200
  fortio_run perf "netpol-bg$maxn" 100 "$nd/netpol-bg$maxn-q100.json"
  oc -n perf delete netpol perf-allow-client --ignore-not-found

  info "bulk-deleting background policies"
  t0=$SECONDS
  oc -n perf delete netpol -l perf-scale=bg --wait=false >/dev/null 2>&1 || true
  until [[ "$(bg_count)" -eq 0 ]]; do sleep 2; done
  echo "$maxn $((SECONDS - t0))" > "$nd/bg-delete-time.txt"
  top_snap "$nd/top-ovn-after-delete.txt" openshift-ovn-kubernetes
  ok "netpol-scale complete (background policies removed)"
}

phase_tuple_scale() {
  info "phase: tuple-scale (propagation at seed vs $TUPLE_COUNT tuples)"
  local td="$RESULTS/tuple-scale" t
  mkdir -p "$td/seed" "$td/bulk"
  oc apply -f "$REPO_ROOT/deploy/perf/authorization-policy.yaml" >/dev/null
  ensure_perf_tuple
  sleep 5
  wait_probe perf-mesh "$SERVER_MESH" 200
  fga_env

  tuple_trials() { # tuple_trials <dir> — starts and ends in the allowed state
    local dir="$1" i
    for ((i = 1; i <= TRIALS; i++)); do
      oc -n perf-mesh exec deploy/fortio-client -c debug -- \
        env FGA_URL="$FGA_SVC_URL" FGA_TOKEN="$FGA_TOKEN" FGA_STORE="$FGA_STORE_ID" \
        /probe/measure-tuple.sh delete "$SERVER_MESH" >> "$dir/trials-delete.txt"
      sleep 0.5
      oc -n perf-mesh exec deploy/fortio-client -c debug -- \
        env FGA_URL="$FGA_SVC_URL" FGA_TOKEN="$FGA_TOKEN" FGA_STORE="$FGA_STORE_ID" \
        /probe/measure-tuple.sh write "$SERVER_MESH" >> "$dir/trials-write.txt"
      sleep 0.5
    done
  }

  info "tuple propagation trials at seed store size"
  tuple_trials "$td/seed"

  bulk_tuples write "$TUPLE_COUNT" "$td/bulk/write-time.txt"
  info "tuple propagation trials at $TUPLE_COUNT tuples"
  tuple_trials "$td/bulk"

  ( for _ in 1 2 3; do sleep 15; top_snap "$td/top-openfga.txt" openfga; done ) &
  local sampler=$!
  fortio_run perf-mesh "mesh_fga-tup$TUPLE_COUNT" 100 \
    "$td/mesh_fga-tup$TUPLE_COUNT-q100.json" "$td/bridge-latency-tup$TUPLE_COUNT.txt"
  wait "$sampler" 2>/dev/null || true

  bulk_tuples delete "$TUPLE_COUNT" "$td/bulk/delete-time.txt"
  ok "tuple-scale complete (bulk tuples removed)"
}

phase_report() {
  info "phase: report"
  python3 "$REPO_ROOT/scripts/perf-report.py" "$RESULTS" | tee "$RESULTS/summary.md"
  ok "summary → $RESULTS/summary.md"
}

phase_teardown() {
  info "phase: teardown"
  for ns in perf perf-mesh; do
    oc delete namespace "$ns" --ignore-not-found
  done
  ok "perf namespaces removed (results kept under perf-results/)"
}

# ── dispatch ────────────────────────────────────────────────────────────────
case "${1:-all}" in
  setup)        phase_setup ;;
  overhead)     phase_overhead ;;
  netpol-scale) phase_netpol_scale ;;
  tuple-scale)  phase_tuple_scale ;;
  report)       phase_report ;;
  teardown)     phase_teardown ;;
  all)          phase_setup; phase_overhead; phase_netpol_scale
                phase_tuple_scale; phase_report ;;
  *) die "usage: $0 [all|setup|overhead|netpol-scale|tuple-scale|report|teardown]" ;;
esac
