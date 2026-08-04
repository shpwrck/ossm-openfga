# Troubleshooting

!!! info "🚧 Populated as the automation is validated on-cluster"
    Entries follow the format: symptom → likely cause → check → fix.

## General diagnostic entry points

```bash
# Is the mesh healthy?
oc get istio,istiorevision -A

# Is Connectivity Link healthy?
oc get kuadrant -A -o yaml | grep -A5 status

# Is OpenFGA answering?
oc -n openfga port-forward svc/openfga 8080:8080 &
curl -s localhost:8080/healthz

# What did the ext_authz bridge decide? (every Check is logged)
oc -n openfga logs deploy/ext-authz-bridge --tail=50

# What did Authorino decide at ingress?
oc -n kuadrant-system logs deploy/authorino --tail=50
```
