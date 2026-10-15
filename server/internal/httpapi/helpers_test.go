package httpapi_test

import (
	"net/http"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/httpapitest"
)

const (
	adminUser = "alice"
	adminPass = "correct horse battery"
)

// problem is the decoded problem+json body.
type problem struct {
	Type      string `json:"type"`
	Title     string `json:"title"`
	Status    int    `json:"status"`
	Detail    string `json:"detail"`
	Code      string `json:"code"`
	RequestID string `json:"request_id"`
}

// withAdmin returns an app with admin alice logged in on a device.
func withAdmin(t *testing.T, opts ...httpapitest.Option) (*httpapitest.App, httpapitest.Session) {
	t.Helper()
	a := httpapitest.New(t, opts...)
	a.SetupAdmin(t, adminUser, adminPass)
	return a, a.Login(t, adminUser, adminPass)
}

// call sends method path with an optional bearer token and JSON body.
func call(t *testing.T, a *httpapitest.App, token, method, path string, body any) (*http.Response, []byte) {
	t.Helper()
	req := a.Req(t, method, path, body)
	if token != "" {
		httpapitest.Bearer(req, token)
	}
	return a.Do(t, req)
}

// wantProblem asserts status and code of a problem response.
func wantProblem(t *testing.T, resp *http.Response, body []byte, status int, code string) problem {
	t.Helper()
	if resp.StatusCode != status {
		t.Fatalf("status %d, want %d: %s", resp.StatusCode, status, body)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/problem+json" {
		t.Fatalf("content type %q: %s", ct, body)
	}
	var p problem
	httpapitest.Decode(t, body, &p)
	if p.Code != code {
		t.Fatalf("code %q, want %q: %s", p.Code, code, body)
	}
	return p
}

// wantStatus asserts the status code.
func wantStatus(t *testing.T, resp *http.Response, body []byte, status int) {
	t.Helper()
	if resp.StatusCode != status {
		t.Fatalf("status %d, want %d: %s", resp.StatusCode, status, body)
	}
}
