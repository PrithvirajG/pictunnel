package discovery

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/brutella/dnssd"
)

func TestDiscoveryTXT(t *testing.T) {
	txt := TXT("01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f", "0.1.0", "xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc")
	want := map[string]string{
		"sid":  "01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f",
		"v":    "0.1.0",
		"api":  "1",
		"fp16": "xKecCxNIWtM6GstV",
	}
	if len(txt) != len(want) {
		t.Fatalf("TXT = %v, want %v", txt, want)
	}
	for k, v := range want {
		if txt[k] != v {
			t.Fatalf("TXT[%s] = %q, want %q (all: %v)", k, txt[k], v, txt)
		}
	}
	if short := TXT("sid", "dev", "abc"); short["fp16"] != "abc" {
		t.Fatalf("short fingerprint: %v", short)
	}
}

// syncBuf is a goroutine-safe log sink.
type syncBuf struct {
	mu sync.Mutex
	b  strings.Builder
}

func (s *syncBuf) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuf) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

func TestStartBindFailureIsAWarning(t *testing.T) {
	orig := newResponder
	newResponder = func() (dnssd.Responder, error) {
		return nil, errors.New("listen udp4 224.0.0.251:5353: bind: address already in use")
	}
	t.Cleanup(func() { newResponder = orig })

	var logs syncBuf
	r := New("Home server", 8443, TXT("sid", "0.1.0", "fp"), slog.New(slog.NewTextHandler(&logs, nil)))
	if err := r.Start(context.Background()); err != nil {
		t.Fatalf("Start with a bind failure = %v, want nil", err)
	}
	r.Stop()
	r.Stop() // idempotent
	if !strings.Contains(logs.String(), "level=WARN") || !strings.Contains(logs.String(), "address already in use") {
		t.Fatalf("no bind warning logged: %s", logs.String())
	}
}

func TestStartStopReal(t *testing.T) {
	// Whether or not the multicast port can be bound here, Start never
	// fails and Stop returns promptly.
	r := New("PicTunnel test", 8443, TXT("sid", "dev", "fingerprint-0123456789"), slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := r.Start(context.Background()); err != nil {
		t.Fatalf("Start = %v", err)
	}
	time.Sleep(50 * time.Millisecond)
	done := make(chan struct{})
	go func() { r.Stop(); close(done) }()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("Stop did not return")
	}
}

func TestStopWithoutStart(t *testing.T) {
	New("x", 1, nil, nil).Stop()
}
