#!/usr/bin/env bash
# Shared helpers for the install scripts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FGA_BIN="$REPO_ROOT/bin/fga"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✔\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m ✘\033[0m %s\n' "$*" >&2; exit 1; }

require_login() {
  oc whoami >/dev/null 2>&1 || die "not logged into a cluster (oc whoami failed)"
}

# retry <attempts> <sleep-seconds> <cmd...>
retry() {
  local attempts="$1" pause="$2" i
  shift 2
  for ((i = 1; i <= attempts; i++)); do
    if "$@"; then return 0; fi
    sleep "$pause"
  done
  die "gave up after $attempts attempts: $*"
}

apply_kustomize() {
  info "applying $1"
  oc apply -k "$REPO_ROOT/$1"
}

# wait_csv <namespace> <subscription> — wait until the operator's CSV succeeds.
# Follows subscription.status.currentCSV when the Subscription exists, but
# falls back to matching CSVs by operator name: some clusters prune
# Subscription objects (e.g. governance policies pinning operator versions)
# while the already-created InstallPlan installs the CSV regardless.
wait_csv() {
  local ns="$1" sub="$2" csv="" phase i
  info "waiting for operator $sub in $ns"
  for ((i = 0; i < 60; i++)); do
    csv="$(oc -n "$ns" get subscription "$sub" -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)"
    [[ -z "$csv" ]] && csv="$(oc -n "$ns" get csv -o name 2>/dev/null | grep -m1 "/$sub\." | cut -d/ -f2 || true)"
    if [[ -n "$csv" ]]; then
      phase="$(oc -n "$ns" get csv "$csv" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      [[ "$phase" == "Succeeded" ]] && { ok "$csv Succeeded"; return 0; }
    fi
    sleep 10
  done
  die "operator $sub did not become ready (last CSV: ${csv:-none})"
}

# ensure_fga — download the fga CLI into ./bin (gitignored) if not present
ensure_fga() {
  [[ -x "$FGA_BIN" ]] && return 0
  info "downloading fga CLI"
  mkdir -p "$REPO_ROOT/bin"
  local ver arch os tmp
  ver="$(curl -s https://api.github.com/repos/openfga/cli/releases/latest | grep -oP '"tag_name": "\Kv[0-9.]+')"
  os="$(uname | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"; [[ "$arch" == "x86_64" ]] && arch=amd64; [[ "$arch" == "aarch64" ]] && arch=arm64
  tmp="$(mktemp -d)"
  curl -sL "https://github.com/openfga/cli/releases/download/${ver}/fga_${ver#v}_${os}_${arch}.tar.gz" |
    tar xz -C "$tmp" fga
  mv "$tmp/fga" "$FGA_BIN"
  rm -rf "$tmp"
  ok "fga CLI $ver -> bin/fga"
}

# enroll_discovery <namespace> — when the live mesh scopes discovery with
# meshConfig.discoverySelectors, label the namespace so istiod can see it.
# No-op on the default (unscoped) mesh or when there is nothing to match.
enroll_discovery() {
  local ns="$1" sel labels
  sel="$(oc get istio default -o jsonpath='{.spec.values.meshConfig.discoverySelectors}' 2>/dev/null || true)"
  [[ -z "$sel" ]] && return 0
  labels="$(printf '%s' "$sel" | python3 -c '
import json, sys
sels = json.load(sys.stdin)
ml = next((s["matchLabels"] for s in sels if s.get("matchLabels")), {})
print(" ".join(f"{k}={v}" for k, v in ml.items()))
')"
  [[ -z "$labels" ]] && { info "mesh uses discoverySelectors without matchLabels — enroll $ns yourself"; return 0; }
  info "mesh scopes discovery via discoverySelectors — labeling $ns ($labels)"
  # shellcheck disable=SC2086
  oc label namespace "$ns" $labels --overwrite >/dev/null
}

# ensure_extension_provider — register the openfga-ext-authz extensionProvider
# on a PRE-EXISTING Istio CR without disturbing the rest of its spec. Other
# providers are preserved (append, not replace); idempotent by provider name.
ensure_extension_provider() {
  local merged
  merged="$(oc get istio default -o json | python3 -c '
import json, sys
spec = json.load(sys.stdin)["spec"]
providers = ((spec.get("values") or {}).get("meshConfig") or {}).get("extensionProviders") or []
if not any(p.get("name") == "openfga-ext-authz" for p in providers):
    providers.append({"name": "openfga-ext-authz", "envoyExtAuthzGrpc": {
        "service": "ext-authz-bridge.openfga.svc.cluster.local", "port": 9191}})
print(json.dumps(providers))
')"
  oc patch istio default --type merge \
    -p "{\"spec\":{\"values\":{\"meshConfig\":{\"extensionProviders\":${merged}}}}}"
}

# port_forward <namespace> <svc/name> <local:remote> — background port-forward,
# killed on script exit; waits until the local port answers
port_forward() {
  local ns="$1" target="$2" ports="$3"
  oc -n "$ns" port-forward "$target" "$ports" >/dev/null 2>&1 &
  PF_PID=$!
  trap '[[ -n "${PF_PID:-}" ]] && kill "$PF_PID" 2>/dev/null || true' EXIT
  local lp="${ports%%:*}" i
  for ((i = 0; i < 30; i++)); do
    (exec 3<>"/dev/tcp/127.0.0.1/$lp") 2>/dev/null && { exec 3>&-; return 0; }
    sleep 1
  done
  die "port-forward to $target did not come up"
}
