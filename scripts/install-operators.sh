#!/usr/bin/env bash
# Installs the OSSM 3 + Connectivity Link operators and instantiates the mesh
# control plane and Kuadrant. Idempotent.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_login

# On OCP 4.19+ the cluster ingress operator may already own a
# servicemeshoperator3 subscription (it backs the openshift-default
# GatewayClass) — don't fight it.
if oc -n openshift-operators get subscription servicemeshoperator3 >/dev/null 2>&1; then
  info "servicemeshoperator3 subscription already exists — leaving it as-is"
else
  oc apply -f "$REPO_ROOT/deploy/operators/subscriptions/ossm-subscription.yaml"
fi
oc apply -f "$REPO_ROOT/deploy/operators/subscriptions/rhcl-namespace.yaml"
oc apply -f "$REPO_ROOT/deploy/operators/subscriptions/rhcl-operatorgroup.yaml"
oc apply -f "$REPO_ROOT/deploy/operators/subscriptions/rhcl-subscription.yaml"

wait_csv openshift-operators servicemeshoperator3
wait_csv kuadrant-system rhcl-operator

# CRDs may take a moment to be served after the CSVs succeed
retry 10 10 oc apply -k "$REPO_ROOT/deploy/operators/instances"

info "waiting for control planes"
oc wait istio/default --for=condition=Ready --timeout=300s
oc wait istiocni/default --for=condition=Ready --timeout=300s
oc -n kuadrant-system wait kuadrant/kuadrant --for=condition=Ready --timeout=300s
ok "operators and control planes ready"
