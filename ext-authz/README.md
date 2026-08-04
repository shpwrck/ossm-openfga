# ext-authz-bridge

The Envoy [external authorization](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/security/ext_authz_filter)
→ [OpenFGA](https://openfga.dev) bridge: a small gRPC server that Istio's
`CUSTOM` AuthorizationPolicies delegate to, registered in the mesh as
extensionProvider `openfga-ext-authz`.

Per request it derives:

| Enforcement point | user | relation | object |
|---|---|---|---|
| sidecar inbound | `workload:<ns>/<sa>` from `source.principal` | `can_call` | `service:<dest-sa>` from `destination.principal` |
| egress gateway | `workload:<ns>/<sa>` (identity preserved by ISTIO_MUTUAL) | `can_reach` | `host:<Host header>` |

and answers with OpenFGA's `Check`. **Fail-closed**: no reachable OpenFGA, no
store, or an unidentifiable peer all mean deny. Every decision is logged.

Configuration (env): `FGA_API_URL`, `FGA_STORE_NAME` (store id is discovered
by name), `FGA_API_TOKEN`, `EGRESS_GATEWAY_PRINCIPALS`, `LISTEN_ADDR`.

```bash
go test ./...      # unit tests
go build ./...     # static binary; Dockerfile builds the distroless image
```

Design notes: the archived `openfga/openfga-envoy` (Apache-2.0) validated the
extractor idea; this implementation reads `source.principal` directly rather
than parsing XFCC headers, which is the more robust source under Istio mTLS.
