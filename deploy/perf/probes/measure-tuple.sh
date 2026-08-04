#!/bin/bash
# In-pod OpenFGA tuple propagation probe — the exact counterpart of
# measure-netpol.sh for the other side of the comparison. Runs inside the
# perf-mesh/fortio-client debug container: writes (or deletes) the tuple that
# authorizes fortio-client -> fortio-server, then polls the server through the
# mesh until the ext_authz verdict flips. Same clock for both timestamps.
#
#   env: FGA_URL (e.g. http://openfga.openfga.svc.cluster.local:8080)
#        FGA_TOKEN, FGA_STORE
#   measure-tuple.sh write|delete <server-url>
#
# stdout on success: "<t-request-start> <t-api-acked> <t-enforced>"
set -euo pipefail
DIR="$1" URL="$2"

TUPLE='{"user":"workload:perf-mesh/fortio-client","relation":"can_call","object":"service:fortio-server"}'

# Denied probes are fast 403s from the sidecar (~2-4ms) — a mesh denial is an
# HTTP answer, not a dropped packet. The 10ms sleep bounds poll resolution.
probe() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 0.5 "$URL" || true
}

fga_write() { # fga_write writes|deletes -> http code
  curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $FGA_TOKEN" -H 'Content-Type: application/json' \
    -X POST -d "{\"$1\":{\"tuple_keys\":[$TUPLE]}}" \
    "$FGA_URL/stores/$FGA_STORE/write"
}

case "$DIR" in
  write)
    [[ "$(probe)" == "200" ]] &&
      { echo "ERR precondition: traffic already allowed" >&2; exit 1; }
    t0="$(date +%s.%N)"
    code="$(fga_write writes)"
    [[ "$code" == "200" ]] || { echo "ERR tuple write returned $code" >&2; exit 1; }
    t1="$(date +%s.%N)"
    while [[ "$(probe)" != "200" ]]; do sleep 0.01; done
    t2="$(date +%s.%N)"
    ;;
  delete)
    [[ "$(probe)" == "200" ]] ||
      { echo "ERR precondition: traffic not allowed" >&2; exit 1; }
    t0="$(date +%s.%N)"
    code="$(fga_write deletes)"
    [[ "$code" == "200" ]] || { echo "ERR tuple delete returned $code" >&2; exit 1; }
    t1="$(date +%s.%N)"
    while [[ "$(probe)" == "200" ]]; do sleep 0.01; done
    t2="$(date +%s.%N)"
    ;;
  *) echo "usage: $0 write|delete <server-url>" >&2; exit 2 ;;
esac
echo "$t0 $t1 $t2"
