package service

import (
	"context"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/conformance"
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
