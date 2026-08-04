// ext-authz-bridge translates Envoy's external-authorization protocol into
// OpenFGA Check calls. It is the entire integration surface between the mesh
// and OpenFGA, kept deliberately small so the walkthrough can read it top to
// bottom:
//
//	Envoy CheckRequest ──► SPIFFE identities + HTTP attributes
//	                   ──► OpenFGA Check(user, relation, object)
//	                   ──► allow / deny (fail-closed)
//
// Two decision modes, selected by who the DESTINATION of the request is:
//
//	sidecar inbound:  user=workload:<ns>/<sa>  can_call   service:<dest-sa>
//	egress gateway:   user=workload:<ns>/<sa>  can_reach  host:<http-host>
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"time"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
)

type bridge struct {
	fgaURL           string
	fgaToken         string
	storeName        string
	storeID          atomic.Value // string; resolved by name in the background
	egressPrincipals map[string]bool
	httpClient       *http.Client
}

// spiffeWorkload parses "spiffe://<trust-domain>/ns/<ns>/sa/<sa>" (Envoy keeps
// the scheme; Istio's own policy syntax drops it — accept both) into "<ns>/<sa>".
func spiffeWorkload(principal string) (string, error) {
	p := strings.TrimPrefix(principal, "spiffe://")
	seg := strings.Split(p, "/")
	var ns, sa string
	for i := 0; i+1 < len(seg); i++ {
		switch seg[i] {
		case "ns":
			ns = seg[i+1]
		case "sa":
			sa = seg[i+1]
		}
	}
	if ns == "" || sa == "" {
		return "", fmt.Errorf("principal %q is not a workload SPIFFE identity", principal)
	}
	return ns + "/" + sa, nil
}

// Check implements envoy.service.auth.v3.Authorization.
func (b *bridge) Check(ctx context.Context, req *authv3.CheckRequest) (*authv3.CheckResponse, error) {
	started := time.Now()
	attrs := req.GetAttributes()
	src := attrs.GetSource().GetPrincipal()
	dst := attrs.GetDestination().GetPrincipal()
	httpReq := attrs.GetRequest().GetHttp()

	caller, err := spiffeWorkload(src)
	if err != nil {
		return b.deny(fmt.Sprintf("unidentified caller: %v", err)), nil
	}
	user := "workload:" + caller

	var relation, object string
	if dstWorkload, err := spiffeWorkload(dst); err == nil && b.egressPrincipals[dstWorkload] {
		// Request is arriving at the egress gateway: authorize the ORIGINAL
		// workload (identity preserved by the ISTIO_MUTUAL mesh→gateway leg)
		// against the external host it is trying to reach.
		relation = "can_reach"
		host := httpReq.GetHost()
		if i := strings.IndexByte(host, ':'); i >= 0 {
			host = host[:i]
		}
		object = "host:" + host
	} else if err == nil {
		// Sidecar inbound: authorize caller workload against the destination
		// service. Demo convention: ServiceAccount name == Service name.
		relation = "can_call"
		object = "service:" + dstWorkload[strings.LastIndexByte(dstWorkload, '/')+1:]
	} else {
		return b.deny(fmt.Sprintf("unidentified destination: %v", err)), nil
	}

	allowed, err := b.fgaCheck(ctx, user, relation, object)
	verdict := "deny"
	if err != nil {
		// Fail closed: no answer from OpenFGA means no access.
		log.Printf("DECISION deny user=%s relation=%s object=%s error=%v", user, relation, object, err)
		return b.deny("authorization unavailable"), nil
	}
	if allowed {
		verdict = "allow"
	}
	log.Printf("DECISION %s user=%s relation=%s object=%s method=%s path=%s latency=%s",
		verdict, user, relation, object, httpReq.GetMethod(), httpReq.GetPath(), time.Since(started).Round(time.Millisecond))

	if !allowed {
		return b.deny(fmt.Sprintf("OpenFGA: %s does not have %s on %s", user, relation, object)), nil
	}
	return &authv3.CheckResponse{Status: &status.Status{Code: int32(codes.OK)}}, nil
}

