package httpapi_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/httpapi"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/httpapitest"
)

func TestLoopbackRejectsForeignHost(t *testing.T) {
	a := httpapitest.New(t, httpapitest.Local())
	for _, host := range []string{"evil.example", "evil.example:8080", "192.168.1.20:8080", "localhost.evil.example"} {
		req := a.Req(t, "POST", "/api/v1/auth/setup", setupBody)
		req.Host = host
		resp, body := a.Do(t, req)
		wantProblem(t, resp, body, 403, "forbidden")
	}
	for _, host := range []string{"localhost:8080", "LOCALHOST", "127.0.0.1", "[::1]:8080"} {
		req := a.Req(t, "GET", "/healthz", nil)
		req.Host = host
		resp, body := a.Do(t, req)
		wantStatus(t, resp, body, 200)
	}
	// The LAN listener does not apply the guard.
	l := httpapitest.New(t)
	req := l.Req(t, "GET", "/healthz", nil)
	req.Host = "photos.example"
	resp, body := l.Do(t, req)
	wantStatus(t, resp, body, 200)
}

// A web page the operator visits must not be able to drive the token-less
// setup on the loopback listener with a cross-site request.
func TestLoopbackRejectsCrossSiteWrites(t *testing.T) {
	a := httpapitest.New(t, httpapitest.Local())
	for _, h := range []map[string]string{
		{"Origin": "https://evil.example"},
		{"Origin": "null"},
		{"Origin": "http://localhost.evil.example:8080"},
		{"Sec-Fetch-Site": "cross-site"},
		{"Sec-Fetch-Site": "same-site"},
	} {
		req := a.Req(t, "POST", "/api/v1/auth/setup", setupBody)
		for k, v := range h {
			req.Header.Set(k, v)
		}
		resp, body := a.Do(t, req)
		wantProblem(t, resp, body, 403, "forbidden")
	}
	// Reads stay open, and a same-origin page or a non-browser client works.
	req := a.Req(t, "GET", "/healthz", nil)
	req.Header.Set("Origin", "https://evil.example")
	resp, body := a.Do(t, req)
	wantStatus(t, resp, body, 200)
	req = a.Req(t, "POST", "/api/v1/auth/setup", setupBody)
	req.Header.Set("Origin", "http://127.0.0.1:8080")
	req.Header.Set("Sec-Fetch-Site", "same-origin")
	resp, body = a.Do(t, req)
	wantStatus(t, resp, body, 201)
}

func TestNosniffOnAllResponses(t *testing.T) {
	a, s := withAdmin(t)
	id := a.SeedAsset(t, s, []byte("bytes"), "n.jpg", "image/jpeg")
	for _, p := range []string{"/healthz", "/api/v1/server/info", "/api/v1/devices", "/api/v1/assets/" + id + "/original"} {
		resp, _ := call(t, a, s.Access, "GET", p, nil)
		if resp.Header.Get("X-Content-Type-Options") != "nosniff" {
			t.Errorf("%s: no nosniff", p)
		}
	}
}

func TestRangeProblemDropsDisposition(t *testing.T) {
	a, s := withAdmin(t)
	id := a.SeedAsset(t, s, []byte("short"), "d.jpg", "image/jpeg")
	req := httpapitest.Bearer(a.Req(t, "GET", "/api/v1/assets/"+id+"/original", nil), s.Access)
	req.Header.Set("Range", "bytes=100-200")
	resp, body := a.Do(t, req)
	wantProblem(t, resp, body, 416, "invalid_request")
	if resp.Header.Get("Content-Disposition") != "" || resp.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("416 headers: %v", resp.Header)
	}
}

