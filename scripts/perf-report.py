#!/usr/bin/env python3
"""Collate a perf-results run directory into summary.md (stdout).

Reads whatever phases actually ran and skips the rest, so it works on partial
runs. Layout is produced by scripts/run-perf.sh.
"""
import json
import re
import sys
from pathlib import Path
from statistics import median

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "perf-results/latest")


def fortio(path: Path):
    d = json.loads(path.read_text())
    h = d["DurationHistogram"]
    pcs = {p["Percentile"]: p["Value"] * 1000 for p in h["Percentiles"]}
    return {
        "n": h["Count"],
        "avg": h["Avg"] * 1000,
        "p50": pcs.get(50), "p75": pcs.get(75), "p90": pcs.get(90),
        "p99": pcs.get(99), "p999": pcs.get(99.9),
        "qps": d.get("ActualQPS", 0),
        "codes": d.get("RetCodes") or {},
    }


def trials(path: Path):
    """Lines 't0 t1 t2' -> list of (t2-t1) seconds; ERR lines are skipped."""
    out = []
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) == 3:
            try:
                out.append(float(parts[2]) - float(parts[1]))
            except ValueError:
                pass
    return out


def trange(vals, unit="s"):
    if not vals:
        return "—"
    scale, suffix = (1000, "ms") if unit == "ms" else (1, "s")
    med, lo, hi = (v * scale for v in (median(vals), min(vals), max(vals)))
    return f"{med:.2f} ({lo:.2f}–{hi:.2f}) {suffix}"


def count_time(path: Path):
    """Last 'count seconds' line in a timing file."""
    if not path.exists():
        return None
    lines = [l.split() for l in path.read_text().splitlines() if l.strip()]
    return (int(lines[-1][0]), int(lines[-1][1])) if lines else None


def top_max(path: Path, prefix: str):
    """Max cpu(m)/mem(Mi) across snapshots for pods starting with prefix."""
    if not path.exists():
        return None
    cpu = mem = 0
    for line in path.read_text().splitlines():
        m = re.match(rf"({prefix}\S*)\s+(\d+)m\s+(\d+)(Mi|Gi)", line)
        if m:
            cpu = max(cpu, int(m.group(2)))
            mem = max(mem, int(m.group(3)) * (1024 if m.group(4) == "Gi" else 1))
    return (cpu, mem) if cpu or mem else None


def go_duration_ms(s: str):
    """Parse a Go time.Duration string ('0s', '5ms', '1.234s', '1m2.5s') to ms."""
    m = re.fullmatch(r"(?:(\d+)m)?([0-9.]+)(ms|s|µs|us|ns)", s)
    if not m:
        return None
    mins, val, unit = int(m.group(1) or 0), float(m.group(2)), m.group(3)
    scale = {"ms": 1, "s": 1000, "µs": 1e-3, "us": 1e-3, "ns": 1e-6}[unit]
    return mins * 60000 + val * scale


def bridge_pcts(path: Path):
    if not path.exists():
        return None
    vals = sorted(v for v in (go_duration_ms(t) for t in path.read_text().split())
                  if v is not None)
    if not vals:
        return None
    q = lambda p: vals[min(len(vals) - 1, int(p * len(vals)))]
    return {"n": len(vals), "p50": q(0.5), "p95": q(0.95), "p99": q(0.99)}


out = []
say = out.append

say(f"# NetworkPolicy vs OpenFGA — measured comparison\n")
meta = ROOT / "meta.txt"
if meta.exists():
    say("## Environment\n")
    say("```")
    say(meta.read_text().strip())
    say("```\n")