func (b *bridge) deny(reason string) *authv3.CheckResponse {
	return &authv3.CheckResponse{
		Status: &status.Status{Code: int32(codes.PermissionDenied), Message: reason},
		HttpResponse: &authv3.CheckResponse_DeniedResponse{
			DeniedResponse: &authv3.DeniedHttpResponse{
				Status: &typev3.HttpStatus{Code: typev3.StatusCode_Forbidden},
				Body:   reason + "\n",
			},
		},
	}
}

// fgaCheck calls POST /stores/{id}/check on the OpenFGA HTTP API.
func (b *bridge) fgaCheck(ctx context.Context, user, relation, object string) (bool, error) {
	storeID, _ := b.storeID.Load().(string)
	if storeID == "" {
		return false, fmt.Errorf("store %q not resolved yet", b.storeName)
	}
	body, _ := json.Marshal(map[string]any{
		"tuple_key": map[string]string{"user": user, "relation": relation, "object": object},
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		b.fgaURL+"/stores/"+storeID+"/check", strings.NewReader(string(body)))
	if err != nil {
		return false, err
	}
	req.Header.Set("Content-Type", "application/json")
	if b.fgaToken != "" {
		req.Header.Set("Authorization", "Bearer "+b.fgaToken)
	}
	resp, err := b.httpClient.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false, fmt.Errorf("openfga check returned %s", resp.Status)
	}
	var out struct {
		Allowed bool `json:"allowed"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return false, err
	}
	return out.Allowed, nil
}

// resolveStore polls GET /stores until a store named storeName exists, so the
// bridge can start before the bootstrap has run (denying, fail-closed, until
// the store appears).
func (b *bridge) resolveStore() {
	for {
		id, err := b.lookupStore()
		if err == nil {
			b.storeID.Store(id)
			log.Printf("resolved store %q -> %s", b.storeName, id)
			return
		}
		log.Printf("store %q not resolved yet (%v); retrying in 5s", b.storeName, err)
		time.Sleep(5 * time.Second)
	}
}

func (b *bridge) lookupStore() (string, error) {
	req, err := http.NewRequest(http.MethodGet, b.fgaURL+"/stores?page_size=100", nil)
	if err != nil {
		return "", err
	}
	if b.fgaToken != "" {
		req.Header.Set("Authorization", "Bearer "+b.fgaToken)
	}
	resp, err := b.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("list stores returned %s", resp.Status)
	}
	var out struct {
		Stores []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"stores"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}
	for _, s := range out.Stores {
		if s.Name == b.storeName {
			return s.ID, nil
		}
	}
	return "", fmt.Errorf("no store named %q", b.storeName)
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	b := &bridge{
		fgaURL:           strings.TrimSuffix(envOr("FGA_API_URL", "http://openfga.openfga.svc.cluster.local:8080"), "/"),
		fgaToken:         os.Getenv("FGA_API_TOKEN"),
		storeName:        envOr("FGA_STORE_NAME", "ossm-openfga-demo"),
		egressPrincipals: map[string]bool{},
		httpClient:       &http.Client{Timeout: 2 * time.Second},
	}
	for _, p := range strings.Split(os.Getenv("EGRESS_GATEWAY_PRINCIPALS"), ",") {
		// accept both "cluster.local/ns/x/sa/y" and bare "x/y"
		if p = strings.TrimSpace(p); p == "" {
			continue
		}
		if w, err := spiffeWorkload(p); err == nil {
			b.egressPrincipals[w] = true
		} else {
			b.egressPrincipals[p] = true
		}
	}
	go b.resolveStore()

	addr := envOr("LISTEN_ADDR", ":9191")
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("listen %s: %v", addr, err)
	}
	srv := grpc.NewServer()
	authv3.RegisterAuthorizationServer(srv, b)
	log.Printf("ext-authz bridge listening on %s (store=%q, fga=%s)", addr, b.storeName, b.fgaURL)
	log.Fatal(srv.Serve(lis))
}
