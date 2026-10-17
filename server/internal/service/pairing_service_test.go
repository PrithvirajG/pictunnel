package service

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/conformance"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
)

var ipad = DeviceInfo{Name: "Alice's iPad", Platform: "ios", AppVersion: "0.1.0"}

func (e *env) alicePrincipal(t *testing.T) Principal {
	t.Helper()
	_, _, tp := e.setupAlice(t)
	return e.principal(t, tp.AccessToken)
}

func TestPairingCreateAndRedeem(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	p := e.alicePrincipal(t)
	code, qr, exp, err := e.pairing.Create(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{2}$`).MatchString(code) {
		t.Fatalf("code %q", code)
	}
	if !exp.Equal(t0.Add(10 * time.Minute)) {
		t.Fatalf("expires %v", exp)
	}
	if !strings.HasPrefix(qr, "pictunnel://pair?v=1&sid=01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f&code="+code+"&fp=") {
		t.Fatalf("qr %q", qr)
	}
	u, d, tp, err := e.pairing.Redeem(ctx, code, ipad)
	if err != nil {
		t.Fatal(err)
	}
	if u.ID != p.UserID || d.UserID != p.UserID || d.Name != "Alice's iPad" || d.Platform != "ios" {
		t.Fatalf("user %+v device %+v", u, d)
	}
	if got := e.principal(t, tp.AccessToken); got.DeviceID != d.ID {
		t.Fatalf("principal %+v", got)
	}
	if _, err := e.auth.Refresh(ctx, tp.RefreshToken); err != nil {
		t.Fatalf("refresh of paired tokens: %v", err)
	}
}

func TestPairingRedeemNormalizesInput(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	p := e.alicePrincipal(t)
	code, _, _, err := e.pairing.Create(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	typed := " " + strings.ToLower(strings.ReplaceAll(code, "-", "")) + " "
	typed = strings.NewReplacer("1", "l", "0", "o").Replace(typed) // Crockford aliases
	if _, _, _, err := e.pairing.Redeem(ctx, typed, ipad); err != nil {
		t.Fatalf("redeem %q (from %q): %v", typed, code, err)
	}
}

func TestPairingSingleUse(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	p := e.alicePrincipal(t)
	code, _, _, err := e.pairing.Create(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := e.pairing.Redeem(ctx, code, ipad); err != nil {
		t.Fatal(err)
	}
	_, _, _, err = e.pairing.Redeem(ctx, code, ipad)
	wantCode(t, err, "pairing_code_invalid")
}

func TestPairingExpired(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	p := e.alicePrincipal(t)
	code, _, _, err := e.pairing.Create(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	e.clk.Advance(10*time.Minute + time.Second)
	_, _, _, err = e.pairing.Redeem(ctx, code, ipad)
	wantCode(t, err, "pairing_code_invalid")
}

func TestPairingRedeemInvalidDevice(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	p := e.alicePrincipal(t)
	code, _, _, err := e.pairing.Create(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	_, _, _, err = e.pairing.Redeem(ctx, code, DeviceInfo{Name: "x", Platform: "palm"})
	wantCode(t, err, "invalid_request")
	if _, _, _, err := e.pairing.Redeem(ctx, code, ipad); err != nil {
		t.Fatalf("code consumed by an invalid request: %v", err)
	}
}

func TestPairingFiveFailuresInvalidate(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	p := e.alicePrincipal(t)
	code, _, _, err := e.pairing.Create(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	for i := range 4 {
		_, _, _, err := e.pairing.Redeem(ctx, "0000-0000-0"+string(rune('0'+i)), ipad)
		wantCode(t, err, "pairing_code_invalid")
	}
	// Four failures leave codes usable; a fresh code proves it without
	// resetting the counter.
	code2, _, _, err := e.pairing.Create(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	_, _, _, err = e.pairing.Redeem(ctx, "not a code", ipad) // fifth failure
	wantCode(t, err, "pairing_code_invalid")
	for _, c := range []string{code, code2} {
		_, _, _, err = e.pairing.Redeem(ctx, c, ipad)
		wantCode(t, err, "pairing_code_invalid")
	}
	// The counter reset: codes created afterwards work. (The two failures
	// just above count toward the next round of five.)
	code3, _, _, err := e.pairing.Create(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := e.pairing.Redeem(ctx, code3, ipad); err != nil {
		t.Fatalf("code created after invalidation: %v", err)
	}
}

func TestQRURIParsesPerVectors(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	p := e.alicePrincipal(t)
	code, qr, _, err := e.pairing.Create(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	got, err := conformance.ParsePairURI(qr)
	if err != nil {
		t.Fatalf("ParsePairURI(%q): %v", qr, err)
	}
	if got.Fingerprint != "xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc" {
		t.Fatalf("fp = %q", got.Fingerprint)
	}
	if got.ServerID != "01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f" || got.Code != code {
		t.Fatalf("parsed %+v", got)
	}
	if want := []string{"https://192.168.1.20:8443", "https://photos.example.com"}; !slices.Equal(got.Endpoints, want) {
		t.Fatalf("endpoints %v, want %v", got.Endpoints, want)
	}
	if !strings.Contains(qr, "&u=https%3A%2F%2F192.168.1.20%3A8443&u=https%3A%2F%2Fphotos.example.com") {
		t.Fatalf("u not URL-encoded and repeated in order: %q", qr)
	}
	if strings.Count(qr, "&u=") != 2 {
		t.Fatalf("duplicate endpoint not removed: %q", qr)
	}
}

func TestNewPairingServiceRequires32ByteSecret(t *testing.T) {
	for _, n := range []int{0, 31, 33} {
		if _, err := NewPairingService(PairingServiceDeps{Secret: make([]byte, n)}); err == nil {
			t.Errorf("secret of %d bytes accepted", n)
		}
	}
}

func countPairingCodes(t *testing.T, e *env) int {
	t.Helper()
	var n int
	if err := e.st.R.QueryRow(`SELECT COUNT(*) FROM pairing_codes`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestPairingCreateWithoutEndpoints(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	p := e.alicePrincipal(t)
	for _, eps := range []func() []string{nil, func() []string { return nil }, func() []string { return []string{""} }} {
		e.pairing.d.Endpoints = eps
		_, _, _, err := e.pairing.Create(ctx, p)
		wantCode(t, err, "internal")
	}
	if n := countPairingCodes(t, e); n != 0 {
		t.Fatalf("%d pairing codes stored without endpoints", n)
	}
}

func TestPairingCodeStoredAsHMAC(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	p := e.alicePrincipal(t)
	code, _, _, err := e.pairing.Create(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	m := hmac.New(sha256.New, testSecret)
	m.Write([]byte(code))
	want := hex.EncodeToString(m.Sum(nil))
	if _, err := (repository.PairingCodesRepository{}).Get(ctx, e.st.R, want); err != nil {
		t.Fatalf("no row under HMAC hash: %v", err)
	}
	if _, err := (repository.PairingCodesRepository{}).Get(ctx, e.st.R, hashToken(code)); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("row found under plain SHA-256: %v", err)
	}
}

func TestPairingAudit(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	p := e.alicePrincipal(t)
	code, _, _, err := e.pairing.Create(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	_, d, _, err := e.pairing.Redeem(ctx, code, ipad)
	if err != nil {
		t.Fatal(err)
	}
	outstanding, _, _, err := e.pairing.Create(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	_, _, _, _ = e.pairing.Redeem(ctx, "garbage!", ipad) // malformed
	_, _, _, _ = e.pairing.Redeem(ctx, code, ipad)       // invalid (used)
	for range 3 {                                        // 3 more → 5th invalidates
		_, _, _, _ = e.pairing.Redeem(ctx, "0000-0000-00", ipad)
	}
	evs, err := repository.AuditLogRepository{}.List(ctx, e.st.R, 100)
	if err != nil {
		t.Fatal(err)
	}
	var redeemed int
	var failed []map[string]any
	for _, ev := range evs {
		for _, c := range []string{code, outstanding, strings.ReplaceAll(code, "-", ""), strings.ReplaceAll(outstanding, "-", "")} {
			if strings.Contains(ev.DetailJSON, c) {
				t.Fatalf("audit event %s leaks a code: %s", ev.Event, ev.DetailJSON)
			}
		}
		switch ev.Event {
		case "pairing.redeemed":
			redeemed++
			if ev.UserID == nil || *ev.UserID != p.UserID || ev.DeviceID == nil || *ev.DeviceID != d.ID {
				t.Fatalf("pairing.redeemed = %+v", ev)
			}
		case "pairing.failed":
			var m map[string]any
			if err := json.Unmarshal([]byte(ev.DetailJSON), &m); err != nil {
				t.Fatal(err)
			}
			failed = append(failed, m)
		}
	}
	if redeemed != 1 || len(failed) != 5 {
		t.Fatalf("redeemed=%d failed=%d", redeemed, len(failed))
	}
	reasons := map[any]int{}
	var invalidated float64
	for _, m := range failed {
		reasons[m["reason"]]++
		invalidated += m["invalidated"].(float64)
	}
	if reasons["malformed"] != 1 || reasons["invalid"] != 4 || invalidated != 1 {
		t.Fatalf("failure details %v", failed)
	}
}
