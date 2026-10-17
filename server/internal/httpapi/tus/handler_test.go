package tus_test

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/httpapitest"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/tus"
)

const (
	user     = "alice"
	pass     = "correct horse battery"
	octet    = "application/offset+octet-stream"
	uploads  = "/api/v1/uploads"
	tusVer   = "1.0.0"
	extsWant = "creation,creation-with-upload,termination,expiration,checksum"
)

type env struct {
	a *httpapitest.App
	s httpapitest.Session
}

func newEnv(t *testing.T) env {
	t.Helper()
	a := httpapitest.New(t)
	a.SetupAdmin(t, user, pass)
	return env{a: a, s: a.Login(t, user, pass)}
}

// payload returns n deterministic bytes and their hex sha256.
func payload(n int, seed byte) ([]byte, string) {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(i) ^ byte(i>>8) ^ seed
	}
	sum := sha256.Sum256(b)
	return b, hex.EncodeToString(sum[:])
}

func b64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

func metadata(sha string) string {
	return "sha256 " + b64(sha) + ",filename " + b64("IMG_0001.JPG") + ",mime " + b64("image/jpeg") + ",local_id " + b64("a-1")
}

// req builds an authenticated tus request (Tus-Resumable set).
func (e env) req(t *testing.T, method, path string, body []byte, hdr map[string]string) *http.Request {
	t.Helper()
	var r *http.Request
	if body == nil {
		r = e.a.Req(t, method, path, nil)
	} else {
		r = e.a.Req(t, method, path, body)
	}
	httpapitest.Bearer(r, e.s.Access)
	r.Header.Set("Tus-Resumable", tusVer)
	for k, v := range hdr {
		if v == "" {
			r.Header.Del(k)
			continue
		}
		r.Header.Set(k, v)
	}
	return r
}

func (e env) do(t *testing.T, method, path string, body []byte, hdr map[string]string) (*http.Response, []byte) {
	t.Helper()
	return e.a.Do(t, e.req(t, method, path, body, hdr))
}

// create posts a bodyless creation and returns the Location.
func (e env) create(t *testing.T, length int, sha string) string {
	t.Helper()
	resp, body := e.do(t, http.MethodPost, uploads, nil, map[string]string{
		"Upload-Length": strconv.Itoa(length), "Upload-Metadata": metadata(sha),
	})
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create: %d %s", resp.StatusCode, body)
	}
	return resp.Header.Get("Location")
}

func wantStatus(t *testing.T, resp *http.Response, body []byte, status int) {
	t.Helper()
	if resp.StatusCode != status {
		t.Fatalf("status %d, want %d: %s", resp.StatusCode, status, body)
	}
	if got := resp.Header.Get("Tus-Resumable"); got != tusVer {
		t.Errorf("Tus-Resumable = %q, want %q", got, tusVer)
	}
}

func wantProblem(t *testing.T, resp *http.Response, body []byte, status int, code string) {
	t.Helper()
	wantStatus(t, resp, body, status)
	var p struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(body, &p); err != nil || p.Code != code {
		t.Fatalf("code %q (err %v), want %q: %s", p.Code, err, code, body)
	}
}

func wantHeader(t *testing.T, resp *http.Response, name, want string) {
	t.Helper()
	if got := resp.Header.Get(name); got != want {
		t.Errorf("%s = %q, want %q", name, got, want)
	}
}

func wantNoHeader(t *testing.T, resp *http.Response, name string) {
	t.Helper()
	if v, ok := resp.Header[http.CanonicalHeaderKey(name)]; ok {
		t.Errorf("unexpected %s: %q", name, v)
	}
}

func expiresAt(d time.Duration) string {
	return httpapitest.T0.Add(d).UTC().Format(http.TimeFormat)
}

