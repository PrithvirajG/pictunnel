package conformance

import (
	"errors"
	"slices"
	"testing"
)

func TestPairingVectors(t *testing.T) {
	cases, err := LoadPairingCases(ProtocolDir())
	if err != nil {
		t.Fatal(err)
	}
	if len(cases) < 12 {
		t.Fatalf("found %d pairing cases, want at least 12", len(cases))
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			got, err := ParsePairURI(c.URI)
			switch c.Expect.Parse {
			case "error":
				var pe *PairError
				if !errors.As(err, &pe) {
					t.Fatalf("err = %v, want PairError %q", err, c.Expect.Error)
				}
				if pe.Code != c.Expect.Error {
					t.Fatalf("error code = %q, want %q", pe.Code, c.Expect.Error)
				}
				return
			case "ok":
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
			default:
				t.Fatalf("unknown expect.parse %q", c.Expect.Parse)
			}
			if c.Expect.ServerID != "" && got.ServerID != c.Expect.ServerID {
				t.Errorf("server_id = %q, want %q", got.ServerID, c.Expect.ServerID)
			}
			if c.Expect.Code != "" && got.Code != c.Expect.Code {
				t.Errorf("code = %q, want %q", got.Code, c.Expect.Code)
			}
			if c.Expect.Fingerprint != "" && got.Fingerprint != c.Expect.Fingerprint {
				t.Errorf("fingerprint = %q, want %q", got.Fingerprint, c.Expect.Fingerprint)
			}
			if c.Expect.Endpoints != nil && !slices.Equal(got.Endpoints, c.Expect.Endpoints) {
				t.Errorf("endpoints = %v, want %v", got.Endpoints, c.Expect.Endpoints)
			}
			if c.Connection != nil {
				if c.Expect.AcceptConnection == nil {
					t.Fatal("connection present without expect.accept_connection")
				}
				acc := AcceptConnection(got.Fingerprint, c.Connection.SystemTrusted, c.Connection.SPKISHA256)
				if acc != *c.Expect.AcceptConnection {
					t.Errorf("accept_connection = %v, want %v", acc, *c.Expect.AcceptConnection)
				}
			}
		})
	}
}

func TestParsePairURIErrorOrder(t *testing.T) {
	// Every rule broken at once: the first rule in P§10.3 order wins.
	_, err := ParsePairURI("pictunnel://pair?v=2&code=bad&u=http%3A%2F%2Fx")
	var pe *PairError
	if !errors.As(err, &pe) || pe.Code != "unsupported_version" {
		t.Fatalf("err = %v, want unsupported_version", err)
	}
	_, err = ParsePairURI("pictunnel://pair?v=1&sid=s&code=K7Q2-M9XD-4T&fp=f&u=https%3A%2F%2Fa&u=http%3A%2F%2Fb")
	if !errors.As(err, &pe) || pe.Code != "insecure_endpoint" {
		t.Fatalf("err = %v, want insecure_endpoint for a later insecure u", err)
	}
}