func TestCSRFEnforcedOnTus(t *testing.T) {
	var (
		mu   sync.Mutex
		hits int
	)
	tus := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		hits++
		mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	})
	a := httpapitest.New(t, httpapitest.WithTus(tus))
	a.SetupAdmin(t, adminUser, adminPass)
	c, csrf := cookieLogin(t, a)
	up := "/api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab"
	for _, mp := range [][2]string{{"POST", "/api/v1/uploads"}, {"PATCH", up}, {"DELETE", up}} {
		req := a.Req(t, mp[0], mp[1], nil)
		req.AddCookie(c)
		resp, body := a.Do(t, req)
		wantProblem(t, resp, body, 403, "forbidden")

		req = a.Req(t, mp[0], mp[1], nil)
		req.AddCookie(c)
		req.Header.Set("X-CSRF-Token", csrf)
		resp, body = a.Do(t, req)
		wantStatus(t, resp, body, 204)
	}
	// HEAD is safe and needs no token.
	req := a.Req(t, "HEAD", up, nil)
	req.AddCookie(c)
	resp, body := a.Do(t, req)
	wantStatus(t, resp, body, 204)
	mu.Lock()
	defer mu.Unlock()
	if hits != 4 {
		t.Fatalf("tus reached %d times, want 4", hits)
	}
}

func TestOptionsOnUploadResourceNeedsAuth(t *testing.T) {
	tus := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })
	a := httpapitest.New(t, httpapitest.WithTus(tus))
	resp, body := call(t, a, "", "OPTIONS", "/api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab", nil)
	wantProblem(t, resp, body, 401, "unauthorized")
}

func TestForwardedForDoesNotChangeRateKey(t *testing.T) {
	a := httpapitest.New(t, httpapitest.WithLimits(httpapi.RateLimits{Login: httpapi.Limit{Count: 1, Per: time.Minute}}))
	bad := map[string]any{"username": "alice", "password": "x", "mode": "tokens"}
	resp, body := call(t, a, "", "POST", "/api/v1/auth/login", bad)
	wantProblem(t, resp, body, 400, "invalid_request")
	for _, xff := range []string{"203.0.113.7", "198.51.100.1, 10.0.0.1"} {
		req := a.Req(t, "POST", "/api/v1/auth/login", bad)
		req.Header.Set("X-Forwarded-For", xff)
		req.Header.Set("X-Real-IP", xff)
		resp, body = a.Do(t, req)
		wantProblem(t, resp, body, 429, "rate_limited")
	}
}

func TestRequestIDWithControlCharsReplaced(t *testing.T) {
	a := httpapitest.New(t)
	for _, bad := range []string{"abc\r\nX-Evil: 1", "abc\ndef", "has space", "tab\there"} {
		req := httptest.NewRequest("GET", "/healthz", nil)
		req.Header.Set("X-Request-Id", bad)
		w := httptest.NewRecorder()
		a.Handler.ServeHTTP(w, req)
		id := w.Header().Get("X-Request-Id")
		if id == "" || id == bad || strings.ContainsAny(id, " \r\n\t") || w.Header().Get("X-Evil") != "" {
			t.Errorf("request id %q echoed as %q", bad, id)
		}
	}
}

// The loopback handler refuses peers that are not loopback, even with a
// loopback Host, so a misbound local listener never exposes token-less
// setup or non-Secure cookies to the LAN.
func TestLoopbackRejectsNonLoopbackPeer(t *testing.T) {
	a := httpapitest.New(t, httpapitest.Local())
	for _, remote := range []string{"192.168.1.5:40000", "[2001:db8::7]:40000", "10.0.0.1:1", "garbage"} {
		req := httptest.NewRequest("POST", "/api/v1/auth/setup", strings.NewReader(`{"username":"alice","password":"`+adminPass+`"}`))
		req.Header.Set("Content-Type", "application/json")
		req.Host = "127.0.0.1:8080"
		req.RemoteAddr = remote
		rec := httptest.NewRecorder()
		a.Handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusForbidden || !strings.Contains(rec.Body.String(), `"code":"forbidden"`) {
			t.Fatalf("peer %s: %d %s", remote, rec.Code, rec.Body.String())
		}
	}
	for _, remote := range []string{"127.0.0.1:40000", "127.8.9.10:1", "[::1]:40000"} {
		req := httptest.NewRequest("GET", "/healthz", nil)
		req.Host = "localhost"
		req.RemoteAddr = remote
		rec := httptest.NewRecorder()
		a.Handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("loopback peer %s: %d %s", remote, rec.Code, rec.Body.String())
		}
	}
	// The LAN handler accepts any peer.
	l := httpapitest.New(t)
	req := httptest.NewRequest("GET", "/healthz", nil)
	req.RemoteAddr = "192.168.1.5:40000"
	rec := httptest.NewRecorder()
	l.Handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("LAN handler: %d", rec.Code)
	}
}
