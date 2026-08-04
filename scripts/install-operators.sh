#!/usr/bin/env bash
# Installs the OSSM 3 + Connectivity Link operators and instantiates the mesh
# control plane and Kuadrant. Idempotent — and it coexists with a cluster that
# already runs a mesh: an existing operator install or Istio/IstioCNI control
# plane is adopted (extended additively), never overwritten.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_login

# On OCP 4.19+ the cluster ingress operator may already own a
# servicemeshoperator3 subscription (it backs the openshift-default
# GatewayClass) — and the operator can also be present with no Subscription at
# all (installed by hand, or its Subscription was later deleted; the CSV keeps
# running either way). Don't fight any of these shapes.
if oc -n openshift-operators get subscription servicemeshoperator3 >/dev/null 2>&1; then
  info "servicemeshoperator3 subscription already exists — leaving it as-is"
  wait_csv openshift-operators servicemeshoperator3
elif oc -n openshift-operators get csv -o name 2>/dev/null | grep -q servicemeshoperator3; then
  info "OSSM operator already installed without a subscription — leaving it as-is"
  wait_csv openshift-operators servicemeshoperator3 # CSV-name fallback covers the missing subscription
else
  oc apply -f "$REPO_ROOT/deploy/operators/subscriptions/ossm-subscription.yaml"
  wait_csv openshift-operators servicemeshoperator3
fi

oc apply -f "$REPO_ROOT/deploy/operators/subscriptions/rhcl-namespace.yaml"
oc apply -f "$REPO_ROOT/deploy/operators/subscriptions/rhcl-operatorgroup.yaml"
oc apply -f "$REPO_ROOT/deploy/operators/subscriptions/rhcl-subscription.yaml"
wait_csv kuadrant-system rhcl-operator

# CRDs may take a moment to be served after the CSVs succeed
retry 10 10 oc apply -f "$REPO_ROOT/deploy/operators/instances/namespaces.yaml"

# Control planes: create ours on a blank cluster; on a cluster that already
# runs a mesh, adopt it — register our extensionProvider, touch nothing else
# (a blind `oc apply` over a foreign Istio CR would strip its version pin,
# profile, and multi-cluster config via last-applied pruning).
if oc get istiocni default >/dev/null 2>&1; then
  info "IstioCNI default already exists — leaving it as-is"
else
  retry 10 10 oc apply -f "$REPO_ROOT/deploy/operators/instances/istio-cni.yaml"
fi
if oc get istio default >/dev/null 2>&1; then
  info "Istio default already exists — registering the openfga-ext-authz extensionProvider only"
  ensure_extension_provider
else
  retry 10 10 oc apply -f "$REPO_ROOT/deploy/operators/instances/istio.yaml"
fi
retry 10 10 oc apply -f "$REPO_ROOT/deploy/operators/instances/kuadrant.yaml"

info "waiting for control planes"
oc wait istio/default --for=condition=Ready --timeout=300s
oc wait istiocni/default --for=condition=Ready --timeout=300s
oc -n istio-system rollout status deploy/istiod --timeout=300s
oc -n kuadrant-system wait kuadrant/kuadrant --for=condition=Ready --timeout=300s
ok "operators and control planes ready"
