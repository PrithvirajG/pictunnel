package httpapi_test

import (
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/httpapitest"
)

// tus 1.0 requires Tus-Resumable on every non-OPTIONS response of the upload
// resources, including errors written by middleware before the tus handler.
func TestTusResumableOnMiddlewareErrors(t *testing.T) {
	a := httpapitest.New(t)

	req := a.Req(t, "PATCH", "/api/v1/uploads/01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f", []byte("x"))
	req.Header.Set("Tus-Resumable", "1.0.0")
	req.Header.Set("Upload-Offset", "0")
	req.Header.Set("Content-Type", "application/offset+octet-stream")
	resp, body := a.Do(t, req)
	wantProblem(t, resp, body, 401, "unauthorized")
	if got := resp.Header.Get("Tus-Resumable"); got != "1.0.0" {
		t.Errorf("401 PATCH Tus-Resumable = %q", got)
	}

	req = a.Req(t, "POST", "/api/v1/uploads", nil)
	req.Header.Set("Tus-Resumable", "1.0.0")
	req.Header.Set("Upload-Length", "10")
	req.Header.Set("PicTunnel-Client", "android/0.0.1")
	resp, body = a.Do(t, req)
	wantProblem(t, resp, body, 426, "client_too_old")
	if got := resp.Header.Get("Tus-Resumable"); got != "1.0.0" {
		t.Errorf("426 POST Tus-Resumable = %q", got)
	}

	req = a.Req(t, "GET", "/api/v1/uploads/a/b", nil)
	resp, _ = a.Do(t, req)
	if got := resp.Header.Get("Tus-Resumable"); got != "1.0.0" {
		t.Errorf("%d nested upload path Tus-Resumable = %q", resp.StatusCode, got)
	}

	resp, _ = call(t, a, "", "GET", "/api/v1/server/info", nil)
	if got := resp.Header.Get("Tus-Resumable"); got != "" {
		t.Errorf("non-upload path got Tus-Resumable %q", got)
	}
}
