package httpapitest

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// failTB captures failures instead of failing the real test.
type failTB struct {
	testing.TB
	msgs []string
}

func (f *failTB) Helper() {}
func (f *failTB) Errorf(format string, args ...any) {
	f.msgs = append(f.msgs, fmt.Sprintf(format, args...))
}
func (f *failTB) Fatalf(format string, args ...any) {
	f.msgs = append(f.msgs, fmt.Sprintf(format, args...))
}
func (f *failTB) Fatal(args ...any) { f.msgs = append(f.msgs, fmt.Sprint(args...)) }

func response(status int, ct, body string) *http.Response {
	h := http.Header{}
	if ct != "" {
		h.Set("Content-Type", ct)
	}
	return &http.Response{StatusCode: status, Header: h, Body: io.NopCloser(bytes.NewBufferString(body))}
}

// The helper must reject responses that break the contract.
func TestAssertContractRejectsViolations(t *testing.T) {
	cases := []struct {
		name, method, path string
		resp               *http.Response
	}{
		{"missing required field", "GET", "/api/v1/server/info", response(200, "application/json", `{"name":"x"}`)},
		{"wrong content type", "GET", "/api/v1/devices", response(200, "text/plain", `hi`)},
		{"closed value broken", "GET", "/api/v1/devices", response(200, "application/json", `{"devices":[{"id":"not-uuid","name":"a","platform":"ios","app_version":"1","created_at":"2026-01-01T00:00:00Z"}]}`)},
		{"problem without request_id", "GET", "/api/v1/devices", response(401, "application/problem+json",
			`{"type":"urn:pictunnel:problem:unauthorized","title":"Unauthorized","status":401,"code":"unauthorized"}`)},
		{"problem type mismatch", "GET", "/nope", response(404, "application/problem+json",
			`{"type":"about:blank","title":"x","status":404,"code":"not_found","request_id":"r"}`)},
	}
	for _, c := range cases {
		f := &failTB{}
		AssertContract(f, httptest.NewRequest(c.method, c.path, nil), c.resp)
		if len(f.msgs) == 0 {
			t.Errorf("%s: accepted", c.name)
		}
	}

	ok := &failTB{}
	AssertContract(ok, httptest.NewRequest("GET", "/api/v1/devices", nil),
		response(200, "application/json", `{"devices":[]}`))
	if len(ok.msgs) != 0 {
		t.Errorf("valid response rejected: %v", ok.msgs)
	}
	if sts := Coverage()["ListDevices"]; len(sts) == 0 {
		t.Errorf("coverage not recorded: %v", Coverage())
	}
}
