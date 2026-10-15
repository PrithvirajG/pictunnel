package app_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/app"
	"github.com/PrithvirajG/pictunnel/server/internal/clock/clocktest"
	"github.com/PrithvirajG/pictunnel/server/internal/config"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
)

var t0 = time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)

const pw = "correct horse battery"

// opts returns boot options on fresh temp dirs: fake clock, no mDNS, no
// scheduler, loopback listeners on random ports.
func opts(t *testing.T) app.Options {
	t.Helper()
	root := t.TempDir()
	cfg := config.Default()
	cfg.DataDir = filepath.Join(root, "data")
	cfg.LibraryDir = filepath.Join(cfg.DataDir, "library")
	cfg.Server.Name = "Test server"
	cfg.Server.HTTPSAddr = "127.0.0.1:0"
	cfg.Server.LocalAddr = "127.0.0.1:0"
	cfg.Discovery.MDNS = false
	return app.Options{
		Config: cfg, Clock: clocktest.NewFake(t0), DisableScheduler: true,
		Log:       slog.New(slog.NewTextHandler(io.Discard, nil)),
		FreeSpace: func(string) (uint64, error) { return 1 << 40, nil },
	}
}

func boot(t *testing.T, o app.Options) *app.App {
	t.Helper()
	a, err := app.New(context.Background(), o)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = a.Close() })
	return a
}

func TestAppBootTwiceSameServerIDAndFingerprint(t *testing.T) {
	o := opts(t)
	a := boot(t, o)
	id, fp, secret := a.ServerID(), a.Fingerprint(), readFile(t, filepath.Join(o.Config.DataDir, "secret.key"))
	if len(id) != 36 || fp == "" {
		t.Fatalf("server id %q fingerprint %q", id, fp)
	}
	if len(secret) != 32 {
		t.Fatalf("secret.key is %d bytes", len(secret))
	}
	if runtime.GOOS != "windows" {
		fi, _ := os.Stat(filepath.Join(o.Config.DataDir, "secret.key"))
		if fi.Mode().Perm() != 0o600 {
			t.Fatalf("secret.key mode %v", fi.Mode().Perm())
		}
	}
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
	b := boot(t, o)
	if b.ServerID() != id || b.Fingerprint() != fp {
		t.Fatalf("second boot: id %q→%q fp %q→%q", id, b.ServerID(), fp, b.Fingerprint())
	}
	if !bytes.Equal(readFile(t, filepath.Join(o.Config.DataDir, "secret.key")), secret) {
		t.Fatal("secret.key rewritten")
	}
}

func TestSecondInstanceLocked(t *testing.T) {
	o := opts(t)
	a := boot(t, o)
	_, err := app.New(context.Background(), o)
	if err == nil || !strings.Contains(err.Error(), "another pictunnel") || !strings.Contains(err.Error(), "pictunnel.lock") {
		t.Fatalf("second instance: %v", err)
	}
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
	boot(t, o) // the lock is released on Close
}

// crashAt aborts at one failpoint.
type crashAt string

func (c crashAt) Hit(name string) error {
	if name == string(c) {
		return errors.New("crash")
	}
	return nil
}

