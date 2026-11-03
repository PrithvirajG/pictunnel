package main

import (
	"bytes"
	"context"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"rsc.io/qr"
)

// startServe runs `pictunnel serve` in a temp data dir and returns the
// loopback listener's base URL. The server stops when the test ends.
func startServe(t *testing.T) string {
	t.Helper()
	// Made before the stop cleanup is registered: cleanups run last first, so the
	// server stops (and releases the database, which Windows requires) before
	// the directory is removed.
	dir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	var out, errOut syncBuf
	done := make(chan int, 1)
	go func() { done <- run(ctx, append([]string{"serve"}, serveFlags(dir)...), nil, &out, &errOut) }()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(40 * time.Second):
			t.Error("serve did not stop")
		}
	})
	re := regexp.MustCompile(`local http://(127\.0\.0\.1:\d+)`)
	deadline := time.Now().Add(20 * time.Second)
	for {
		if m := re.FindStringSubmatch(out.String()); m != nil {
			return "http://" + m[1]
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
}

func runPair(env []string, args ...string) (int, string, string) {
	var out, errOut bytes.Buffer
	code := run(context.Background(), append([]string{"pair"}, args...), env, &out, &errOut)
	return code, out.String(), errOut.String()
}

func TestPairCLI(t *testing.T) {
	base := startServe(t)

	// No password and no --create: nothing to log in with.
	if code, _, stderr := runPair(nil, "--url", base); code != 2 || !strings.Contains(stderr, "--password") {
		t.Fatalf("no password: %d %q", code, stderr)
	}

	// First run: creates the admin with a generated password; stdout is only the link.
	code, stdout, stderr := runPair(nil, "--url", base, "--create", "--uri-only")
	if code != 0 {
		t.Fatalf("create: %d %q", code, stderr)
	}
	m := regexp.MustCompile(`Created the admin account "admin" with the password (\S+)`).FindStringSubmatch(stderr)
	if m == nil {
		t.Fatalf("no generated password in stderr: %q", stderr)
	}
	password := m[1]
	link := strings.TrimSpace(stdout)
	if strings.Count(stdout, "\n") != 1 || !strings.HasPrefix(link, "pictunnel://pair?v=1&sid=") {
		t.Fatalf("--uri-only stdout = %q", stdout)
	}
	u, err := url.Parse(link)
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	if len(q.Get("fp")) != 43 || len(q["u"]) == 0 || q.Get("code") == "" {
		t.Fatalf("pairing link %q lacks fp, u or code", link)
	}

	// The code really redeems.
	body := `{"code":"` + q.Get("code") + `","device":{"device_name":"cli test","platform":"android","app_version":"0.1.0"}}`
	req, _ := http.NewRequest(http.MethodPost, base+"/api/v1/pairing/redeem", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("PicTunnel-Client", "android/0.1.0")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("redeem: %d", resp.StatusCode)
	}

	// --create on a server with an account and no password fails without changing it.
	if code, _, stderr := runPair(nil, "--url", base, "--create"); code != 1 || !strings.Contains(stderr, "already has an account") {
		t.Fatalf("second create without password: %d %q", code, stderr)
	}
	// --create with the password just carries on to the code.
	if code, stdout, stderr := runPair(nil, "--url", base, "--create", "--password", password, "--uri-only"); code != 0 ||
		!strings.HasPrefix(stdout, "pictunnel://pair?") || strings.Contains(stderr, "Created") {
		t.Fatalf("create with password on a set-up server: %d %q %q", code, stdout, stderr)
	}

	// Text mode, password from the environment: code, QR, pin and link, plus a PNG.
	png := filepath.Join(t.TempDir(), "qr.png")
	code, stdout, stderr = runPair([]string{"PICTUNNEL_PASSWORD=" + password, "PICTUNNEL_LOCAL_URL=" + base}, "--png", png)
	if code != 0 {
		t.Fatalf("text mode: %d %q", code, stderr)
	}
	for _, want := range []string{"Pairing code:  ", "Security code: " + q.Get("fp")[:16], "Server URLs:   https://", "Pairing link:  pictunnel://pair?", "█"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("text output lacks %q:\n%s", want, stdout)
		}
	}

	if b, err := os.ReadFile(png); err != nil || !bytes.HasPrefix(b, []byte{0x89, 'P', 'N', 'G'}) {
		t.Errorf("--png did not write a PNG: %v", err)
	}

	// A wrong password is the server's 401.
	if code, _, stderr := runPair(nil, "--url", base, "--password", "not the password"); code != 1 || !strings.Contains(stderr, "401") {
		t.Fatalf("wrong password: %d %q", code, stderr)
	}
}

func TestPairCLIUsage(t *testing.T) {
	for _, args := range [][]string{{"--url", "ftp://x"}, {"--bogus"}, {"extra"}} {
		if code, _, _ := runPair(nil, args...); code != 2 {
			t.Errorf("%v: exit %d, want 2", args, code)
		}
	}
	// Nothing listening: a clear error, exit 1.
	if code, _, stderr := runPair(nil, "--url", "http://127.0.0.1:1", "--password", "x"); code != 1 || !strings.Contains(stderr, "is the server running?") {
		t.Errorf("no server: %d %q", code, stderr)
	}
}

func TestRenderQRQuietZoneAndSize(t *testing.T) {
	c, err := qr.Encode("pictunnel://pair?v=1", qr.L)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(renderQR(c), "\n"), "\n")
	width := c.Size + 8
	if len(lines) != (width+1)/2 {
		t.Fatalf("%d lines for size %d", len(lines), c.Size)
	}
	for i, l := range lines {
		if n := len([]rune(l)); n != width {
			t.Fatalf("line %d has %d columns, want %d", i, n, width)
		}
	}
	// The first two rows are quiet zone: all light.
	if strings.Trim(lines[0], "█") != "" {
		t.Errorf("first line is not quiet zone: %q", lines[0])
	}
}
