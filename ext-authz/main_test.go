package main

import "testing"

func TestSpiffeWorkload(t *testing.T) {
	cases := []struct {
		in, want string
		wantErr  bool
	}{
		{in: "spiffe://cluster.local/ns/demo/sa/storefront", want: "demo/storefront"},
		// Istio policy syntax omits the scheme; Envoy attributes include it — both must parse
		{in: "cluster.local/ns/istio-egress/sa/egress-gateway", want: "istio-egress/egress-gateway"},
		{in: "spiffe://example.org/ns/a/sa/b", want: "a/b"},
		{in: "spiffe://cluster.local/workload-id", wantErr: true},
		{in: "", wantErr: true},
	}
	for _, c := range cases {
		got, err := spiffeWorkload(c.in)
		if c.wantErr != (err != nil) {
			t.Errorf("spiffeWorkload(%q) error = %v, wantErr %v", c.in, err, c.wantErr)
			continue
		}
		if got != c.want {
			t.Errorf("spiffeWorkload(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
