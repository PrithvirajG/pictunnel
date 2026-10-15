package httpapi_test

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/httpapitest"
)

func TestHealthz(t *testing.T) {
	a := httpapitest.New(t)
	resp, body := call(t, a, "", "GET", "/healthz", nil)
	wantStatus(t, resp, body, 200)
	if string(body) != "ok" || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/plain") {
		t.Fatalf("healthz: %q %q", resp.Header.Get("Content-Type"), body)
	}
}

func TestReadyz(t *testing.T) {
	a := httpapitest.New(t)
	resp, body := call(t, a, "", "GET", "/readyz", nil)
	wantStatus(t, resp, body, 200)
	if string(body) != "ready" {
		t.Fatalf("readyz body %q", body)
	}
}

func TestReadyzServerUnavailable(t *testing.T) {
	a := httpapitest.New(t, httpapitest.WithReady(func(context.Context) error {
		return errors.New("disk /secret/path not writable")
	}))
	resp, body := call(t, a, "", "GET", "/readyz", nil)
	wantProblem(t, resp, body, 503, "server_unavailable")
	if resp.Header.Get("Retry-After") == "" {
		t.Error("503 without Retry-After")
	}
	if strings.Contains(string(body), "secret") {
		t.Errorf("readyz leaks the error: %s", body)
	}
}

func TestServerInfo(t *testing.T) {
	a := httpapitest.New(t)
	a.Clock.Advance(90 * time.Second)
	resp, body := call(t, a, "", "GET", "/api/v1/server/info", nil)
	wantStatus(t, resp, body, 200)
	var info gen.ServerInfo
	httpapitest.Decode(t, body, &info)
	if info.ServerId.String() != httpapitest.ServerID || !info.Time.Equal(httpapitest.T0.Add(90*time.Second)) {
		t.Fatalf("info: %+v", info)
	}
	if info.Upload.MaxFileBytes != 53687091200 || info.Upload.RecommendedChunkBytes != 8388608 {
		t.Fatalf("upload limits: %+v", info.Upload)
	}
}

func TestPanicGivesInternalProblem(t *testing.T) {
	a := httpapitest.New(t, httpapitest.WithInfo(func() gen.ServerInfo {
		panic("boom: secret internals")
	}))
	resp, body := call(t, a, "", "GET", "/api/v1/server/info", nil)
	p := wantProblem(t, resp, body, 500, "internal")
	if p.RequestID == "" {
		t.Fatal("no request_id")
	}
	for _, leak := range []string{"boom", "secret", "goroutine", ".go:"} {
		if strings.Contains(string(body), leak) {
			t.Errorf("500 body leaks %q: %s", leak, body)
		}
	}
}

func TestRequestIDEcho(t *testing.T) {
	a := httpapitest.New(t)
	req := a.Req(t, "GET", "/api/v1/devices", nil)
	req.Header.Set("X-Request-Id", "req-abc-123")
	resp, body := a.Do(t, req)
	p := wantProblem(t, resp, body, 401, "unauthorized")
	if resp.Header.Get("X-Request-Id") != "req-abc-123" || p.RequestID != "req-abc-123" {
		t.Fatalf("request id not echoed: header %q body %q", resp.Header.Get("X-Request-Id"), p.RequestID)
	}

	resp, body = call(t, a, "", "GET", "/api/v1/devices", nil)
	p = wantProblem(t, resp, body, 401, "unauthorized")
	if id := resp.Header.Get("X-Request-Id"); id == "" || id != p.RequestID {
		t.Fatalf("generated request id: header %q body %q", id, p.RequestID)
	}

	// A malformed incoming id is replaced.
	req = a.Req(t, "GET", "/healthz", nil)
	req.Header.Set("X-Request-Id", strings.Repeat("x", 300))
	resp, _ = a.Do(t, req)
	if id := resp.Header.Get("X-Request-Id"); id == "" || len(id) > 128 {
		t.Fatalf("oversized request id echoed: %q", id)
	}
}

func TestUnknownRouteIsNotFoundProblem(t *testing.T) {
	a, s := withAdmin(t)
	resp, body := call(t, a, s.Access, "GET", "/api/v1/nope", nil)
	wantProblem(t, resp, body, 404, "not_found")
}

func TestUploadRoutesGoToTus(t *testing.T) {
	var (
		mu   sync.Mutex
		hits []string
	)
	tus := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		hits = append(hits, r.Method+" "+r.URL.Path)
		mu.Unlock()
		w.Header().Set("Tus-Resumable", "1.0.0")
		w.WriteHeader(http.StatusNoContent)
	})
	a, s := withAdmin(t, httpapitest.WithTus(tus))

	// OPTIONS is public; the others need credentials.
	resp, body := call(t, a, "", "OPTIONS", "/api/v1/uploads", nil)
	wantStatus(t, resp, body, 204)
	resp, body = call(t, a, "", "POST", "/api/v1/uploads", nil)
	wantProblem(t, resp, body, 401, "unauthorized")
	for _, m := range []string{"POST", "HEAD", "PATCH", "DELETE"} {
		path := "/api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab"
		if m == "POST" {
			path = "/api/v1/uploads"
		}
		resp, body = call(t, a, s.Access, m, path, nil)
		wantStatus(t, resp, body, 204)
	}
	want := []string{"OPTIONS /api/v1/uploads", "POST /api/v1/uploads",
		"HEAD /api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab",
		"PATCH /api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab",
		"DELETE /api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab"}
	mu.Lock()
	defer mu.Unlock()
	if strings.Join(hits, "|") != strings.Join(want, "|") {
		t.Fatalf("tus hits %v, want %v", hits, want)
	}
}
