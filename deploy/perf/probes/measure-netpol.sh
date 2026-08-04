#!/bin/bash
# In-pod NetworkPolicy propagation probe. Runs inside the perf/fortio-client
# debug container: creates (or deletes) the perf-allow-client NetworkPolicy
# via the kube API, then polls the fortio server until enforcement flips.
# All three timestamps come from THIS pod's clock — no cross-host skew.
#
#   measure-netpol.sh apply|delete <server-url>
#
# stdout on success: "<t-request-start> <t-api-acked> <t-enforced>"
# (propagation latency = t-enforced - t-api-acked)
set -euo pipefail
DIR="$1" URL="$2"
API=https://kubernetes.default.svc
NS=perf
TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

POLICY='{"apiVersion":"networking.k8s.io/v1","kind":"NetworkPolicy",
"metadata":{"name":"perf-allow-client","namespace":"perf"},
"spec":{"podSelector":{"matchLabels":{"app":"fortio-server"}},
"policyTypes":["Ingress"],
"ingress":[{"from":[{"podSelector":{"matchLabels":{"app":"fortio-client"}}}],
"ports":[{"port":8080,"protocol":"TCP"}]}]}}'

# In the denied state OVN drops the SYN, so the connect timeout (50ms) is the
# poll resolution for the apply direction. In the allowed state probes return
# in ~1-2ms; the 20ms sleep bounds the delete-direction resolution.
probe() {
  curl -s -o /dev/null -w '%{http_code}' \
    --connect-timeout 0.05 --max-time 0.3 "$URL" || true
}

kapi() { # kapi <method> <path> [json-body] -> http code
  local method="$1" path="$2" body="${3:-}"
  local args=(-s -o /dev/null -w '%{http_code}' --cacert "$CA"
              -H "Authorization: Bearer $TOKEN" -X "$method")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  curl "${args[@]}" "$API$path"
}

case "$DIR" in
  apply)
    [[ "$(probe)" == "200" ]] &&
      { echo "ERR precondition: traffic already allowed" >&2; exit 1; }
    t0="$(date +%s.%N)"
    code="$(kapi POST "/apis/networking.k8s.io/v1/namespaces/$NS/networkpolicies" "$POLICY")"
    [[ "$code" == "201" ]] || { echo "ERR create returned $code" >&2; exit 1; }
    t1="$(date +%s.%N)"
    while [[ "$(probe)" != "200" ]]; do :; done
    t2="$(date +%s.%N)"
    ;;
  delete)
    [[ "$(probe)" == "200" ]] ||
      { echo "ERR precondition: traffic not allowed" >&2; exit 1; }
    t0="$(date +%s.%N)"
    code="$(kapi DELETE "/apis/networking.k8s.io/v1/namespaces/$NS/networkpolicies/perf-allow-client")"
    [[ "$code" == "200" ]] || { echo "ERR delete returned $code" >&2; exit 1; }
    t1="$(date +%s.%N)"
    while [[ "$(probe)" == "200" ]]; do sleep 0.02; done
    t2="$(date +%s.%N)"
    ;;
  *) echo "usage: $0 apply|delete <server-url>" >&2; exit 2 ;;
esac
echo "$t0 $t1 $t2"