func TestOptions(t *testing.T) {
	e := newEnv(t)
	resp, body := e.do(t, http.MethodOptions, uploads, nil, map[string]string{"Tus-Resumable": ""})
	wantStatus(t, resp, body, http.StatusNoContent)
	wantHeader(t, resp, "Tus-Version", tusVer)
	wantHeader(t, resp, "Tus-Extension", extsWant)
	wantHeader(t, resp, "Tus-Max-Size", "53687091200")
	wantHeader(t, resp, "Tus-Checksum-Algorithm", "sha256")
}

func TestOptionsNoAuth(t *testing.T) {
	e := newEnv(t)
	resp, body := e.a.Do(t, e.a.Req(t, http.MethodOptions, uploads, nil))
	wantStatus(t, resp, body, http.StatusNoContent)
	wantHeader(t, resp, "Tus-Version", tusVer)
	wantHeader(t, resp, "Tus-Extension", extsWant)
	wantHeader(t, resp, "Tus-Max-Size", "53687091200")
	wantHeader(t, resp, "Tus-Checksum-Algorithm", "sha256")
}

func TestTusResumableRequired(t *testing.T) {
	e := newEnv(t)
	_, sha := payload(16, 1)
	loc := e.create(t, 16, sha)
	for _, c := range []struct{ method, path, version string }{
		{http.MethodPost, uploads, ""},
		{http.MethodPost, uploads, "0.2.2"},
		{http.MethodPatch, loc, ""},
		{http.MethodDelete, loc, ""},
	} {
		hdr := map[string]string{"Tus-Resumable": c.version, "Upload-Length": "16", "Upload-Metadata": metadata(sha)}
		if c.version == "" {
			hdr["Tus-Resumable"] = ""
		}
		resp, body := e.do(t, c.method, c.path, nil, hdr)
		wantProblem(t, resp, body, http.StatusPreconditionFailed, "invalid_request")
		wantHeader(t, resp, "Tus-Version", tusVer)
	}
	// HEAD carries no body; status and headers still apply.
	resp, body := e.do(t, http.MethodHead, loc, nil, map[string]string{"Tus-Resumable": ""})
	wantStatus(t, resp, body, http.StatusPreconditionFailed)
	wantHeader(t, resp, "Tus-Version", tusVer)
}

func TestCreateBodyless(t *testing.T) {
	e := newEnv(t)
	_, sha := payload(1048576, 2)
	resp, body := e.do(t, http.MethodPost, uploads, nil, map[string]string{
		"Upload-Length": "1048576", "Upload-Metadata": metadata(sha),
	})
	wantStatus(t, resp, body, http.StatusCreated)
	loc := resp.Header.Get("Location")
	if !strings.HasPrefix(loc, uploads+"/") || len(loc) != len(uploads)+1+36 {
		t.Errorf("Location = %q", loc)
	}
	wantHeader(t, resp, "Upload-Expires", expiresAt(24*time.Hour))
	wantHeader(t, resp, "Upload-Offset", "0") // always reported (P§7.3 row 4 needs it for a joined session at 0)
	wantNoHeader(t, resp, "PicTunnel-Asset-Id")
	wantNoHeader(t, resp, "PicTunnel-Asset-Created")

	// Outcome #4: the same content resumes that session.
	resp, body = e.do(t, http.MethodPost, uploads, nil, map[string]string{
		"Upload-Length": "1048576", "Upload-Metadata": metadata(sha),
	})
	wantStatus(t, resp, body, http.StatusCreated)
	wantHeader(t, resp, "Location", loc)
}

