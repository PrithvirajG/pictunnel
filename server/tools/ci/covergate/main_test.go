package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const profile = `mode: set
example.com/m/a/a.go:1.1,2.1 3 1
example.com/m/a/a.go:3.1,4.1 1 0
example.com/m/b/b.go:1.1,2.1 2 0
example.com/m/b/b.go:1.1,2.1 2 1
example.com/m/gen/g.go:1.1,2.1 50 0
`

func writeProfile(t *testing.T) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "cover.out")
	if err := os.WriteFile(p, []byte(profile), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestGatePassesAndMergesDuplicateBlocks(t *testing.T) {
	var out bytes.Buffer
	if err := run([]string{"-min", "75", "-exclude", "/gen$", writeProfile(t)}, &out); err != nil {
		t.Fatalf("%v\n%s", err, out.String())
	}
	// a: 3/4 = 75%; b: the duplicate block is covered once → 100%.
	for _, want := range []string{" 75.0%  example.com/m/a", "100.0%  example.com/m/b", " 83.3%  total"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("output lacks %q:\n%s", want, out.String())
		}
	}
	if strings.Contains(out.String(), "/gen") {
		t.Errorf("excluded package reported:\n%s", out.String())
	}
}

func TestGateFailsBelowMinimum(t *testing.T) {
	var out bytes.Buffer
	err := run([]string{"-min", "80", "-exclude", "/gen$", writeProfile(t)}, &out)
	if err == nil || !strings.Contains(err.Error(), "example.com/m/a") || strings.Contains(err.Error(), "total") {
		t.Fatalf("err %v\n%s", err, out.String())
	}
	// Without the exclusion the generated package drags the total down.
	if err := run([]string{"-min", "80", writeProfile(t)}, &out); err == nil || !strings.Contains(err.Error(), "total") {
		t.Fatalf("err %v", err)
	}
}

func TestGateRejectsMalformedProfile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "bad.out")
	if err := os.WriteFile(p, []byte("mode: set\nnot a profile line\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{p}, &bytes.Buffer{}); err == nil {
		t.Fatal("malformed profile accepted")
	}
}