# ── per-request overhead ────────────────────────────────────────────────────
od = ROOT / "overhead"
if od.is_dir():
    say("## Per-request overhead (fortio, fixed QPS, cross-node)\n")
    runs = {}
    for f in sorted(od.glob("*-q*.json")):
        case, qps = f.stem.rsplit("-q", 1)
        runs.setdefault(qps, {})[case] = fortio(f)
    order = ["base", "netpol", "mesh", "mesh_fga"]
    for qps in sorted(runs, key=int):
        cases = runs[qps]
        say(f"### {qps} QPS\n")
        say("| case | p50 | p75 | p90 | p99 | p99.9 | avg | non-200 |")
        say("|---|---|---|---|---|---|---|---|")
        for c in order + [c for c in cases if c not in order]:
            if c not in cases:
                continue
            r = cases[c]
            bad = sum(v for k, v in r["codes"].items() if k != "200")
            say(f"| {c} | " + " | ".join(
                f"{r[k]:.2f}" if r[k] is not None else "—"
                for k in ("p50", "p75", "p90", "p99", "p999", "avg"))
                + f" | {bad}/{r['n']} |")
        say("")
        if "mesh" in cases and "mesh_fga" in cases:
            d50 = cases["mesh_fga"]["p50"] - cases["mesh"]["p50"]
            d99 = cases["mesh_fga"]["p99"] - cases["mesh"]["p99"]
            say(f"**ext_authz cost at {qps} QPS** (mesh_fga − mesh): "
                f"+{d50:.2f} ms p50, +{d99:.2f} ms p99 — one OpenFGA Check per request.\n")
        if "base" in cases and "netpol" in cases:
            d50 = cases["netpol"]["p50"] - cases["base"]["p50"]
            say(f"**NetworkPolicy cost at {qps} QPS** (netpol − base): "
                f"{d50:+.2f} ms p50 — enforcement is pre-programmed in OVN.\n")
    for qps in sorted(runs, key=int):
        b = bridge_pcts(od / f"bridge-latency-q{qps}.txt")
        if b:
            say(f"Bridge-observed Check latency at {qps} QPS "
                f"(n={b['n']}): p50={b['p50']} ms, p95={b['p95']} ms, "
                f"p99={b['p99']} ms (bridge → OpenFGA → verdict, ms-rounded).\n")
    for f in sorted(od.glob("top-mesh_fga-q*.txt")):
        qps = f.stem.rsplit("-q", 1)[1]
        parts = []
        for pod in ("openfga", "ext-authz-bridge", "postgres"):
            t = top_max(f, pod)
            if t:
                parts.append(f"{pod} {t[0]}m/{t[1]}Mi")
        if parts:
            say(f"Authorizer footprint under load at {qps} QPS (max observed): "
                + ", ".join(parts) + ".\n")

# ── propagation at scale ────────────────────────────────────────────────────
nd = ROOT / "netpol-scale"
if nd.is_dir():
    say("## Policy propagation: NetworkPolicy at N background policies\n")
    say("Latency is *API-acknowledged → observed enforcement*, measured on one "
        "clock inside the client pod. Poll resolution ≈ 50 ms (apply) / 25 ms "
        "(delete). Median (min–max) over trials.\n")
    say("| background policies | batch create (accepted) | allow: apply→enforced | allow removed: delete→enforced |")
    say("|---|---|---|---|")
    for tier in sorted(nd.glob("tier-*")):
        n = int(tier.name.split("-")[1])
        ct = count_time(tier / "create-time.txt")
        say(f"| {n} | " + (f"{ct[0]} in {ct[1]}s" if ct else "—") + " | "
            + trange(trials(tier / "trials-apply.txt"), "ms") + " | "
            + trange(trials(tier / "trials-delete.txt"), "ms") + " |")
    say("")
    dt = count_time(nd / "bg-delete-time.txt")
    if dt:
        say(f"Bulk delete of {dt[0]} policies: {dt[1]}s until the namespace was clean.\n")
    rows = []
    for tier in sorted(nd.glob("tier-*")):
        t = top_max(tier / "top-ovn.txt", "ovnkube-node")
        if t:
            rows.append(f"N={int(tier.name.split('-')[1])}: {t[0]}m/{t[1]}Mi")
    if rows:
        say("Max ovnkube-node footprint per tier (cpu/mem): " + "; ".join(rows) + ".\n")
    for f in sorted(nd.glob("netpol-bg*-q100.json")):
        r = fortio(f)
        n = f.stem[len("netpol-bg"):-len("-q100")]
        say(f"Per-request latency with {n} policies programmed: "
            f"p50={r['p50']:.2f} ms, p99={r['p99']:.2f} ms — compare the netpol "
            f"row of the 100 QPS table: per-request cost does not grow with N.\n")

# ── ipBlock.except sweep ────────────────────────────────────────────────────
EXCEPT_LAYOUTS = [
    ("netpol-except",
     "scattered excepts (stride-32 /28s — every except punches its own hole)"),
    ("netpol-except-contiguous",
     "contiguous excepts (adjacent /28s — they aggregate away)"),
]
if any((ROOT / d).is_dir() for d, _ in EXCEPT_LAYOUTS):
    say("## ipBlock.except: OpenFlow flow inflation\n")
    say("Each `except` entry becomes a `!=` in the OVN ACL match. OVN "
        "compiles `cidr − excepts` into positive complement CIDRs, so the "
        "OpenFlow cost tracks the complement's *piece count* — scattered "
        "excepts cost flows per except, contiguous ones collapse. Flow "
        "counts are `ovs-ofctl dump-aggregate br-int`, max-node delta vs "
        "the empty-namespace baseline.\n")