func TestCreateWithUpload(t *testing.T) {
	e := newEnv(t)
	data, sha := payload(1048576, 3)
	resp, body := e.do(t, http.MethodPost, uploads, data, map[string]string{
		"Upload-Length": "1048576", "Upload-Metadata": metadata(sha), "Content-Type": octet,
	})
	wantStatus(t, resp, body, http.StatusCreated)
	loc := resp.Header.Get("Location")
	if !strings.HasPrefix(loc, uploads+"/") {
		t.Errorf("Location = %q", loc)
	}
	wantHeader(t, resp, "Upload-Offset", "1048576")
	wantHeader(t, resp, "PicTunnel-Asset-Created", "true")
	asset := resp.Header.Get("PicTunnel-Asset-Id")
	if len(asset) != 36 {
		t.Fatalf("PicTunnel-Asset-Id = %q", asset)
	}

	// Outcome #3: existing content resolves without bytes.
	resp, body = e.do(t, http.MethodPost, uploads, data, map[string]string{
		"Upload-Length": "1048576", "Upload-Metadata": metadata(sha), "Content-Type": octet,
	})
	wantStatus(t, resp, body, http.StatusCreated)
	wantHeader(t, resp, "Upload-Offset", "1048576")
	wantHeader(t, resp, "PicTunnel-Asset-Id", asset)
	wantHeader(t, resp, "PicTunnel-Asset-Created", "false")
	loc3 := resp.Header.Get("Location")

	// HEAD on that Location works and names the asset.
	resp, body = e.do(t, http.MethodHead, loc3, nil, nil)
	wantStatus(t, resp, body, http.StatusOK)
	wantHeader(t, resp, "Upload-Offset", "1048576")
	wantHeader(t, resp, "Upload-Length", "1048576")
	wantHeader(t, resp, "PicTunnel-Asset-Id", asset)
	wantHeader(t, resp, "Cache-Control", "no-store")
}

func TestCreatePartialBody(t *testing.T) {
	e := newEnv(t)
	data, sha := payload(4096, 4)
	resp, body := e.do(t, http.MethodPost, uploads, data[:1000], map[string]string{
		"Upload-Length": "4096", "Upload-Metadata": metadata(sha), "Content-Type": octet,
	})
	wantStatus(t, resp, body, http.StatusCreated)
	wantHeader(t, resp, "Upload-Offset", "1000")
	wantHeader(t, resp, "Upload-Expires", expiresAt(24*time.Hour))
	wantNoHeader(t, resp, "PicTunnel-Asset-Id")
}

func TestCreateInvalid(t *testing.T) {
	e := newEnv(t)
	data, sha := payload(64, 5)
	for name, c := range map[string]struct {
		body []byte
		hdr  map[string]string
	}{
		"no length":         {nil, map[string]string{"Upload-Metadata": metadata(sha)}},
		"bad length":        {nil, map[string]string{"Upload-Length": "-1", "Upload-Metadata": metadata(sha)}},
		"text length":       {nil, map[string]string{"Upload-Length": "ten", "Upload-Metadata": metadata(sha)}},
		"defer length":      {nil, map[string]string{"Upload-Defer-Length": "1", "Upload-Metadata": metadata(sha)}},
		"no metadata":       {nil, map[string]string{"Upload-Length": "64"}},
		"bad metadata":      {nil, map[string]string{"Upload-Length": "64", "Upload-Metadata": "sha256 !!!"}},
		"wrong type":        {data, map[string]string{"Upload-Length": "64", "Upload-Metadata": metadata(sha), "Content-Type": "text/plain"}},
		"body without type": {data, map[string]string{"Upload-Length": "64", "Upload-Metadata": metadata(sha), "Content-Type": ""}},
		"body too long":     {append(data, 0), map[string]string{"Upload-Length": "64", "Upload-Metadata": metadata(sha), "Content-Type": octet}},
		"checksum algo":     {data, map[string]string{"Upload-Length": "64", "Upload-Metadata": metadata(sha), "Content-Type": octet, "Upload-Checksum": "md5 " + b64("x")}},
		"checksum value":    {data, map[string]string{"Upload-Length": "64", "Upload-Metadata": metadata(sha), "Content-Type": octet, "Upload-Checksum": "sha256 !!"}},
	} {
		t.Run(name, func(t *testing.T) {
			resp, body := e.do(t, http.MethodPost, uploads, c.body, c.hdr)
			wantProblem(t, resp, body, http.StatusBadRequest, "invalid_request")
		})
	}
	// Nothing was created by the rejected requests.
	resp, body := e.do(t, http.MethodPost, uploads, nil, map[string]string{"Upload-Length": "64", "Upload-Metadata": metadata(sha)})
	wantStatus(t, resp, body, http.StatusCreated)
	wantHeader(t, resp, "Upload-Offset", "0") // always reported (P§7.3 row 4 needs it for a joined session at 0)
}

