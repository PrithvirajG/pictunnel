package httpapi_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/config"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/httpapitest"
)

var setupBody = map[string]any{"username": "alice", "password": adminPass, "display_name": "Alice"}

func tokensLogin(user, pass string) map[string]any {
	return map[string]any{"username": user, "password": pass, "mode": "tokens",
		"device": map[string]any{"device_name": "Pixel 9", "platform": "android", "app_version": "0.1.0"}}
}

func TestSetupLocal(t *testing.T) {
	a := httpapitest.New(t, httpapitest.Local())
	resp, body := call(t, a, "", "POST", "/api/v1/auth/setup", setupBody)
	wantStatus(t, resp, body, 201)
	var out gen.SetupResponse
	httpapitest.Decode(t, body, &out)
	if out.User.Username != "alice" || out.User.DisplayName != "Alice" || out.User.Role != "admin" {
		t.Fatalf("setup: %+v", out)
	}
}

func TestSetupAlreadyDone(t *testing.T) {
	a := httpapitest.New(t, httpapitest.Local())
	resp, body := call(t, a, "", "POST", "/api/v1/auth/setup", setupBody)
	wantStatus(t, resp, body, 201)
	resp, body = call(t, a, "", "POST", "/api/v1/auth/setup", setupBody)
	wantProblem(t, resp, body, 409, "setup_already_done")
}

func TestSetupTokenRequiredOffLoopback(t *testing.T) {
	a := httpapitest.New(t)
	tok, created, err := a.Users.EnsureSetupToken(context.Background())
	if err != nil || !created {
		t.Fatalf("EnsureSetupToken: %v %v", created, err)
	}
	resp, body := call(t, a, "", "POST", "/api/v1/auth/setup", setupBody)
	wantProblem(t, resp, body, 403, "forbidden")

	req := a.Req(t, "POST", "/api/v1/auth/setup", setupBody)
	req.Header.Set("PicTunnel-Setup-Token", "wrong")
	resp, body = a.Do(t, req)
	wantProblem(t, resp, body, 403, "forbidden")

	req = a.Req(t, "POST", "/api/v1/auth/setup", setupBody)
	req.Header.Set("PicTunnel-Setup-Token", tok)
	resp, body = a.Do(t, req)
	wantStatus(t, resp, body, 201)
}

func TestSetupInvalidJSON(t *testing.T) {
	a := httpapitest.New(t, httpapitest.Local())
	resp, body := call(t, a, "", "POST", "/api/v1/auth/setup", `{"username":`)
	wantProblem(t, resp, body, 400, "invalid_request")
	resp, body = call(t, a, "", "POST", "/api/v1/auth/setup", map[string]any{"username": "alice", "password": "short"})
	wantProblem(t, resp, body, 400, "invalid_request")
}

func TestLoginTokens(t *testing.T) {
	a := httpapitest.New(t)
	a.SetupAdmin(t, adminUser, adminPass)
	req := a.Req(t, "POST", "/api/v1/auth/login", tokensLogin(adminUser, adminPass))
	req.Header.Set("PicTunnel-Client", "android/0.1.0")
	resp, body := a.Do(t, req)
	wantStatus(t, resp, body, 200)
	var out gen.LoginResponse
	httpapitest.Decode(t, body, &out)
	if out.Tokens == nil || !strings.HasPrefix(out.Tokens.AccessToken, "pt_at_") || !strings.HasPrefix(out.Tokens.RefreshToken, "pt_rt_") {
		t.Fatalf("tokens: %+v", out.Tokens)
	}
	if !out.Tokens.AccessTokenExpiresAt.Equal(httpapitest.T0.Add(15 * time.Minute)) {
		t.Errorf("access expiry %v", out.Tokens.AccessTokenExpiresAt)
	}
	if out.Device == nil || out.Device.Name != "Pixel 9" || out.Device.Platform != "android" || out.Device.LastSeenAt != nil {
		t.Fatalf("device: %+v", out.Device)
	}
	if out.CsrfToken != nil || resp.Header.Get("Set-Cookie") != "" {
		t.Error("tokens mode returned cookie material")
	}
	if cc := resp.Header.Get("Cache-Control"); cc != "no-store" {
		t.Errorf("token response Cache-Control %q", cc)
	}

	// The access token works.
	resp, body = call(t, a, out.Tokens.AccessToken, "GET", "/api/v1/devices", nil)
	wantStatus(t, resp, body, 200)
}

