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

// failingResponder's Respond fails at once (e.g. the socket died).
type failingResponder struct{}

func (failingResponder) Add(dnssd.Service) (dnssd.ServiceHandle, error) { return nil, nil }
func (failingResponder) Remove(dnssd.ServiceHandle)                     {}
func (failingResponder) Respond(context.Context) error                  { return errors.New("socket closed") }
func (failingResponder) Debug(context.Context, dnssd.ReadFunc)          {}

func TestRespondErrorRebindsOnNextTick(t *testing.T) {
	origNew, origTick := newResponder, recheckInterval
	var mu sync.Mutex
	binds := 0
	newResponder = func() (dnssd.Responder, error) {
		mu.Lock()
		defer mu.Unlock()
		binds++
		return failingResponder{}, nil
	}
	recheckInterval = 10 * time.Millisecond
	t.Cleanup(func() { newResponder, recheckInterval = origNew, origTick })

	r := New("x", 8443, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := r.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		mu.Lock()
		n := binds
		mu.Unlock()
		if n >= 3 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("binds = %d; a failed responder must be rebound on the next tick", n)
		}
		time.Sleep(5 * time.Millisecond)
	}
	r.Stop()
}
