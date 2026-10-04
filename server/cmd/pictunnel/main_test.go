package main

import (
	"bytes"
	"testing"
)

func TestRunVersion(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"version"}, &out, &errOut); code != 0 {
		t.Fatalf("exit code %d, stderr %q", code, errOut.String())
	}
	if out.String() != "pictunnel dev\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}

func TestRunUnknownCommandShowsUsage(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"serve"}, &out, &errOut); code != 2 {
		t.Fatalf("exit code %d, want 2", code)
	}
	if errOut.String() != "usage: pictunnel version\n" {
		t.Fatalf("stderr = %q", errOut.String())
	}
}