func TestCreateFileTooLarge(t *testing.T) {
	e := newEnv(t)
	_, sha := payload(8, 6)
	resp, body := e.do(t, http.MethodPost, uploads, nil, map[string]string{
		"Upload-Length": "53687091201", "Upload-Metadata": metadata(sha),
	})
	wantProblem(t, resp, body, http.StatusRequestEntityTooLarge, "file_too_large")
}

func TestHead(t *testing.T) {
	e := newEnv(t)
	data, sha := payload(2048, 7)
	loc := e.create(t, 2048, sha)

	resp, body := e.do(t, http.MethodHead, loc, nil, nil)
	wantStatus(t, resp, body, http.StatusOK)
	wantHeader(t, resp, "Upload-Offset", "0")
	wantHeader(t, resp, "Upload-Length", "2048")
	wantHeader(t, resp, "Upload-Expires", expiresAt(24*time.Hour))
	wantHeader(t, resp, "Cache-Control", "no-store")
	wantNoHeader(t, resp, "PicTunnel-Asset-Id")

	e.a.Clock.Advance(10 * time.Minute)
	resp, body = e.do(t, http.MethodPatch, loc, data[:512], map[string]string{"Upload-Offset": "0", "Content-Type": octet})
	wantStatus(t, resp, body, http.StatusNoContent)
	resp, body = e.do(t, http.MethodHead, loc, nil, nil)
	wantStatus(t, resp, body, http.StatusOK)
	wantHeader(t, resp, "Upload-Offset", "512")
	wantHeader(t, resp, "Upload-Expires", expiresAt(24*time.Hour+10*time.Minute))

	resp, body = e.do(t, http.MethodHead, uploads+"/01928f40-1111-7aaa-8bbb-0123456789ab", nil, nil)
	wantStatus(t, resp, body, http.StatusNotFound)
}

func TestPatch(t *testing.T) {
	e := newEnv(t)
	data, sha := payload(1048576, 8)
	loc := e.create(t, len(data), sha)

	resp, body := e.do(t, http.MethodPatch, loc, data[:524288], map[string]string{"Upload-Offset": "0", "Content-Type": octet})
	wantStatus(t, resp, body, http.StatusNoContent)
	wantHeader(t, resp, "Upload-Offset", "524288")
	wantHeader(t, resp, "Upload-Expires", expiresAt(24*time.Hour))
	wantNoHeader(t, resp, "PicTunnel-Asset-Id")

	// Wrong offset: 409 with the server's offset.
	resp, body = e.do(t, http.MethodPatch, loc, data[:10], map[string]string{"Upload-Offset": "10", "Content-Type": octet})
	wantProblem(t, resp, body, http.StatusConflict, "offset_mismatch")
	wantHeader(t, resp, "Upload-Offset", "524288")

	resp, body = e.do(t, http.MethodPatch, loc, data[524288:], map[string]string{"Upload-Offset": "524288", "Content-Type": octet})
	wantStatus(t, resp, body, http.StatusNoContent)
	wantHeader(t, resp, "Upload-Offset", "1048576")
	wantHeader(t, resp, "PicTunnel-Asset-Created", "true")
	if id := resp.Header.Get("PicTunnel-Asset-Id"); len(id) != 36 {
		t.Errorf("PicTunnel-Asset-Id = %q", id)
	}
}

