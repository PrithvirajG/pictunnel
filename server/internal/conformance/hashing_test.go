package conformance

import (
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/contenthash"
)

func TestHashingVectors(t *testing.T) {
	dir := ProtocolDir()
	cases, err := LoadHashingCases(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(cases) < 8 {
		t.Fatalf("found %d hashing cases, want at least 8", len(cases))
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			r, err := c.Input.Open(dir)
			if err != nil {
				t.Fatal(err)
			}
			defer r.Close()
			got, err := contenthash.HashReader(r)
			if err != nil {
				t.Fatal(err)
			}
			if got != c.ExpectedSHA256 {
				t.Errorf("got %s, want %s", got, c.ExpectedSHA256)
			}
		})
	}
}
