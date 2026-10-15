package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/app"
	"github.com/PrithvirajG/pictunnel/server/internal/config"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
)

func TestServeVersionCLI(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run(context.Background(), []string{"version"}, nil, &out, &errOut); code != 0 {
		t.Fatalf("exit code %d, stderr %q", code, errOut.String())
	}
	if out.String() != "pictunnel dev\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}

func TestRunUnknownCommandShowsUsage(t *testing.T) {
	for _, args := range [][]string{nil, {"frobnicate"}, {"reset-password"}} {
		var out, errOut bytes.Buffer
		if code := run(context.Background(), args, nil, &out, &errOut); code != 2 {
			t.Fatalf("%v: exit code %d, want 2", args, code)
		}
		if !strings.Contains(errOut.String(), "pictunnel serve") {
			t.Fatalf("%v: stderr = %q", args, errOut.String())
		}
	}
}

// syncBuf is a goroutine-safe writer.
type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
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

func serveFlags(dir string) []string {
	return []string{"--data-dir", dir, "--server.https-addr", "127.0.0.1:0", "--server.local-addr", "127.0.0.1:0",
		"--discovery.mdns=false", "--log.format", "text"}
}

func TestServeCLI(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var out, errOut syncBuf
	done := make(chan int, 1)
	go func() { done <- run(ctx, append([]string{"serve"}, serveFlags(dir)...), nil, &out, &errOut) }()

	re := regexp.MustCompile(`local http://(127\.0\.0\.1:\d+)`)
	var local string
	deadline := time.Now().Add(20 * time.Second)
	for local == "" {
		if m := re.FindStringSubmatch(out.String()); m != nil {
			local = m[1]
			break
		}
		select {
		case code := <-done:
			t.Fatalf("serve exited %d: %s %s", code, out.String(), errOut.String())
		default:
		}
		if time.Now().After(deadline) {
			t.Fatalf("serve not listening: %s %s", out.String(), errOut.String())
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !strings.Contains(out.String(), "PicTunnel-Setup-Token: ") || !strings.Contains(out.String(), "open http://"+local+" ") {
		t.Errorf("first boot did not print the setup token and URL: %s", out.String())
	}
	resp, err := http.Get("http://" + local + "/api/v1/server/info")
	if err != nil {
		t.Fatal(err)
	}
	var info struct{ Version string }
	_ = json.NewDecoder(resp.Body).Decode(&info)
	resp.Body.Close()
	if resp.StatusCode != 200 || info.Version != "dev" {
		t.Fatalf("server info %d %+v", resp.StatusCode, info)
	}
	cancel()
	select {
	case code := <-done:
		if code != 0 {
			t.Fatalf("serve exit %d: %s", code, errOut.String())
		}
	case <-time.After(40 * time.Second):
		t.Fatal("serve did not stop")
	}
}

func TestResetPasswordCLI(t *testing.T) {
	dir := t.TempDir()
	cfg, err := config.Load(serveFlags(dir), nil)
	if err != nil {
		t.Fatal(err)
	}
	a, err := app.New(context.Background(), app.Options{Config: cfg, Log: slog.New(slog.NewTextHandler(io.Discard, nil))})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.Users().Create(context.Background(), "alice", "correct horse battery", "", service.RoleUser); err != nil {
		t.Fatal(err)
	}
	// While the server holds the lock, reset-password refuses.
	var out, errOut bytes.Buffer
	if code := run(context.Background(), append([]string{"reset-password", "alice"}, serveFlags(dir)...), nil, &out, &errOut); code != 1 ||
		!strings.Contains(errOut.String(), "another pictunnel") {
		t.Fatalf("reset while locked: %d %q", code, errOut.String())
	}
	_ = a.Close()

	out.Reset()
	errOut.Reset()
	if code := run(context.Background(), append([]string{"reset-password", "alice"}, serveFlags(dir)...), nil, &out, &errOut); code != 0 {
		t.Fatalf("reset: %d %q", code, errOut.String())
	}
	m := regexp.MustCompile(`New password for alice: (\S+)`).FindStringSubmatch(out.String())
	if m == nil {
		t.Fatalf("no password printed: %q", out.String())
	}
	b, err := app.New(context.Background(), app.Options{Config: cfg, Log: slog.New(slog.NewTextHandler(io.Discard, nil))})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	if _, _, _, err := b.Auth().Login(context.Background(), "alice", m[1],
		service.DeviceInfo{Name: "x", Platform: "android", AppVersion: "0.1.0"}); err != nil {
		t.Fatalf("login with the new password: %v", err)
	}
	if code := run(context.Background(), []string{"reset-password", "bob", "--data-dir", filepath.Join(dir, "other"), "--discovery.mdns=false"}, nil, &out, &errOut); code != 1 {
		t.Fatalf("unknown user exit %d", code)
	}
}