func TestPatchInvalid(t *testing.T) {
	e := newEnv(t)
	data, sha := payload(100, 9)
	loc := e.create(t, len(data), sha)
	for name, hdr := range map[string]map[string]string{
		"wrong type":    {"Upload-Offset": "0", "Content-Type": "application/octet-stream"},
		"no type":       {"Upload-Offset": "0", "Content-Type": ""},
		"no offset":     {"Content-Type": octet},
		"bad offset":    {"Upload-Offset": "-3", "Content-Type": octet},
		"checksum algo": {"Upload-Offset": "0", "Content-Type": octet, "Upload-Checksum": "crc32 AAAA"},
	} {
		t.Run(name, func(t *testing.T) {
			resp, body := e.do(t, http.MethodPatch, loc, data[:10], hdr)
			wantProblem(t, resp, body, http.StatusBadRequest, "invalid_request")
		})
	}
	// A body longer than the remaining length is rejected before reading.
	resp, body := e.do(t, http.MethodPatch, loc, append(append([]byte{}, data...), 1), map[string]string{"Upload-Offset": "0", "Content-Type": octet})
	wantProblem(t, resp, body, http.StatusBadRequest, "invalid_request")
	resp, body = e.do(t, http.MethodHead, loc, nil, nil)
	wantStatus(t, resp, body, http.StatusOK)
	wantHeader(t, resp, "Upload-Offset", "0")

	resp, body = e.do(t, http.MethodPatch, uploads+"/01928f40-1111-7aaa-8bbb-0123456789ab", data, map[string]string{"Upload-Offset": "0", "Content-Type": octet})
	wantProblem(t, resp, body, http.StatusNotFound, "not_found")
}

// A chunked body (unknown length) keeps the bytes up to Upload-Length and
// then reports the excess.
func TestPatchChunkedExcess(t *testing.T) {
	e := newEnv(t)
	data, sha := payload(300, 10)
	loc := e.create(t, len(data), sha)
	req := e.req(t, http.MethodPatch, loc, nil, map[string]string{"Upload-Offset": "0", "Content-Type": octet})
	req.Body = io.NopCloser(io.MultiReader(bytes.NewReader(data[:100]), bytes.NewReader(data[100:]), strings.NewReader("extra")))
	req.ContentLength = -1
	resp, body := e.a.Do(t, req)
	wantProblem(t, resp, body, http.StatusBadRequest, "invalid_request")
	resp, body = e.do(t, http.MethodHead, loc, nil, nil)
	wantStatus(t, resp, body, http.StatusOK)
	wantHeader(t, resp, "Upload-Offset", "300")
}

func TestPatchChunkedExact(t *testing.T) {
	e := newEnv(t)
	data, sha := payload(300, 11)
	loc := e.create(t, len(data), sha)
	req := e.req(t, http.MethodPatch, loc, nil, map[string]string{"Upload-Offset": "0", "Content-Type": octet})
	req.Body = io.NopCloser(bytes.NewReader(data[:200]))
	req.ContentLength = -1
	resp, body := e.a.Do(t, req)
	wantStatus(t, resp, body, http.StatusNoContent)
	wantHeader(t, resp, "Upload-Offset", "200")
}

func TestUploadChecksumHeader(t *testing.T) {
	e := newEnv(t)
	data, sha := payload(1000, 12)
	loc := e.create(t, len(data), sha)

	wrong := sha256.Sum256([]byte("not the body"))
	resp, body := e.do(t, http.MethodPatch, loc, data[:400], map[string]string{
		"Upload-Offset": "0", "Content-Type": octet,
		"Upload-Checksum": "sha256 " + base64.StdEncoding.EncodeToString(wrong[:]),
	})
	wantProblem(t, resp, body, 460, "checksum_mismatch")
	resp, body = e.do(t, http.MethodHead, loc, nil, nil)
	wantStatus(t, resp, body, http.StatusOK)
	wantHeader(t, resp, "Upload-Offset", "0")

	right := sha256.Sum256(data[:400])
	resp, body = e.do(t, http.MethodPatch, loc, data[:400], map[string]string{
		"Upload-Offset": "0", "Content-Type": octet,
		"Upload-Checksum": "sha256 " + base64.StdEncoding.EncodeToString(right[:]),
	})
	wantStatus(t, resp, body, http.StatusNoContent)
	wantHeader(t, resp, "Upload-Offset", "400")
}