func TestLoginTokensNeedsDevice(t *testing.T) {
	a := httpapitest.New(t)
	resp, body := call(t, a, "", "POST", "/api/v1/auth/login",
		map[string]any{"username": "alice", "password": adminPass, "mode": "tokens"})
	wantProblem(t, resp, body, 400, "invalid_request")
	resp, body = call(t, a, "", "POST", "/api/v1/auth/login",
		map[string]any{"username": "alice", "password": adminPass, "mode": "magic"})
	wantProblem(t, resp, body, 400, "invalid_request")
}

func TestLoginUnauthorized(t *testing.T) {
	a := httpapitest.New(t)
	a.SetupAdmin(t, adminUser, adminPass)
	resp, body := call(t, a, "", "POST", "/api/v1/auth/login", tokensLogin(adminUser, "wrong password!"))
	wantProblem(t, resp, body, 401, "unauthorized")
}

func cookieLogin(t *testing.T, a *httpapitest.App) (*http.Cookie, string) {
	t.Helper()
	resp, body := call(t, a, "", "POST", "/api/v1/auth/login",
		map[string]any{"username": adminUser, "password": adminPass, "mode": "cookie"})
	wantStatus(t, resp, body, 200)
	var out gen.LoginResponse
	httpapitest.Decode(t, body, &out)
	if out.CsrfToken == nil || *out.CsrfToken == "" || out.Tokens != nil {
		t.Fatalf("cookie login: %s", body)
	}
	for _, c := range resp.Cookies() {
		if c.Name == "pt_session" {
			return c, *out.CsrfToken
		}
	}
	t.Fatalf("no pt_session cookie: %v", resp.Header["Set-Cookie"])
	return nil, ""
}

func TestLoginCookie(t *testing.T) {
	a := httpapitest.New(t)
	a.SetupAdmin(t, adminUser, adminPass)
	c, _ := cookieLogin(t, a)
	if !strings.HasPrefix(c.Value, "pt_ws_") || !c.HttpOnly || !c.Secure || c.SameSite != http.SameSiteLaxMode || c.Path != "/" {
		t.Fatalf("cookie attributes: %+v", c)
	}

	l := httpapitest.New(t, httpapitest.Local())
	l.SetupAdmin(t, adminUser, adminPass)
	c, _ = cookieLogin(t, l)
	if c.Secure || !c.HttpOnly {
		t.Fatalf("loopback cookie attributes: %+v", c)
	}
}

func TestCookieCSRFRequired(t *testing.T) {
	a := httpapitest.New(t)
	a.SetupAdmin(t, adminUser, adminPass)
	c, csrf := cookieLogin(t, a)

	// Safe methods need no CSRF token.
	req := a.Req(t, "GET", "/api/v1/devices", nil)
	req.AddCookie(c)
	resp, body := a.Do(t, req)
	wantStatus(t, resp, body, 200)

	// State-changing requests do.
	req = a.Req(t, "POST", "/api/v1/pairing/codes", nil)
	req.AddCookie(c)
	resp, body = a.Do(t, req)
	wantProblem(t, resp, body, 403, "forbidden")

	req = a.Req(t, "POST", "/api/v1/pairing/codes", nil)
	req.AddCookie(c)
	req.Header.Set("X-CSRF-Token", "not-the-token")
	resp, body = a.Do(t, req)
	wantProblem(t, resp, body, 403, "forbidden")

	req = a.Req(t, "POST", "/api/v1/pairing/codes", nil)
	req.AddCookie(c)
	req.Header.Set("X-CSRF-Token", csrf)
	resp, body = a.Do(t, req)
	wantStatus(t, resp, body, 201)

	// Logout with the cookie clears it.
	req = a.Req(t, "POST", "/api/v1/auth/logout", nil)
	req.AddCookie(c)
	req.Header.Set("X-CSRF-Token", csrf)
	resp, body = a.Do(t, req)
	wantStatus(t, resp, body, 204)
	cleared := false
	for _, k := range resp.Cookies() {
		cleared = cleared || (k.Name == "pt_session" && k.MaxAge < 0)
	}
	if !cleared {
		t.Errorf("logout did not clear the cookie: %v", resp.Header["Set-Cookie"])
	}
	req = a.Req(t, "GET", "/api/v1/devices", nil)
	req.AddCookie(c)
	resp, body = a.Do(t, req)
	wantProblem(t, resp, body, 401, "unauthorized")
}