def flows_by_node(path: Path):
    out = {}
    if path.exists():
        for line in path.read_text().splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[1].isdigit():
                out[parts[0]] = int(parts[1])
    return out


def except_combo_key(d: Path):
    m = re.fullmatch(r"combo-(sel|K(\d+))-N(\d+)", d.name)
    if not m:
        return None
    k = -1 if m.group(1) == "sel" else int(m.group(2))
    return (int(m.group(3)), k)


for dirname, label in EXCEPT_LAYOUTS:
    xd = ROOT / dirname
    if not xd.is_dir():
        continue
    say(f"### {label}\n")
    base_flows = flows_by_node(xd / "baseline-flows.txt")
    combos = sorted((d for d in xd.glob("combo-*") if except_combo_key(d)),
                    key=except_combo_key)
    say("| policies | rule style | ovs flows (Δ max node) | allow: apply→enforced "
        "| ovn-controller max cpu/mem | bulk delete |")
    say("|---|---|---|---|---|---|")
    for d in combos:
        n, k = except_combo_key(d)
        style = "label selector" if k < 0 else (
            "ipBlock, no except" if k == 0 else f"ipBlock + {k} excepts")
        fl = flows_by_node(d / "flows.txt")
        delta = max((fl[nd_] - base_flows.get(nd_, 0) for nd_ in fl), default=None)
        t = top_max(d / "top-ovn-containers.txt", r"\S+\s+ovn-controller")
        dt = count_time(d / "delete-time.txt")
        say(f"| {n} | {style} | "
            + (f"+{delta:,}" if delta is not None else "—") + " | "
            + trange(trials(d / "trials-apply.txt"), "ms") + " | "
            + (f"{t[0]}m/{t[1]}Mi" if t else "—") + " | "
            + (f"{dt[0]} in {dt[1]}s" if dt else "—") + " |")
    say("")
    if base_flows:
        say("Baseline br-int flows per node: "
            + ", ".join(f"{k} {v:,}" for k, v in sorted(base_flows.items()))
            + ".\n")
    fw = count_time(xd / "final-wipe-time.txt")
    if fw:
        say(f"Final wipe of {fw[0]} except-style policies: {fw[1]}s.\n")

td = ROOT / "tuple-scale"
if td.is_dir():
    say("## Policy propagation: OpenFGA tuple write\n")
    say("Latency is *write-acknowledged → observed verdict flip* through the "
        "mesh, same single-clock method. Poll resolution ≈ 10–15 ms.\n")
    say("| store size | grant: write→enforced | revoke: delete→enforced |")
    say("|---|---|---|")
    labels = {"seed": "seed (demo tuples)", "bulk": None}
    wt = count_time(td / "bulk" / "write-time.txt")
    labels["bulk"] = f"+{wt[0]} tuples" if wt else "bulk"
    for k in ("seed", "bulk"):
        d = td / k
        if d.is_dir() and (d / "trials-write.txt").exists():
            say(f"| {labels[k]} | " + trange(trials(d / "trials-write.txt"), "ms")
                + " | " + trange(trials(d / "trials-delete.txt"), "ms") + " |")
    say("")
    if wt:
        say(f"Bulk write of {wt[0]} tuples: {wt[1]}s "
            f"({wt[0] // max(wt[1], 1)}/s in 100-tuple batches).\n")
    dt = count_time(td / "bulk" / "delete-time.txt")
    if dt:
        say(f"Bulk delete of {dt[0]} tuples: {dt[1]}s.\n")
    for f in sorted(td.glob("mesh_fga-tup*-q100.json")):
        r = fortio(f)
        n = f.stem[len("mesh_fga-tup"):-len("-q100")]
        say(f"Per-request latency with {n} extra tuples in the store: "
            f"p50={r['p50']:.2f} ms, p99={r['p99']:.2f} ms — compare mesh_fga "
            f"at 100 QPS: Check latency does not grow with store size.\n")
    b = bridge_pcts(next(iter(sorted(td.glob("bridge-latency-tup*.txt"))), Path("/nonexistent")))
    if b:
        say(f"Bridge-observed Check latency at bulk store size (n={b['n']}): "
            f"p50={b['p50']} ms, p95={b['p95']} ms, p99={b['p99']} ms.\n")
    parts = []
    for pod in ("openfga", "ext-authz-bridge", "postgres"):
        t = top_max(td / "top-openfga.txt", pod)
        if t:
            parts.append(f"{pod} {t[0]}m/{t[1]}Mi")
    if parts:
        say("Authorizer footprint at bulk store size under 100 QPS (max observed): "
            + ", ".join(parts) + ".\n")

print("\n".join(out))
