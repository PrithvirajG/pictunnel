package tlsutil_test

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/tlsutil"
)

var (
	t0 = time.Date(2026, 10, 13, 12, 0, 0, 0, time.UTC)
	ip = []net.IP{net.ParseIP("192.168.1.20")}
)

func ensure(t *testing.T, dir string, ips []net.IP, now time.Time) *tlsutil.Material {
	t.Helper()
	m, err := tlsutil.EnsureSelfSigned(dir, "0123456789abcdef", []string{"myhost", "myhost.local"}, ips, now)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func mtimes(t *testing.T, dir string) map[string]time.Time {
	t.Helper()
	out := map[string]time.Time{}
	for _, n := range []string{"ca.crt", "ca.key", "server.crt", "server.key"} {
		fi, err := os.Stat(filepath.Join(dir, n))
		if err != nil {
			t.Fatal(err)
		}
		out[n] = fi.ModTime()
	}
	return out
}

func TestCreateAndVerify(t *testing.T) {
	dir := t.TempDir()
	m := ensure(t, dir, ip, t0)
	mtimes(t, dir) // all four exist
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(m.CAPEM) {
		t.Fatal("bad CAPEM")
	}
	for _, name := range []string{"localhost", "myhost.local", "127.0.0.1", "192.168.1.20", "::1"} {
		if _, err := m.Leaf.Verify(x509.VerifyOptions{Roots: pool, DNSName: name, CurrentTime: t0.Add(time.Hour)}); err != nil {
			t.Errorf("verify %s: %v", name, err)
		}
	}
	if m.Cert.PrivateKey == nil || len(m.Cert.Certificate) == 0 {
		t.Fatal("tls.Certificate not populated")
	}
}

func TestSecondCallDoesNotRewrite(t *testing.T) {
	dir := t.TempDir()
	m1 := ensure(t, dir, ip, t0)
	before := mtimes(t, dir)
	time.Sleep(20 * time.Millisecond)
	m2 := ensure(t, dir, ip, t0.Add(time.Hour))
	after := mtimes(t, dir)
	for k, v := range before {
		if !after[k].Equal(v) {
			t.Errorf("%s rewritten", k)
		}
	}
	if m1.SPKIFingerprint != m2.SPKIFingerprint {
		t.Fatal("fingerprint changed")
	}
}

func TestNewIPRenewsLeafKeepsPin(t *testing.T) {
	dir := t.TempDir()
	m1 := ensure(t, dir, ip, t0)
	m2 := ensure(t, dir, append(ip, net.ParseIP("10.0.0.5")), t0.Add(time.Hour))
	if m1.SPKIFingerprint != m2.SPKIFingerprint {
		t.Fatal("fingerprint changed")
	}
	if m1.Leaf.SerialNumber.Cmp(m2.Leaf.SerialNumber) == 0 {
		t.Fatal("leaf not renewed")
	}
	if !m2.Leaf.IPAddresses[len(m2.Leaf.IPAddresses)-1].Equal(net.ParseIP("10.0.0.5")) && !containsIP(m2.Leaf.IPAddresses, "10.0.0.5") {
		t.Fatal("new IP not in SANs")
	}
}

func containsIP(l []net.IP, s string) bool {
	for _, i := range l {
		if i.Equal(net.ParseIP(s)) {
			return true
		}
	}
	return false
}

func TestNearExpiryRenewsKeepsPin(t *testing.T) {
	dir := t.TempDir()
	m1 := ensure(t, dir, ip, t0)
	now := m1.Leaf.NotAfter.Add(-29 * 24 * time.Hour)
	m2 := ensure(t, dir, ip, now)
	if m1.SPKIFingerprint != m2.SPKIFingerprint {
		t.Fatal("fingerprint changed")
	}
	if !m2.Leaf.NotAfter.After(m1.Leaf.NotAfter) {
		t.Fatal("leaf not renewed")
	}
	// 31 days before expiry: no renewal.
	m3 := ensure(t, dir, ip, m2.Leaf.NotAfter.Add(-31*24*time.Hour))
	if m3.Leaf.SerialNumber.Cmp(m2.Leaf.SerialNumber) != 0 {
		t.Fatal("renewed too early")
	}
}

func TestFingerprintFormat(t *testing.T) {
	m := ensure(t, t.TempDir(), ip, t0)
	sum := sha256.Sum256(m.Leaf.RawSubjectPublicKeyInfo)
	want := base64.RawURLEncoding.EncodeToString(sum[:])
	if m.SPKIFingerprint != want || tlsutil.SPKIFingerprint(m.Leaf) != want {
		t.Fatalf("got %q want %q", m.SPKIFingerprint, want)
	}
}

func TestLoadFiles(t *testing.T) {
	dir := t.TempDir()
	m := ensure(t, dir, ip, t0)
	l, err := tlsutil.LoadFiles(filepath.Join(dir, "server.crt"), filepath.Join(dir, "server.key"))
	if err != nil {
		t.Fatal(err)
	}
	if l.SPKIFingerprint != m.SPKIFingerprint {
		t.Fatal("fingerprint mismatch")
	}
}

func TestKeyFileMode(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX modes not enforced on Windows")
	}
	dir := t.TempDir()
	ensure(t, dir, ip, t0)
	for _, n := range []string{"ca.key", "server.key"} {
		fi, err := os.Stat(filepath.Join(dir, n))
		if err != nil {
			t.Fatal(err)
		}
		if fi.Mode().Perm() != 0o600 {
			t.Errorf("%s mode %v", n, fi.Mode().Perm())
		}
	}
}

func TestLocalIPsNonLoopback(t *testing.T) {
	ips, err := tlsutil.LocalIPs()
	if err != nil {
		t.Fatal(err)
	}
	for _, i := range ips {
		if i.IsLoopback() {
			t.Errorf("loopback %v", i)
		}
	}
}