func login(t *testing.T, a *app.App, user string) service.Principal {
	t.Helper()
	ctx := context.Background()
	if _, err := a.Users().Create(ctx, user, pw, "", service.RoleUser); err != nil {
		t.Fatal(err)
	}
	_, _, tp, err := a.Auth().Login(ctx, user, pw, service.DeviceInfo{Name: "Pixel", Platform: "android", AppVersion: "0.1.0"})
	if err != nil {
		t.Fatal(err)
	}
	p, err := a.Auth().AuthenticateBearer(ctx, tp.AccessToken)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func upload(t *testing.T, a *app.App, p service.Principal, content []byte, filename, mime string) (service.UploadView, error) {
	t.Helper()
	sum := sha256.Sum256(content)
	return a.Upload().Create(context.Background(), p, service.CreateInput{
		Length: int64(len(content)),
		Meta:   service.UploadMeta{SHA256: hex.EncodeToString(sum[:]), Filename: filename, Mime: mime},
		Body:   bytes.NewReader(content),
	})
}

func count(t *testing.T, a *app.App, q string, args ...any) int {
	t.Helper()
	var n int
	if err := a.Store().R.QueryRow(q, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestBootRecoversFinalizing(t *testing.T) {
	o := opts(t)
	o.Failpoints = crashAt(service.FPAfterTx1)
	a := boot(t, o)
	p := login(t, a, "alice")
	if _, err := upload(t, a, p, []byte("hello recovered world"), "a.jpg", "image/jpeg"); err == nil {
		t.Fatal("upload survived the failpoint")
	}
	if n := count(t, a, `SELECT COUNT(*) FROM upload_sessions WHERE state = 'finalizing'`); n != 1 {
		t.Fatalf("finalizing sessions after crash: %d", n)
	}
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}
	o.Failpoints = nil
	b := boot(t, o)
	if n := count(t, b, `SELECT COUNT(*) FROM upload_sessions WHERE state = 'finalizing'`); n != 0 {
		t.Fatalf("finalizing sessions after recovery: %d", n)
	}
	if n := count(t, b, `SELECT COUNT(*) FROM assets`); n != 1 {
		t.Fatalf("assets after recovery: %d", n)
	}
	entries, _ := os.ReadDir(filepath.Join(o.Config.DataDir, "uploads"))
	if len(entries) != 0 {
		t.Fatalf("staging files left: %v", entries)
	}
}

func TestSetupTokenRotatesUntilUserExists(t *testing.T) {
	o := opts(t)
	a := boot(t, o)
	tok1 := a.SetupToken()
	if tok1 == "" || !a.Users().CheckSetupToken(context.Background(), tok1) {
		t.Fatalf("first boot setup token %q", tok1)
	}
	_ = a.Close()
	b := boot(t, o)
	tok2 := b.SetupToken()
	if tok2 == "" || tok2 == tok1 || b.Users().CheckSetupToken(context.Background(), tok1) {
		t.Fatalf("second boot did not rotate the token: %q %q", tok1, tok2)
	}
	if _, err := b.Users().Setup(context.Background(), "admin", pw, ""); err != nil {
		t.Fatal(err)
	}
	_ = b.Close()
	if c := boot(t, o); c.SetupToken() != "" {
		t.Fatalf("token printed after setup: %q", c.SetupToken())
	}
}

func TestBootReenqueuesMediaJobs(t *testing.T) {
	o := opts(t)
	a := boot(t, o)
	p := login(t, a, "alice")
	v, err := upload(t, a, p, []byte("not really a jpeg"), "x.jpg", "image/jpeg")
	if err != nil {
		t.Fatal(err)
	}
	// Simulate media jobs that died (e.g. ffmpeg was missing).
	if _, err := a.Store().W.Exec(`UPDATE jobs SET state = 'dead'`); err != nil {
		t.Fatal(err)
	}
	_ = a.Close()
	b := boot(t, o)
	if n := count(t, b, `SELECT COUNT(*) FROM jobs WHERE state = 'pending' AND kind = 'generate_thumbnails' AND dedupe_key = ?`, v.AssetID); n != 1 {
		t.Fatalf("pending generate_thumbnails after boot: %d", n)
	}
	if n := count(t, b, `SELECT COUNT(*) FROM jobs WHERE state = 'pending' AND kind = 'generate_thumbnails' AND max_attempts = ?`, service.MediaJobMaxAttempts); n != 1 {
		t.Fatal("re-enqueued media job lacks max_attempts 3")
	}
	_ = b.Close()
	c := boot(t, o) // deduped: still one pending job
	if n := count(t, c, `SELECT COUNT(*) FROM jobs WHERE state = 'pending' AND kind = 'generate_thumbnails'`); n != 1 {
		t.Fatalf("pending generate_thumbnails after third boot: %d", n)
	}
}

func TestFilterIPs(t *testing.T) {
	in := []net.IP{
		net.ParseIP("192.168.1.20"), net.ParseIP("fe80::1"), net.ParseIP("127.0.0.1"),
		net.ParseIP("::1"), net.ParseIP("2001:db8::5"), net.ParseIP("169.254.3.4"), net.ParseIP("10.0.0.2"),
	}
	var got []string
	for _, ip := range app.FilterIPs(in) {
		got = append(got, ip.String())
	}
	if want := "192.168.1.20,2001:db8::5,10.0.0.2"; strings.Join(got, ",") != want {
		t.Fatalf("FilterIPs = %v, want %s", got, want)
	}
}

func TestPairingEndpoints(t *testing.T) {
	ips := []net.IP{net.ParseIP("192.168.1.20"), net.ParseIP("2001:db8::5")}
	got := app.PairingEndpoints(ips, 8443, []string{"https://photos.example.com", "https://192.168.1.20:8443", ""}, true)
	want := []string{"https://192.168.1.20:8443", "https://[2001:db8::5]:8443", "https://photos.example.com"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("endpoints = %v, want %v", got, want)
	}
	if got := app.PairingEndpoints(nil, 9443, nil, true); len(got) != 1 || got[0] != "https://localhost:9443" {
		t.Fatalf("fallback = %v", got)
	}
	// Without TLS the LAN entries cannot be https: only public URLs remain.
	if got := app.PairingEndpoints(ips, 8443, []string{"https://photos.example.com"}, false); len(got) != 1 || got[0] != "https://photos.example.com" {
		t.Fatalf("tls off = %v", got)
	}
}

// syncWriter collects log output across goroutines.
type syncWriter struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (w *syncWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.b.Write(p)
}

func TestRunServesListeners(t *testing.T) {
	o := opts(t)
	type addrs struct{ https, local string }
	got := make(chan addrs, 1)
	o.Listening = func(h, l string) { got <- addrs{h, l} }
	a := boot(t, o)
	ctx, cancel := context.WithCancel(context.Background())
	runErr := make(chan error, 1)
	go func() { runErr <- a.Run(ctx) }()
	var ad addrs
	select {
	case ad = <-got:
	case err := <-runErr:
		t.Fatalf("Run returned early: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("listeners not ready")
	}

	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(a.CACertPEM()) {
		t.Fatal("bad CA PEM")
	}
	tc := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}}
	resp, err := tc.Get("https://" + ad.https + "/api/v1/server/info")
	if err != nil {
		t.Fatal(err)
	}
	var info struct {
		ServerID     string   `json:"server_id"`
		Name         string   `json:"name"`
		Capabilities []string `json:"capabilities"`
		Upload       struct {
			MaxFileBytes int64 `json:"max_file_bytes"`
		} `json:"upload"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&info)
	resp.Body.Close()
	if resp.StatusCode != 200 || info.ServerID != a.ServerID() || info.Name != "Test server" ||
		strings.Join(info.Capabilities, ",") != "tus" || info.Upload.MaxFileBytes != o.Config.Upload.MaxFileBytes {
		t.Fatalf("https info %d %+v", resp.StatusCode, info)
	}
	if resp.TLS == nil || len(resp.TLS.PeerCertificates) == 0 {
		t.Fatal("no TLS")
	}

	// Setup without a token: allowed on the loopback listener only.
	setup := func(base string, c *http.Client) int {
		r, err := c.Post(base+"/api/v1/auth/setup", "application/json",
			strings.NewReader(`{"username":"admin","password":"`+pw+`"}`))
		if err != nil {
			t.Fatal(err)
		}
		r.Body.Close()
		return r.StatusCode
	}
	if st := setup("https://"+ad.https, tc); st != http.StatusForbidden {
		t.Fatalf("setup over https without token = %d, want 403", st)
	}
	if st := setup("http://"+ad.local, http.DefaultClient); st != http.StatusCreated && st != http.StatusOK {
		t.Fatalf("setup over loopback = %d", st)
	}

	cancel()
	select {
	case err := <-runErr:
		if err != nil {
			t.Fatalf("Run = %v", err)
		}
	case <-time.After(40 * time.Second):
		t.Fatal("Run did not stop")
	}
}

func readFile(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
