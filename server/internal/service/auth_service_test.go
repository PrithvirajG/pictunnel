package service

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"strings"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
)

func TestDeriveSuccessorsPerADR0012(t *testing.T) {
	rt := "pt_rt_abc"
	at2, rt2 := deriveSuccessors(testSecret, rt)
	mac := func(msg string) string {
		m := hmac.New(sha256.New, testSecret)
		m.Write([]byte(msg))
		return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
	}
	if rt2 != "pt_rt_"+mac("rt|"+rt) {
		t.Fatalf("rt' = %q", rt2)
	}
	if at2 != "pt_at_"+mac("at|"+rt) {
		t.Fatalf("at' = %q", at2)
	}
}

func TestNewTokenFormat(t *testing.T) {
	tok := newToken(prefixAccess)
	if !strings.HasPrefix(tok, "pt_at_") || len(tok) != len("pt_at_")+43 {
		t.Fatalf("token %q", tok)
	}
	if hashToken(tok) == hashToken(newToken(prefixAccess)) {
		t.Fatal("tokens collide")
	}
	if h := hashToken("x"); h != "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881" {
		t.Fatalf("hashToken(x) = %s", h)
	}
}

func TestLogin(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	u, d, tp := e.setupAlice(t)
	if d.UserID != u.ID || d.Name != "Pixel 9" || d.Platform != "android" || d.AppVersion != "0.1.0" {
		t.Fatalf("device = %+v", d)
	}
	if !strings.HasPrefix(tp.AccessToken, "pt_at_") || !strings.HasPrefix(tp.RefreshToken, "pt_rt_") {
		t.Fatalf("tokens = %+v", tp)
	}
	if !tp.AccessExpiresAt.Equal(t0.Add(15*time.Minute)) || !tp.RefreshExpiresAt.Equal(t0.Add(90*24*time.Hour)) {
		t.Fatalf("expiries = %v %v", tp.AccessExpiresAt, tp.RefreshExpiresAt)
	}
	p := e.principal(t, tp.AccessToken)
	want := Principal{UserID: u.ID, Username: "alice", Slug: "alice", Role: "admin", DeviceID: d.ID, Platform: "android", Via: "bearer"}
	if p != want {
		t.Fatalf("principal = %+v, want %+v", p, want)
	}

	_, _, _, err := e.auth.Login(ctx, "alice", "wrong password!", pixel)
	wantCode(t, err, "unauthorized")
	_, _, _, err = e.auth.Login(ctx, "nobody", testPassword, pixel)
	wantCode(t, err, "unauthorized")
	_, _, _, err = e.auth.Login(ctx, "alice", testPassword, DeviceInfo{Name: "x", Platform: "nokia"})
	wantCode(t, err, "invalid_request")
	_, _, _, err = e.auth.Login(ctx, "alice", testPassword, DeviceInfo{Name: " ", Platform: "ios"})
	wantCode(t, err, "invalid_request")
}

