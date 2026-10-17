package httpapi_test

// HTTP-level tests for the statuses the middleware produces on every
// operation (426 version gate, 403 CSRF) and the upload lock statuses of
// HEAD and DELETE (S§11.3 contract coverage).

import (
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/config"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/httpapitest"
)

var pathIDs = strings.NewReplacer(
	"{upload_id}", "01928f40-1111-7aaa-8bbb-0123456789ab",
	"{asset_id}", "01928f40-2222-7aaa-8bbb-0123456789ab",
	"{device_id}", "01928f40-3333-7aaa-8bbb-0123456789ab",
	"{sha256}", shaOf([]byte("x")),
)

// forEachOperation calls fn for every operation of the embedded spec that
// documents status.
func forEachOperation(t *testing.T, status int, fn func(id, method, path string)) int {
	t.Helper()
	doc, err := gen.GetSpec()
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for path, item := range doc.Paths.Map() {
		for method, op := range item.Operations() {
			if op.Responses.Status(status) != nil {
				n++
				fn(op.OperationID, method, pathIDs.Replace(path))
			}
		}
	}
	return n
}

// TestVersionGateOnDocumentedOperations: every operation that documents 426
// answers client_too_old below the configured minimum, before auth.
func TestVersionGateOnDocumentedOperations(t *testing.T) {
	a := httpapitest.New(t, httpapitest.WithConfig(func(c *config.Config) { c.Clients.MinVersion["android"] = "9.0.0" }))
	n := forEachOperation(t, 426, func(id, method, path string) {
		req := a.Req(t, method, path, nil)
		req.Header.Set("PicTunnel-Client", "android/1.0.0")
		req.Header.Set("Tus-Resumable", tusVersion)
		resp, body := a.Do(t, req)
		if method == http.MethodHead {
			wantStatus(t, resp, body, 426)
			return
		}
		wantProblem(t, resp, body, 426, "client_too_old")
	})
	// Every operation except server info, the probes and OPTIONS (S§4.4).
	if n != 26 {
		t.Fatalf("%d operations document 426, want 26", n)
	}
}

// TestCSRFOnDocumentedOperations: every operation that documents 403
// rejects a cookie session without X-CSRF-Token (setup has its own 403).
func TestCSRFOnDocumentedOperations(t *testing.T) {
	a := httpapitest.New(t)
	a.SetupAdmin(t, adminUser, adminPass)
	c, _ := cookieLogin(t, a)
	n := forEachOperation(t, 403, func(id, method, path string) {
		if id == "SetupFirstAdmin" || id == "setupFirstAdmin" {
			return
		}
		req := a.Req(t, method, path, nil)
		req.AddCookie(c)
		req.Header.Set("Tus-Resumable", tusVersion)
		resp, body := a.Do(t, req)
		wantProblem(t, resp, body, 403, "forbidden")
	})
	if n < 13 {
		t.Fatalf("only %d operations document 403", n)
	}
}

// TestDeleteTombstoneMalformedHash: the path must be 64 lowercase hex digits.
func TestDeleteTombstoneMalformedHash(t *testing.T) {
	a, s := withAdmin(t)
	for _, p := range []string{"not-a-hash", strings.ToUpper(shaOf([]byte("x")))} {
		resp, body := call(t, a, s.Access, "DELETE", "/api/v1/tombstones/"+p, nil)
		wantProblem(t, resp, body, 400, "invalid_request")
	}
}

// TestUploadLockedHeadAndDelete holds the upload lock with a slowly
// streamed PATCH: HEAD is refused after its lock wait and DELETE at once,
// both with 423 upload_locked; the PATCH then completes normally.
func TestUploadLockedHeadAndDelete(t *testing.T) {
	a, s := withAdmin(t)
	content := []byte(strings.Repeat("pictunnel", 1000))
	resp, body := a.Do(t, createReq(t, a, s.Access, content, shaOf(content), nil))
	wantStatus(t, resp, body, 201)
	loc := resp.Header.Get("Location")

	pr, pw := io.Pipe()
	slow, err := http.NewRequest(http.MethodPatch, a.Server.URL+loc, pr)
	if err != nil {
		t.Fatal(err)
	}
	slow.ContentLength = 200
	httpapitest.Bearer(slow, s.Access)
	slow.Header.Set("Tus-Resumable", tusVersion)
	slow.Header.Set("Content-Type", "application/offset+octet-stream")
	slow.Header.Set("Upload-Offset", "0")
	done := make(chan *http.Response, 1)
	go func() {
		r, err := http.DefaultClient.Do(slow)
		if err != nil {
			done <- nil
			return
		}
		b, _ := io.ReadAll(r.Body)
		_ = r.Body.Close()
		r.Body = io.NopCloser(strings.NewReader(string(b)))
		done <- r
	}()
	if _, err := pw.Write(content[:10]); err != nil {
		t.Fatal(err)
	}

	// HEAD waits up to LockWait for the lock: 200 means the PATCH has not
	// taken it yet, 423 that it holds it.
	locked := false
	for deadline := time.Now().Add(20 * time.Second); !locked && time.Now().Before(deadline); {
		resp, body = a.Do(t, tusReq(t, a, s.Access, http.MethodHead, loc, nil))
		switch resp.StatusCode {
		case 423:
			locked = true
		case 200:
			time.Sleep(5 * time.Millisecond)
		default:
			t.Fatalf("HEAD while streaming: %d %s", resp.StatusCode, body)
		}
	}
	if !locked {
		t.Fatal("HEAD never saw upload_locked")
	}
	resp, body = a.Do(t, tusReq(t, a, s.Access, http.MethodDelete, loc, nil))
	wantProblem(t, resp, body, 423, "upload_locked")

	if _, err := pw.Write(content[10:200]); err != nil {
		t.Fatal(err)
	}
	_ = pw.Close()
	r := <-done
	if r == nil {
		t.Fatal("slow PATCH failed")
	}
	httpapitest.AssertContract(t, slow, r)
	if r.StatusCode != 204 || r.Header.Get("Upload-Offset") != strconv.Itoa(200) {
		t.Fatalf("slow PATCH: %d %v", r.StatusCode, r.Header)
	}
}
