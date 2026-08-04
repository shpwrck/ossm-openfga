#!/usr/bin/env bash
# Stretch goal: the NetworkPolicy-vs-OpenFGA comparison harness.
# Planned shape (see docs/walkthrough/06-netpol-comparison.md):
#   1. kube-burner-ocp network-policy workload + netpolLatency measurement
#      (policy propagation at N policies)
#   2. fortio fixed-QPS runs: baseline / netpol-only / mesh / mesh+ext_authz
#      (per-request overhead)
#   3. resource sampling: ovnkube/ovn-controller vs bridge+OpenFGA
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
die "perf harness not implemented yet — see docs/walkthrough/06-netpol-comparison.md for the design"