func TestRefreshRotation(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	_, d, tp := e.setupAlice(t)
	e.clk.Advance(5 * time.Minute)
	tp2, err := e.auth.Refresh(ctx, tp.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	if tp2.AccessToken == tp.AccessToken || tp2.RefreshToken == tp.RefreshToken {
		t.Fatal("refresh did not rotate")
	}
	now := t0.Add(5 * time.Minute)
	if !tp2.AccessExpiresAt.Equal(now.Add(15*time.Minute)) || !tp2.RefreshExpiresAt.Equal(now.Add(90*24*time.Hour)) {
		t.Fatalf("successor expiries = %v %v", tp2.AccessExpiresAt, tp2.RefreshExpiresAt)
	}
	if p := e.principal(t, tp2.AccessToken); p.DeviceID != d.ID {
		t.Fatalf("new access token principal %+v", p)
	}
	// The old access token keeps working until its own expiry.
	e.clk.Advance(9*time.Minute + 59*time.Second)
	if p := e.principal(t, tp.AccessToken); p.DeviceID != d.ID {
		t.Fatalf("old access token principal %+v", p)
	}
	e.clk.Advance(2 * time.Second)
	_, err = e.auth.AuthenticateBearer(ctx, tp.AccessToken)
	wantCode(t, err, "token_expired")
	// The successor refresh token rotates in turn.
	if _, err := e.auth.Refresh(ctx, tp2.RefreshToken); err != nil {
		t.Fatalf("second-generation refresh: %v", err)
	}
	rt, err := repository.RefreshTokensRepository{}.Get(ctx, e.st.R, hashToken(tp.RefreshToken))
	if err != nil || rt.State != "rotated" {
		t.Fatalf("old refresh row = %+v, %v", rt, err)
	}
	rt2, err := repository.RefreshTokensRepository{}.Get(ctx, e.st.R, hashToken(tp2.RefreshToken))
	if err != nil || rt2.FamilyID != rt.FamilyID {
		t.Fatalf("successor family %q, want %q (%v)", rt2.FamilyID, rt.FamilyID, err)
	}
}

func TestRefreshGraceIdempotent(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	_, _, tp := e.setupAlice(t)
	a, err := e.auth.Refresh(ctx, tp.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	e.clk.Advance(10 * time.Second)
	b, err := e.auth.Refresh(ctx, tp.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	if a != b {
		t.Fatalf("grace replay pair differs:\n%+v\n%+v", a, b)
	}
	e.clk.Advance(20 * time.Second) // exactly 30 s: still inside the window
	c, err := e.auth.Refresh(ctx, tp.RefreshToken)
	if err != nil || c != a {
		t.Fatalf("replay at 30 s = %+v, %v", c, err)
	}
	e.principal(t, a.AccessToken)
}

func TestRefreshReuseRevokesFamily(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	u, d, tp := e.setupAlice(t)
	a, err := e.auth.Refresh(ctx, tp.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	e.clk.Advance(31 * time.Second)
	_, err = e.auth.Refresh(ctx, tp.RefreshToken)
	wantCode(t, err, "refresh_token_reused")

	_, err = e.auth.AuthenticateBearer(ctx, a.AccessToken)
	wantCode(t, err, "unauthorized")
	_, err = e.auth.AuthenticateBearer(ctx, tp.AccessToken)
	wantCode(t, err, "unauthorized")
	_, err = e.auth.Refresh(ctx, a.RefreshToken)
	wantCode(t, err, "unauthorized")
	dev, err := repository.DevicesRepository{}.Get(ctx, e.st.R, d.ID)
	if err != nil || dev.RevokedAt == nil {
		t.Fatalf("device not revoked: %+v, %v", dev, err)
	}
	evs, err := repository.AuditLogRepository{}.List(ctx, e.st.R, 50)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, ev := range evs {
		if ev.Event == "auth.refresh_reused" && ev.DeviceID != nil && *ev.DeviceID == d.ID && ev.UserID != nil && *ev.UserID == u.ID {
			found = true
		}
	}
	if !found {
		t.Fatalf("no auth.refresh_reused audit event in %+v", evs)
	}
	// Replaying again stays rejected.
	_, err = e.auth.Refresh(ctx, tp.RefreshToken)
	if err == nil {
		t.Fatal("replay after revocation succeeded")
	}
}

func TestRefreshGraceSurvivesRestart(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	_, _, tp := e.setupAlice(t)
	e.clk.Advance(1234 * time.Microsecond) // sub-ms precision must not leak into expiries
	a, err := e.auth.Refresh(ctx, tp.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	e.clk.Advance(15 * time.Second)
	restarted := newEnvOn(t, e.st, e.clk)
	b, err := restarted.auth.Refresh(ctx, tp.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	if a != b {
		t.Fatalf("pair after restart differs:\n%+v\n%+v", a, b)
	}
}

func TestRefreshGarbledUnauthorized(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	_, _, tp := e.setupAlice(t)
	for _, bad := range []string{"", "pt_rt_", "pt_rt_nope", tp.AccessToken, tp.RefreshToken + "x", "garbage"} {
		_, err := e.auth.Refresh(ctx, bad)
		wantCode(t, err, "unauthorized")
	}
	// A different server secret derives different successors: the replay
	// inside the grace window cannot find them and is unauthorized, not reuse.
	if _, err := e.auth.Refresh(ctx, tp.RefreshToken); err != nil {
		t.Fatal(err)
	}
	other := newEnvOn(t, e.st, e.clk)
	other.auth.secret = []byte("another secret, 32 bytes long!!!")
	_, err := other.auth.Refresh(ctx, tp.RefreshToken)
	wantCode(t, err, "unauthorized")
}

func TestRefreshExpired(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	_, _, tp := e.setupAlice(t)
	e.clk.Advance(90*24*time.Hour + time.Second)
	_, err := e.auth.Refresh(ctx, tp.RefreshToken)
	wantCode(t, err, "unauthorized")
}

func TestAccessExpiry(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	_, _, tp := e.setupAlice(t)
	e.clk.Advance(15 * time.Minute)
	e.principal(t, tp.AccessToken) // valid through its expiry instant
	e.clk.Advance(time.Second)
	_, err := e.auth.AuthenticateBearer(ctx, tp.AccessToken)
	wantCode(t, err, "token_expired")
}

func TestBearerGarbledUnauthorized(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	_, _, tp := e.setupAlice(t)
	for _, bad := range []string{"", "pt_at_", "pt_at_nope", tp.RefreshToken, "Bearer " + tp.AccessToken} {
		_, err := e.auth.AuthenticateBearer(ctx, bad)
		wantCode(t, err, "unauthorized")
	}
}

func TestRevokedDeviceUnauthorized(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	_, d, tp := e.setupAlice(t)
	// Revoke the row only, leaving the token rows, to prove the device check.
	if err := (repository.DevicesRepository{}).Revoke(ctx, e.st.W, d.ID, t0); err != nil {
		t.Fatal(err)
	}
	_, err := e.auth.AuthenticateBearer(ctx, tp.AccessToken)
	wantCode(t, err, "unauthorized")
	_, err = e.auth.Refresh(ctx, tp.RefreshToken)
	wantCode(t, err, "unauthorized")
	// Revoked beats expired.
	e.clk.Advance(time.Hour)
	_, err = e.auth.AuthenticateBearer(ctx, tp.AccessToken)
	wantCode(t, err, "unauthorized")
}

func TestDisabledUserUnauthorized(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	u, _, tp := e.setupAlice(t)
	if _, err := e.st.W.ExecContext(ctx, `UPDATE users SET disabled_at = '2026-10-03T12:00:00.000Z' WHERE id = ?`, u.ID); err != nil {
		t.Fatal(err)
	}
	_, err := e.auth.AuthenticateBearer(ctx, tp.AccessToken)
	wantCode(t, err, "unauthorized")
	_, err = e.auth.Refresh(ctx, tp.RefreshToken)
	wantCode(t, err, "unauthorized")
	_, _, _, err = e.auth.Login(ctx, "alice", testPassword, pixel)
	wantCode(t, err, "unauthorized")
}

func TestBearerDoesNotWrite(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	_, d, tp := e.setupAlice(t)
	e.clk.Advance(5 * time.Minute)
	e.principal(t, tp.AccessToken)
	dev, err := repository.DevicesRepository{}.Get(ctx, e.st.R, d.ID)
	if err != nil || !dev.LastSeenAt.Equal(t0) {
		t.Fatalf("last_seen_at = %v, %v; AuthenticateBearer must not write", dev.LastSeenAt, err)
	}
}

func TestCookieLoginCSRF(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	if _, err := e.users.Setup(ctx, "alice", testPassword, "Alice"); err != nil {
		t.Fatal(err)
	}
	u, d, sess, csrf, exp, err := e.auth.LoginCookie(ctx, "alice", testPassword)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(sess, "pt_ws_") || csrf == "" || csrf == sess {
		t.Fatalf("session %q csrf %q", sess, csrf)
	}
	if d.Platform != "web" || d.UserID != u.ID {
		t.Fatalf("device = %+v", d)
	}
	if !exp.Equal(t0.Add(30 * 24 * time.Hour)) {
		t.Fatalf("expires = %v", exp)
	}
	p, err := e.auth.AuthenticateCookie(ctx, sess)
	if err != nil {
		t.Fatal(err)
	}
	if p.Via != "cookie" || p.DeviceID != d.ID || p.UserID != u.ID || p.SessionHash != hashToken(sess) {
		t.Fatalf("principal = %+v", p)
	}
	if !e.auth.CheckCSRF(ctx, p, csrf) {
		t.Fatal("correct CSRF token rejected")
	}
	for _, bad := range []string{"", "x", csrf + "x", sess} {
		if e.auth.CheckCSRF(ctx, p, bad) {
			t.Fatalf("CSRF %q accepted", bad)
		}
	}
	// Bearer principals need no CSRF token.
	_, _, tp, err := e.auth.Login(ctx, "alice", testPassword, pixel)
	if err != nil {
		t.Fatal(err)
	}
	if !e.auth.CheckCSRF(ctx, e.principal(t, tp.AccessToken), "") {
		t.Fatal("bearer principal failed CSRF check")
	}
	// Wrong password and garbage session tokens.
	_, _, _, _, _, err = e.auth.LoginCookie(ctx, "alice", "nope nope nope")
	wantCode(t, err, "unauthorized")
	for _, bad := range []string{"", "pt_ws_x", tp.AccessToken} {
		_, err = e.auth.AuthenticateCookie(ctx, bad)
		wantCode(t, err, "unauthorized")
	}
	// Sliding: use after 20 days extends; 31 idle days later it is gone.
	e.clk.Advance(20 * 24 * time.Hour)
	if _, err := e.auth.AuthenticateCookie(ctx, sess); err != nil {
		t.Fatalf("session at day 20: %v", err)
	}
	e.clk.Advance(25 * 24 * time.Hour)
	if _, err := e.auth.AuthenticateCookie(ctx, sess); err != nil {
		t.Fatalf("session at day 45 after sliding: %v", err)
	}
	e.clk.Advance(31 * 24 * time.Hour)
	_, err = e.auth.AuthenticateCookie(ctx, sess)
	wantCode(t, err, "unauthorized")
}

func TestLogoutCookie(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	if _, err := e.users.Setup(ctx, "alice", testPassword, "Alice"); err != nil {
		t.Fatal(err)
	}
	_, _, sess, csrf, _, err := e.auth.LoginCookie(ctx, "alice", testPassword)
	if err != nil {
		t.Fatal(err)
	}
	p, err := e.auth.AuthenticateCookie(ctx, sess)
	if err != nil {
		t.Fatal(err)
	}
	if err := e.auth.Logout(ctx, p); err != nil {
		t.Fatal(err)
	}
	_, err = e.auth.AuthenticateCookie(ctx, sess)
	wantCode(t, err, "unauthorized")
	if e.auth.CheckCSRF(ctx, p, csrf) {
		t.Fatal("CSRF accepted after logout")
	}
}

func TestLogoutBearer(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	_, d, tp := e.setupAlice(t)
	if err := e.auth.Logout(ctx, e.principal(t, tp.AccessToken)); err != nil {
		t.Fatal(err)
	}
	_, err := e.auth.AuthenticateBearer(ctx, tp.AccessToken)
	wantCode(t, err, "unauthorized")
	_, err = e.auth.Refresh(ctx, tp.RefreshToken)
	wantCode(t, err, "unauthorized")
	dev, err := repository.DevicesRepository{}.Get(ctx, e.st.R, d.ID)
	if err != nil || dev.RevokedAt == nil {
		t.Fatalf("device after logout = %+v, %v", dev, err)
	}
}