func TestDelete(t *testing.T) {
	e := newEnv(t)
	data, sha := payload(100, 13)
	loc := e.create(t, len(data), sha)
	resp, body := e.do(t, http.MethodDelete, loc, nil, nil)
	wantStatus(t, resp, body, http.StatusNoContent)
	resp, body = e.do(t, http.MethodHead, loc, nil, nil)
	wantStatus(t, resp, body, http.StatusNotFound)
	resp, body = e.do(t, http.MethodDelete, loc, nil, nil)
	wantProblem(t, resp, body, http.StatusNotFound, "not_found")
}

func TestUnknownMethod(t *testing.T) {
	e := newEnv(t)
	resp, body := e.do(t, http.MethodGet, uploads, nil, nil)
	wantProblem(t, resp, body, http.StatusNotFound, "not_found")
}

// rawPatch opens a TCP connection, sends PATCH headers declaring length
// bytes at offset and the first n of body, and returns the connection.
func rawPatch(t *testing.T, e env, loc string, offset, length int, body []byte) net.Conn {
	t.Helper()
	conn, err := net.Dial("tcp", e.a.Server.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	head := fmt.Sprintf("PATCH %s HTTP/1.1\r\nHost: %s\r\nAuthorization: Bearer %s\r\nTus-Resumable: 1.0.0\r\n"+
		"Upload-Offset: %d\r\nContent-Type: %s\r\nContent-Length: %d\r\n\r\n",
		loc, e.a.Server.Listener.Addr(), e.s.Access, offset, octet, length)
	if _, err := conn.Write([]byte(head)); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Write(body); err != nil {
		t.Fatal(err)
	}
	return conn
}

// waitOffset polls HEAD until the offset is want.
func waitOffset(t *testing.T, e env, loc string, want int) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		resp, body := e.do(t, http.MethodHead, loc, nil, nil)
		wantStatus(t, resp, body, http.StatusOK)
		if resp.Header.Get("Upload-Offset") == strconv.Itoa(want) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("Upload-Offset = %s, want %d", resp.Header.Get("Upload-Offset"), want)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestDropMidPatchRealConn(t *testing.T) {
	e := newEnv(t)
	data, sha := payload(1048576, 14)
	loc := e.create(t, len(data), sha)

	conn := rawPatch(t, e, loc, 0, len(data), data[:1000000])
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
	waitOffset(t, e, loc, 1000000)

	resp, body := e.do(t, http.MethodPatch, loc, data[1000000:], map[string]string{"Upload-Offset": "1000000", "Content-Type": octet})
	wantStatus(t, resp, body, http.StatusNoContent)
	wantHeader(t, resp, "Upload-Offset", "1048576")
	wantHeader(t, resp, "PicTunnel-Asset-Created", "true")
	if id := resp.Header.Get("PicTunnel-Asset-Id"); len(id) != 36 {
		t.Errorf("PicTunnel-Asset-Id = %q", id)
	}
}

// A client that stops sending mid-body is cut off after the idle timeout;
// it gets no response and the bytes it sent are kept.
func TestIdleBodyTimeout(t *testing.T) {
	defer tus.SetIdleTimeout(300 * time.Millisecond)()
	e := newEnv(t)
	data, sha := payload(4096, 15)
	loc := e.create(t, len(data), sha)

	conn := rawPatch(t, e, loc, 0, len(data), data[:1000])
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	got, err := io.ReadAll(bufio.NewReader(conn))
	if len(got) != 0 {
		t.Fatalf("got a response after the idle timeout: %q", got)
	}
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatalf("server did not close the idle connection: %v", err)
	}
	waitOffset(t, e, loc, 1000)
}
