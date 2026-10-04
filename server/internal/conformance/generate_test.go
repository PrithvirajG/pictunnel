package conformance

import (
	"bytes"
	"io"
	"testing"
)

func TestCounterReaderProducesPattern(t *testing.T) {
	got, err := io.ReadAll(CounterReader(Generate{Pattern: "counter", Seed: 1, Length: 258}, 0, 258))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 258 {
		t.Fatalf("len = %d, want 258", len(got))
	}
	if got[0] != 1 || got[254] != 255 || got[255] != 0 || got[257] != 2 {
		t.Fatalf("unexpected bytes: %v ... %v", got[:3], got[254:])
	}
}

func TestCounterReaderRangeMatchesSlice(t *testing.T) {
	g := Generate{Pattern: "counter", Length: 1000}
	full, _ := io.ReadAll(CounterReader(g, 0, 1000))
	part, _ := io.ReadAll(CounterReader(g, 300, 700))
	if !bytes.Equal(part, full[300:700]) {
		t.Fatal("a range must equal the same slice of the full stream")
	}
}
