package contenthash

import (
	"errors"
	"strings"
	"testing"
)

func TestHashReaderKnownVectors(t *testing.T) {
	cases := map[string]string{
		"":    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		"abc": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	}
	for in, want := range cases {
		got, err := HashReader(strings.NewReader(in))
		if err != nil {
			t.Fatalf("HashReader(%q): %v", in, err)
		}
		if got != want {
			t.Errorf("HashReader(%q) = %s, want %s", in, got, want)
		}
	}
}

type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, errors.New("disk on fire") }

func TestHashReaderPropagatesReadErrors(t *testing.T) {
	_, err := HashReader(failingReader{})
	if err == nil || !strings.Contains(err.Error(), "disk on fire") {
		t.Fatalf("expected the read error, got %v", err)
	}
}