func TestRefresh(t *testing.T) {
	a, s := withAdmin(t)
	resp, body := call(t, a, "", "POST", "/api/v1/auth/refresh", map[string]any{"refresh_token": s.Refresh})
	wantStatus(t, resp, body, 200)
	var tp gen.TokenPair
	httpapitest.Decode(t, body, &tp)
	if tp.RefreshToken == s.Refresh || !strings.HasPrefix(tp.AccessToken, "pt_at_") {
		t.Fatalf("refresh: %+v", tp)
	}
	// Within the grace window the same pair comes back.
	resp, body = call(t, a, "", "POST", "/api/v1/auth/refresh", map[string]any{"refresh_token": s.Refresh})
	wantStatus(t, resp, body, 200)
	var again gen.TokenPair
	httpapitest.Decode(t, body, &again)
	if again.RefreshToken != tp.RefreshToken || again.AccessToken != tp.AccessToken {
		t.Fatal("grace-window refresh returned a different pair")
	}
	// After it, reuse revokes the device.
	a.Clock.Advance(31 * time.Second)
	resp, body = call(t, a, "", "POST", "/api/v1/auth/refresh", map[string]any{"refresh_token": s.Refresh})
	wantProblem(t, resp, body, 401, "refresh_token_reused")
	resp, body = call(t, a, tp.AccessToken, "GET", "/api/v1/devices", nil)
	wantProblem(t, resp, body, 401, "unauthorized")
}

func TestRefreshUnknownToken(t *testing.T) {
	a := httpapitest.New(t)
	resp, body := call(t, a, "", "POST", "/api/v1/auth/refresh", map[string]any{"refresh_token": "pt_rt_nope"})
	wantProblem(t, resp, body, 401, "unauthorized")
}

func TestTokenExpired(t *testing.T) {
	a, s := withAdmin(t)
	a.Clock.Advance(16 * time.Minute)
	resp, body := call(t, a, s.Access, "GET", "/api/v1/devices", nil)
	wantProblem(t, resp, body, 401, "token_expired")
}

func TestUnauthorized(t *testing.T) {
	a := httpapitest.New(t)
	resp, body := call(t, a, "", "GET", "/api/v1/devices", nil)
	wantProblem(t, resp, body, 401, "unauthorized")
	resp, body = call(t, a, "pt_at_garbage", "GET", "/api/v1/devices", nil)
	wantProblem(t, resp, body, 401, "unauthorized")
	req := a.Req(t, "GET", "/api/v1/devices", nil)
	req.Header.Set("Authorization", "Basic YWxpY2U6cHc=")
	resp, body = a.Do(t, req)
	wantProblem(t, resp, body, 401, "unauthorized")
}

func TestLogout(t *testing.T) {
	a, s := withAdmin(t)
	resp, body := call(t, a, s.Access, "POST", "/api/v1/auth/logout", nil)
	wantStatus(t, resp, body, 204)
	resp, body = call(t, a, s.Access, "GET", "/api/v1/devices", nil)
	wantProblem(t, resp, body, 401, "unauthorized")
}

