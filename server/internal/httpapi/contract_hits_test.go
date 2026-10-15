package httpapi_test

// HTTP-level tests that reach the documented statuses no handler-focused
// test reaches (S§11.3): the real tus handler end to end, credentials on
// every secured operation, the version gate and a few validation paths.

import (
	"encoding/base64"
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

const tusVersion = "1.0.0"

func tusMeta(sha, filename, mime string) string {
	enc := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
	return "sha256 " + enc(sha) + ",filename " + enc(filename) + ",mime " + enc(mime)
}

// tusReq is a tus request with the bearer token (if any) and Tus-Resumable.
func tusReq(t *testing.T, a *httpapitest.App, token, method, path string, body []byte) *http.Request {
	t.Helper()
	var b any
	if body != nil {
		b = body
	}
	req := a.Req(t, method, path, b)
	if token != "" {
		httpapitest.Bearer(req, token)
	}
	req.Header.Set("Tus-Resumable", tusVersion)
	if len(body) > 0 || method == http.MethodPatch {
		req.Header.Set("Content-Type", "application/offset+octet-stream")
	}
	return req
}

func createReq(t *testing.T, a *httpapitest.App, token string, content []byte, sha string, body []byte) *http.Request {
	t.Helper()
	req := tusReq(t, a, token, http.MethodPost, "/api/v1/uploads", body)
	req.Header.Set("Upload-Length", strconv.Itoa(len(content)))
	req.Header.Set("Upload-Metadata", tusMeta(sha, "IMG_1.JPG", "image/jpeg"))
	return req
}

func patchReq(t *testing.T, a *httpapitest.App, token, loc string, off int, body []byte) *http.Request {
	t.Helper()
	req := tusReq(t, a, token, http.MethodPatch, loc, body)
	req.Header.Set("Upload-Offset", strconv.Itoa(off))
	return req
}

// TestTusContract walks one session through every documented outcome of
// the tus operations that a single client can trigger.
func TestTusContract(t *testing.T) {
	a, s := withAdmin(t)
	content := []byte(strings.Repeat("pictunnel", 1000))
	sha := shaOf(content)

	resp, body := call(t, a, "", "OPTIONS", "/api/v1/uploads", nil)
	wantStatus(t, resp, body, 204)
	if resp.Header.Get("Tus-Extension") == "" {
		t.Fatalf("OPTIONS headers: %v", resp.Header)
	}

	// createUpload: 412, 400, 413, then 201.
	req := createReq(t, a, s.Access, content, sha, nil)
	req.Header.Del("Tus-Resumable")
	resp, body = a.Do(t, req)
	wantProblem(t, resp, body, 412, "invalid_request")
	req = createReq(t, a, s.Access, content, sha, nil)
	req.Header.Set("Upload-Metadata", "sha256 not-base64!")
	resp, body = a.Do(t, req)
	wantProblem(t, resp, body, 400, "invalid_request")
	req = createReq(t, a, s.Access, content, sha, nil)
	req.Header.Set("Upload-Length", "53687091201")
	resp, body = a.Do(t, req)
	wantProblem(t, resp, body, 413, "file_too_large")
	resp, body = a.Do(t, createReq(t, a, s.Access, content, sha, nil))
	wantStatus(t, resp, body, 201)
	loc := resp.Header.Get("Location")

	// getUploadOffset: 412, 200.
	req = tusReq(t, a, s.Access, http.MethodHead, loc, nil)
	req.Header.Del("Tus-Resumable")
	resp, body = a.Do(t, req)
	wantStatus(t, resp, body, 412)
	resp, body = a.Do(t, tusReq(t, a, s.Access, http.MethodHead, loc, nil))
	wantStatus(t, resp, body, 200)
	if resp.Header.Get("Upload-Offset") != "0" || resp.Header.Get("Upload-Length") != strconv.Itoa(len(content)) {
		t.Fatalf("HEAD headers: %v", resp.Header)
	}

	// appendUpload: 400, 412, 409, 460, then 204.
	req = patchReq(t, a, s.Access, loc, 0, content[:100])
	req.Header.Del("Upload-Offset")
	resp, body = a.Do(t, req)
	wantProblem(t, resp, body, 400, "invalid_request")
	req = patchReq(t, a, s.Access, loc, 0, content[:100])
	req.Header.Del("Tus-Resumable")
	resp, body = a.Do(t, req)
	wantProblem(t, resp, body, 412, "invalid_request")
	resp, body = a.Do(t, patchReq(t, a, s.Access, loc, 50, content[50:100]))
	wantProblem(t, resp, body, 409, "offset_mismatch")
	req = patchReq(t, a, s.Access, loc, 0, content[:100])
	req.Header.Set("Upload-Checksum", "sha256 "+base64.StdEncoding.EncodeToString(make([]byte, 32)))
	resp, body = a.Do(t, req)
	wantProblem(t, resp, body, 460, "checksum_mismatch")
	resp, body = a.Do(t, patchReq(t, a, s.Access, loc, 0, content[:100]))
	wantStatus(t, resp, body, 204)
	if resp.Header.Get("Upload-Offset") != "100" {
		t.Fatalf("PATCH offset: %v", resp.Header)
	}

	// appendUpload 423: a second request while one is streaming its body.
	patchWhileLocked(t, a, s, loc, content, 100)

	// terminateUpload: 412, 204, then the session is gone for all three.
	req = tusReq(t, a, s.Access, http.MethodDelete, loc, nil)
	req.Header.Del("Tus-Resumable")
	resp, body = a.Do(t, req)
	wantProblem(t, resp, body, 412, "invalid_request")
	resp, body = a.Do(t, tusReq(t, a, s.Access, http.MethodDelete, loc, nil))
	wantStatus(t, resp, body, 204)
	resp, body = a.Do(t, tusReq(t, a, s.Access, http.MethodHead, loc, nil))
	wantStatus(t, resp, body, 404)
	resp, body = a.Do(t, patchReq(t, a, s.Access, loc, 0, content[:10]))
	wantProblem(t, resp, body, 404, "not_found")
	resp, body = a.Do(t, tusReq(t, a, s.Access, http.MethodDelete, loc, nil))
	wantProblem(t, resp, body, 404, "not_found")

	// createUpload 460: creation-with-upload whose bytes do not hash to the
	// declared sha256.
	other := []byte(strings.Repeat("x", len(content)))
	resp, body = a.Do(t, createReq(t, a, s.Access, other, sha, other))
	wantProblem(t, resp, body, 460, "checksum_mismatch")

	// createUpload 409: purged content is tombstoned.
	id := a.SeedAsset(t, s, content, "IMG_1.JPG", "image/jpeg")
	for _, op := range []string{"trash", "purge"} {
		resp, body = call(t, a, s.Access, "POST", "/api/v1/assets/"+op, map[string]any{"asset_ids": []string{id}})
		wantStatus(t, resp, body, 200)
	}
	resp, body = a.Do(t, createReq(t, a, s.Access, content, sha, nil))
	wantProblem(t, resp, body, 409, "tombstoned")
}

// patchWhileLocked streams a PATCH body slowly and sends empty PATCHes
// until one of the two requests is refused with 423 upload_locked.
func patchWhileLocked(t *testing.T, a *httpapitest.App, s httpapitest.Session, loc string, content []byte, off int) {
	t.Helper()
	pr, pw := io.Pipe()
	slow, err := http.NewRequest(http.MethodPatch, a.Server.URL+loc, pr)
	if err != nil {
		t.Fatal(err)
	}
	slow.ContentLength = 200
	httpapitest.Bearer(slow, s.Access)
	slow.Header.Set("Tus-Resumable", tusVersion)
	slow.Header.Set("Content-Type", "application/offset+octet-stream")
	slow.Header.Set("Upload-Offset", strconv.Itoa(off))
	type result struct {
		resp *http.Response
		err  error
	}
	done := make(chan result, 1)
	go func() {
		resp, err := http.DefaultClient.Do(slow)
		if err == nil {
			b, _ := io.ReadAll(resp.Body)
			_ = resp.Body.Close()
			resp.Body = io.NopCloser(strings.NewReader(string(b)))
		}
		done <- result{resp, err}
	}()
	if _, err := pw.Write(content[off : off+10]); err != nil {
		t.Fatal(err)
	}
	locked := false
	deadline := time.Now().Add(10 * time.Second)
	for !locked && time.Now().Before(deadline) {
		resp, body := a.Do(t, patchReq(t, a, s.Access, loc, off, []byte{}))
		switch resp.StatusCode {
		case 423:
			wantProblem(t, resp, body, 423, "upload_locked")
			locked = true
		case 204:
			time.Sleep(5 * time.Millisecond)
		default:
			t.Fatalf("probe PATCH: %d %s", resp.StatusCode, body)
		}
	}
	go func() {
		_, _ = pw.Write(content[off+10 : off+200])
		_ = pw.Close()
	}()
	r := <-done
	if r.err != nil {
		t.Fatal(r.err)
	}
	httpapitest.AssertContract(t, slow, r.resp)
	if r.resp.StatusCode == 423 {
		locked = true
	} else if r.resp.StatusCode != 204 || r.resp.Header.Get("Upload-Offset") != strconv.Itoa(off+200) {
		t.Fatalf("slow PATCH: %d %v", r.resp.StatusCode, r.resp.Header)
	}
	if !locked {
		t.Fatal("no request saw upload_locked")
	}
}

// TestCreateUploadInsufficientStorage: a new session needs its length plus
// the reserve free on the staging and library volumes (P§7.3 #6).
func TestCreateUploadInsufficientStorage(t *testing.T) {
	a, s := withAdmin(t, httpapitest.WithFreeSpace(func(string) (uint64, error) { return 1 << 20, nil }))
	content := []byte("small")
	resp, body := a.Do(t, createReq(t, a, s.Access, content, shaOf(content), nil))
	wantProblem(t, resp, body, 507, "insufficient_storage")
}

// TestSecuredOperationsNeedCredentials sends every operation that declares
// 401 without credentials.
func TestSecuredOperationsNeedCredentials(t *testing.T) {
	a := httpapitest.New(t)
	doc, err := gen.GetSwagger()
	if err != nil {
		t.Fatal(err)
	}
	ids := strings.NewReplacer(
		"{upload_id}", "01928f40-1111-7aaa-8bbb-0123456789ab",
		"{asset_id}", "01928f40-2222-7aaa-8bbb-0123456789ab",
		"{device_id}", "01928f40-3333-7aaa-8bbb-0123456789ab",
		"{sha256}", shaOf([]byte("x")),
	)
	n := 0
	for path, item := range doc.Paths.Map() {
		for method, op := range item.Operations() {
			if op.Responses.Status(401) == nil || (op.Security != nil && len(*op.Security) == 0) {
				continue
			}
			n++
			req := a.Req(t, method, ids.Replace(path), nil)
			if strings.HasPrefix(path, "/api/v1/uploads") {
				req.Header.Set("Tus-Resumable", tusVersion)
			}
			resp, body := a.Do(t, req)
			if resp.StatusCode != 401 {
				t.Errorf("%s %s without credentials: %d %s", method, path, resp.StatusCode, body)
			}
		}
	}
	if n < 20 {
		t.Fatalf("only %d secured operations found", n)
	}
}

// TestVersionGateOnDocumentedOperations: the operations that document 426
// answer client_too_old below the configured minimum.
func TestVersionGateOnDocumentedOperations(t *testing.T) {
	a := httpapitest.New(t, httpapitest.WithConfig(func(c *config.Config) { c.Clients.MinVersion["android"] = "9.0.0" }))
	for _, tc := range []struct{ method, path string }{
		{"POST", "/api/v1/sync/check"},
		{"POST", "/api/v1/uploads"},
		{"POST", "/api/v1/pairing/redeem"},
		{"POST", "/api/v1/auth/refresh"},
	} {
		req := a.Req(t, tc.method, tc.path, nil)
		req.Header.Set("PicTunnel-Client", "android/1.0.0")
		req.Header.Set("Tus-Resumable", tusVersion)
		resp, body := a.Do(t, req)
		wantProblem(t, resp, body, 426, "client_too_old")
	}
}

// TestBadRequestBodies covers the 400s of refresh, restore and purge.
func TestBadRequestBodies(t *testing.T) {
	a, s := withAdmin(t)
	resp, body := call(t, a, "", "POST", "/api/v1/auth/refresh", "not json")
	wantProblem(t, resp, body, 400, "invalid_request")
	for _, op := range []string{"restore", "purge"} {
		resp, body = call(t, a, s.Access, "POST", "/api/v1/assets/"+op, map[string]any{"asset_ids": []string{}})
		wantProblem(t, resp, body, 400, "invalid_request")
	}
}

// TestPlaybackRangeNotSatisfiable: a range past the end of a playable
// video is 416.
func TestPlaybackRangeNotSatisfiable(t *testing.T) {
	a, s := withAdmin(t)
	vid := a.SeedAsset(t, s, []byte(strings.Repeat("mp4!", 16)), "clip.mp4", "video/mp4")
	a.SetPlayable(t, vid, true)
	req := httpapitest.Bearer(a.Req(t, "GET", "/api/v1/assets/"+vid+"/playback", nil), s.Access)
	req.Header.Set("Range", "bytes=1000-2000")
	resp, body := a.Do(t, req)
	wantProblem(t, resp, body, 416, "invalid_request")
}