func TestClientTooOld(t *testing.T) {
	a := httpapitest.New(t)
	a.SetupAdmin(t, adminUser, adminPass)
	req := a.Req(t, "POST", "/api/v1/auth/login", tokensLogin(adminUser, adminPass))
	req.Header.Set("PicTunnel-Client", "android/0.0.1")
	resp, body := a.Do(t, req)
	wantProblem(t, resp, body, 426, "client_too_old")

	// Exempt: server info, health, OPTIONS.
	for _, p := range []string{"/api/v1/server/info", "/healthz", "/readyz"} {
		req = a.Req(t, "GET", p, nil)
		req.Header.Set("PicTunnel-Client", "android/0.0.1")
		resp, body = a.Do(t, req)
		wantStatus(t, resp, body, 200)
	}
	// Equal or newer versions, unknown platforms and no header pass.
	for _, hdr := range []string{"android/0.1.0", "ios/1.2.3", "web/0.1.0-beta.1+b5", "desktop/0.0.1", ""} {
		req = a.Req(t, "GET", "/api/v1/server/info", nil)
		if hdr != "" {
			req.Header.Set("PicTunnel-Client", hdr)
		}
		resp, body = a.Do(t, req)
		wantStatus(t, resp, body, 200)
		req = a.Req(t, "POST", "/api/v1/auth/refresh", map[string]any{"refresh_token": "pt_rt_x"})
		if hdr != "" {
			req.Header.Set("PicTunnel-Client", hdr)
		}
		resp, body = a.Do(t, req)
		wantProblem(t, resp, body, 401, "unauthorized")
	}
}

func TestRateLimitedLogin(t *testing.T) {
	a := httpapitest.New(t)
	// mode tokens without a device fails validation before the password
	// hash, so the 10 allowed requests are cheap.
	bad := map[string]any{"username": "alice", "password": "x", "mode": "tokens"}
	for i := 0; i < 10; i++ {
		resp, body := call(t, a, "", "POST", "/api/v1/auth/login", bad)
		wantProblem(t, resp, body, 400, "invalid_request")
	}
	resp, body := call(t, a, "", "POST", "/api/v1/auth/login", bad)
	wantProblem(t, resp, body, 429, "rate_limited")
	if resp.Header.Get("Retry-After") == "" {
		t.Error("429 without Retry-After")
	}
	// Another username has its own bucket.
	other := map[string]any{"username": "bob", "password": "x", "mode": "tokens"}
	resp, body = call(t, a, "", "POST", "/api/v1/auth/login", other)
	wantProblem(t, resp, body, 400, "invalid_request")
	// The bucket refills with time.
	a.Clock.Advance(time.Minute)
	resp, body = call(t, a, "", "POST", "/api/v1/auth/login", bad)
	wantProblem(t, resp, body, 400, "invalid_request")
}

func TestRateLimitRedeemAndSetup(t *testing.T) {
	a := httpapitest.New(t, httpapitest.Local(), httpapitest.WithLimits(httpapi.RateLimits{
		Login:  httpapi.Limit{Count: 1, Per: time.Minute},
		Redeem: httpapi.Limit{Count: 2, Per: time.Minute},
		Setup:  httpapi.Limit{Count: 1, Per: time.Minute},
	}))
	redeem := map[string]any{"code": "AAAA-AAAA-AA",
		"device": map[string]any{"device_name": "x", "platform": "ios", "app_version": "1"}}
	for i := 0; i < 2; i++ {
		resp, body := call(t, a, "", "POST", "/api/v1/pairing/redeem", redeem)
		wantProblem(t, resp, body, 400, "pairing_code_invalid")
	}
	resp, body := call(t, a, "", "POST", "/api/v1/pairing/redeem", redeem)
	wantProblem(t, resp, body, 429, "rate_limited")

	resp, body = call(t, a, "", "POST", "/api/v1/auth/setup", `{}`)
	wantProblem(t, resp, body, 400, "invalid_request")
	resp, body = call(t, a, "", "POST", "/api/v1/auth/setup", `{}`)
	wantProblem(t, resp, body, 429, "rate_limited")
}

func TestRateLimitDisabled(t *testing.T) {
	a := httpapitest.New(t, httpapitest.WithConfig(func(c *config.Config) { c.RateLimit.Enabled = false }),
		httpapitest.WithLimits(httpapi.RateLimits{Login: httpapi.Limit{Count: 1, Per: time.Minute}}))
	bad := map[string]any{"username": "alice", "password": "x", "mode": "tokens"}
	for i := 0; i < 3; i++ {
		resp, body := call(t, a, "", "POST", "/api/v1/auth/login", bad)
		wantProblem(t, resp, body, 400, "invalid_request")
	}
}
