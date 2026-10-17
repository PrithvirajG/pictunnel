package conformance_test

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/text/unicode/norm"

	"github.com/PrithvirajG/pictunnel/server/internal/app"
	"github.com/PrithvirajG/pictunnel/server/internal/clock/clocktest"
	"github.com/PrithvirajG/pictunnel/server/internal/config"
	"github.com/PrithvirajG/pictunnel/server/internal/conformance"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/httpapitest"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
)

// scenarioCount is the number of server-scenario cases the contract ships.
const scenarioCount = 17

var t0 = time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)

const userPassword = "conformance password"

func TestScenarios(t *testing.T) {
	cases, err := conformance.LoadScenarioCases(conformance.ProtocolDir())
	if err != nil {
		t.Fatal(err)
	}
	if len(cases) != scenarioCount {
		t.Fatalf("loaded %d server-scenario cases, want %d", len(cases), scenarioCount)
	}
	for _, c := range cases {
		t.Run(strings.TrimSuffix(c.File, ".json")+"/"+c.Name, func(t *testing.T) {
			t.Parallel()
			newRunner(t, c).run()
		})
	}
}

// actorState is a paired device and its credentials.
type actorState struct {
	name, user, platform  string
	deviceID              string
	access, refresh       string
	accessExp, refreshExp time.Time
}

type runner struct {
	t      *testing.T
	c      conformance.ScenarioCase
	a      *app.App
	clk    *clocktest.Fake
	srv    *httptest.Server
	client *http.Client
	tlsCfg *tls.Config
	vars   conformance.Vars
	actors map[string]*actorState

	connMu sync.Mutex
	closed map[string]chan struct{} // server-side remote addr → closed
}

func newRunner(t *testing.T, c conformance.ScenarioCase) *runner {
	t.Helper()
	root := t.TempDir()
	cfg := config.Default()
	cfg.DataDir = filepath.Join(root, "data")
	cfg.LibraryDir = filepath.Join(root, "data", "library")
	cfg.Server.Name = "Conformance"
	cfg.Discovery.MDNS = false
	cfg.Log.Format = "text"
	clk := clocktest.NewFake(t0)
	a, err := app.New(context.Background(), app.Options{
		Config: cfg, Clock: clk, DisableScheduler: true,
		Log:       slog.New(slog.NewTextHandler(io.Discard, nil)),
		FreeSpace: func(string) (uint64, error) { return 1 << 40, nil },
	})
	if err != nil {
		t.Fatal(err)
	}
	r := &runner{t: t, c: c, a: a, clk: clk, vars: conformance.Vars{}, actors: map[string]*actorState{},
		closed: map[string]chan struct{}{}}
	r.srv = httptest.NewUnstartedServer(a.Handler())
	r.srv.TLS = a.TLSConfig()
	r.srv.Config.ConnState = func(conn net.Conn, s http.ConnState) {
		if s == http.StateClosed || s == http.StateHijacked {
			r.connClosed(conn.RemoteAddr().String())
		}
	}
	r.srv.StartTLS()
	t.Cleanup(func() {
		r.srv.Close()
		_ = a.Close()
	})
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(a.CACertPEM()) {
		t.Fatal("app CA PEM unusable")
	}
	r.tlsCfg = &tls.Config{RootCAs: pool, NextProtos: []string{"http/1.1"}}
	r.client = &http.Client{
		Transport:     &http.Transport{TLSClientConfig: r.tlsCfg, DisableCompression: true},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		Timeout:       2 * time.Minute,
	}
	return r
}

func (r *runner) closedCh(addr string) chan struct{} {
	r.connMu.Lock()
	defer r.connMu.Unlock()
	ch, ok := r.closed[addr]
	if !ok {
		ch = make(chan struct{})
		r.closed[addr] = ch
	}
	return ch
}

func (r *runner) connClosed(addr string) {
	ch := r.closedCh(addr)
	r.connMu.Lock()
	defer r.connMu.Unlock()
	select {
	case <-ch:
	default:
		close(ch)
	}
}

func (r *runner) run() {
	t := r.t
	ctx := context.Background()
	var names []string
	for n := range r.c.Actors {
		names = append(names, n)
	}
	sort.Strings(names)
	created := map[string]bool{}
	for _, n := range names {
		ac := r.c.Actors[n]
		if !created[ac.User] {
			if _, err := r.a.Users().Create(ctx, ac.User, userPassword, "", service.RoleUser); err != nil {
				t.Fatalf("create user %s: %v", ac.User, err)
			}
			created[ac.User] = true
		}
		platform := ac.Platform
		if platform == "" {
			platform = "other"
		}
		st := &actorState{name: n, user: ac.User, platform: platform}
		r.pair(st)
		r.actors[n] = st
	}
	for i, s := range r.c.Steps {
		label := fmt.Sprintf("step %d", i)
		if s.Request != nil {
			label += " " + s.Actor + " " + s.Request.Method + " " + s.Request.Path
		}
		if s.Control != nil {
			r.control(label, s.Control)
			continue
		}
		r.httpStep(label, s)
		if t.Failed() {
			t.FailNow()
		}
	}
	r.checkInvariants()
}

// ---- auth -------------------------------------------------------------

type tokenPair struct {
	AccessToken           string    `json:"access_token"`
	AccessTokenExpiresAt  time.Time `json:"access_token_expires_at"`
	RefreshToken          string    `json:"refresh_token"`
	RefreshTokenExpiresAt time.Time `json:"refresh_token_expires_at"`
}

// api sends a JSON request outside the vector steps and decodes the
// response, failing on an unexpected status.
func (r *runner) api(method, path, bearer string, in any, wantStatus int, out any) {
	r.t.Helper()
	var body io.Reader
	if in != nil {
		b, _ := json.Marshal(in)
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, r.srv.URL+path, body)
	if err != nil {
		r.t.Fatal(err)
	}
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, raw := r.do(req)
	if resp.StatusCode != wantStatus {
		r.t.Fatalf("%s %s: status %d, want %d: %s", method, path, resp.StatusCode, wantStatus, raw)
	}
	if out != nil {
		if err := json.Unmarshal(raw, out); err != nil {
			r.t.Fatalf("%s %s: decode: %v", method, path, err)
		}
	}
}

// pair logs the runner in as the actor's user (tokens mode) and pairs a
// device with the actor's platform through createPairingCode and
// redeemPairingCode; the generated qr_uri must parse under P§10.3.
func (r *runner) pair(st *actorState) {
	r.t.Helper()
	var login struct {
		Tokens tokenPair `json:"tokens"`
	}
	r.api("POST", "/api/v1/auth/login", "", map[string]any{
		"username": st.user, "password": userPassword, "mode": "tokens",
		"device": map[string]string{"device_name": "conformance runner", "platform": "other", "app_version": "0.1.0"},
	}, 200, &login)
	var code struct {
		Code  string `json:"code"`
		QrURI string `json:"qr_uri"`
	}
	r.api("POST", "/api/v1/pairing/codes", login.Tokens.AccessToken, nil, 201, &code)
	pu, err := conformance.ParsePairURI(code.QrURI)
	if err != nil {
		r.t.Fatalf("qr_uri %q rejected: %v", code.QrURI, err)
	}
	if pu.ServerID != r.a.ServerID() || pu.Fingerprint != r.a.Fingerprint() || pu.Code != code.Code || len(pu.Endpoints) == 0 {
		r.t.Fatalf("qr_uri %q: parsed %+v", code.QrURI, pu)
	}
	var redeem struct {
		Device struct {
			ID string `json:"id"`
		} `json:"device"`
		Tokens tokenPair `json:"tokens"`
	}
	r.api("POST", "/api/v1/pairing/redeem", "", map[string]any{
		"code":   code.Code,
		"device": map[string]string{"device_name": st.name, "platform": st.platform, "app_version": "0.1.0"},
	}, 201, &redeem)
	st.deviceID = redeem.Device.ID
	st.setTokens(redeem.Tokens)
}

func (st *actorState) setTokens(tp tokenPair) {
	st.access, st.refresh = tp.AccessToken, tp.RefreshToken
	st.accessExp, st.refreshExp = tp.AccessTokenExpiresAt, tp.RefreshTokenExpiresAt
}

// token returns a current access token for the actor. When the test clock
// has moved past the access token's expiry it refreshes; past the refresh
// expiry the actor is paired again (a new device). Neither happens unless
// a step advances the clock.
func (r *runner) token(st *actorState) string {
	now := r.clk.Now()
	if now.Before(st.accessExp) {
		return st.access
	}
	if now.Before(st.refreshExp) {
		var tp tokenPair
		r.api("POST", "/api/v1/auth/refresh", "", map[string]string{"refresh_token": st.refresh}, 200, &tp)
		st.setTokens(tp)
		return st.access
	}
	r.pair(st)
	return st.access
}

// ---- HTTP steps ---------------------------------------------------------

// do sends req, reads the body and validates the response against the
// OpenAPI contract (and problem bodies against the catalogue).
func (r *runner) do(req *http.Request) (*http.Response, []byte) {
	r.t.Helper()
	resp, err := r.client.Do(req)
	if err != nil {
		r.t.Fatalf("%s %s: %v", req.Method, req.URL.Path, err)
	}
	raw, err := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if err != nil {
		r.t.Fatal(err)
	}
	resp.Body = io.NopCloser(bytes.NewReader(raw))
	httpapitest.AssertContract(r.t, req, resp)
	resp.Body = io.NopCloser(bytes.NewReader(raw))
	return resp, raw
}

func (r *runner) must(label string, err error) {
	r.t.Helper()
	if err != nil {
		r.t.Fatalf("%s: %v", label, err)
	}
}

func (r *runner) httpStep(label string, s conformance.Step) {
	t := r.t
	t.Helper()
	if s.Request == nil || s.Expect == nil {
		t.Fatalf("%s: an HTTP step needs request and expect", label)
	}
	st, ok := r.actors[s.Actor]
	if !ok {
		t.Fatalf("%s: unknown actor %q", label, s.Actor)
	}
	rq := s.Request
	path, err := r.vars.Subst(rq.Path)
	r.must(label, err)
	headers := http.Header{}
	auth := true
	for k, v := range rq.Headers {
		if strings.EqualFold(k, "Authorization") && v == "" {
			auth = false
			continue
		}
		v, err := r.vars.Subst(v)
		r.must(label, err)
		headers.Set(k, v)
	}
	if auth && headers.Get("Authorization") == "" {
		headers.Set("Authorization", "Bearer "+r.token(st))
	}
	if rq.TusMetadata != nil {
		md, err := conformance.TusMetadata(rq.TusMetadata, r.vars)
		r.must(label, err)
		headers.Set("Upload-Metadata", md)
	}
	var body io.Reader
	var length int64
	switch {
	case len(rq.JSON) > 0:
		b, err := r.vars.SubstJSON(rq.JSON)
		r.must(label, err)
		body, length = bytes.NewReader(b), int64(len(b))
		if headers.Get("Content-Type") == "" {
			headers.Set("Content-Type", "application/json")
		}
	case rq.Body != nil:
		g := rq.Body.Generate
		start, err := r.vars.Offset(g.Start, 0)
		r.must(label, err)
		end, err := r.vars.Offset(g.End, g.Length)
		r.must(label, err)
		if start < 0 || end > g.Length || start > end {
			t.Fatalf("%s: bad generate range [%d,%d) of %d", label, start, end, g.Length)
		}
		body = conformance.CounterReader(conformance.Generate{Pattern: g.Pattern, Seed: g.Seed, Length: g.Length}, start, end)
		length = end - start
	}

	if s.Transport != nil {
		if s.Expect == nil || !s.Expect.NoResponse {
			t.Fatalf("%s: drop_after_bytes without no_response", label)
		}
		r.dropAfter(label, rq.Method, path, headers, body, length, s.Transport.DropAfterBytes)
		return
	}

	req, err := http.NewRequest(rq.Method, r.srv.URL+path, body)
	r.must(label, err)
	req.Header = headers
	if body != nil {
		req.ContentLength = length
	}
	resp, raw := r.do(req)

	exp := s.Expect
	if exp.NoResponse {
		t.Fatalf("%s: expected no response, got %d", label, resp.StatusCode)
	}
	if resp.StatusCode != exp.Status {
		t.Fatalf("%s: status %d, want %d\nbody: %s", label, resp.StatusCode, exp.Status, raw)
	}
	for name, want := range exp.Headers {
		got := resp.Header.Values(name)
		if len(got) == 0 {
			t.Errorf("%s: header %s missing (want %s)", label, name, want)
			continue
		}
		g := got[0]
		if strings.EqualFold(name, "Location") {
			g = conformance.NormalizeLocation(g)
		}
		if err := conformance.MatchString(want, g, r.vars); err != nil {
			t.Errorf("%s: header %s: %v", label, name, err)
		}
	}
	var doc any
	decoded := false
	decode := func() any {
		if !decoded {
			if err := json.Unmarshal(raw, &doc); err != nil {
				t.Fatalf("%s: response body is not JSON: %v: %s", label, err, raw)
			}
			decoded = true
		}
		return doc
	}
	if len(exp.Body) > 0 {
		var want any
		if err := json.Unmarshal(exp.Body, &want); err != nil {
			t.Fatalf("%s: bad expect.body: %v", label, err)
		}
		if err := conformance.MatchJSON(want, decode(), r.vars); err != nil {
			t.Errorf("%s: body: %v\nbody: %s", label, err, raw)
		}
	}
	for name, src := range s.Save {
		switch {
		case strings.HasPrefix(src, "header:"):
			h := strings.TrimPrefix(src, "header:")
			v := resp.Header.Get(h)
			if v == "" {
				t.Fatalf("%s: save %s: header %s missing", label, name, h)
			}
			if strings.EqualFold(h, "Location") {
				v = conformance.NormalizeLocation(v)
			}
			r.vars[name] = v
		case strings.HasPrefix(src, "body:"):
			v, err := conformance.JSONPointer(decode(), strings.TrimPrefix(src, "body:"))
			r.must(label+": save "+name, err)
			r.vars[name] = v
		default:
			t.Fatalf("%s: bad save source %q", label, src)
		}
	}
}

// dropAfter sends the request line, headers (with the full Content-Length)
// and the first n body bytes over a raw TLS connection, then closes it
// without reading a response. It waits until the server has closed its
// side, so the interrupted request has been fully handled (and its offset
// committed) before the next step.
func (r *runner) dropAfter(label, method, path string, h http.Header, body io.Reader, length, n int64) {
	t := r.t
	addr := r.srv.Listener.Addr().String()
	conn, err := tls.Dial("tcp", addr, r.tlsCfg)
	r.must(label, err)
	closed := r.closedCh(conn.LocalAddr().String())
	w := bufio.NewWriter(conn)
	fmt.Fprintf(w, "%s %s HTTP/1.1\r\nHost: %s\r\n", method, path, addr)
	if body != nil {
		h.Set("Content-Length", strconv.FormatInt(length, 10))
	}
	r.must(label, h.Write(w))
	_, _ = w.WriteString("\r\n")
	if body != nil {
		if _, err := io.CopyN(w, body, n); err != nil {
			t.Fatalf("%s: write %d body bytes: %v", label, n, err)
		}
	}
	r.must(label, w.Flush())
	_ = conn.Close()
	select {
	case <-closed:
	case <-time.After(30 * time.Second):
		t.Fatalf("%s: server did not finish the dropped request", label)
	}
}

// ---- control steps ----------------------------------------------------

func (r *runner) control(label string, c *conformance.Control) {
	t := r.t
	ctx := context.Background()
	switch {
	case c.AdvanceClockSeconds > 0:
		r.clk.Advance(time.Duration(c.AdvanceClockSeconds) * time.Second)
	case c.RunJob != "":
		if err := r.a.Jobs().RunNow(ctx, c.RunJob); err != nil {
			t.Fatalf("%s: run_job %s: %v", label, c.RunJob, err)
		}
	case c.AssertLibraryPaths != nil:
		want := append([]string(nil), c.AssertLibraryPaths.Paths...)
		for i := range want {
			want[i] = norm.NFC.String(want[i])
		}
		got := r.libraryFiles(filepath.Join(r.a.Config().LibraryDir, c.AssertLibraryPaths.User))
		sort.Strings(want)
		if strings.Join(got, "\n") != strings.Join(want, "\n") {
			t.Fatalf("%s: library paths\n got %q\nwant %q", label, got, want)
		}
	case c.AssertAssetSources != nil:
		asset, err := r.vars.Subst(c.AssertAssetSources.Asset)
		r.must(label, err)
		var want []string
		for _, s := range c.AssertAssetSources.Sources {
			st, ok := r.actors[s.Actor]
			if !ok {
				t.Fatalf("%s: unknown actor %q", label, s.Actor)
			}
			want = append(want, st.deviceID+"|"+s.LocalID)
		}
		rows, err := repository.AssetSourcesRepository{}.ListByAsset(ctx, r.a.Store().R, asset)
		r.must(label, err)
		var got []string
		for _, s := range rows {
			got = append(got, s.DeviceID+"|"+s.LocalID)
		}
		sort.Strings(want)
		sort.Strings(got)
		if strings.Join(got, ",") != strings.Join(want, ",") {
			t.Fatalf("%s: asset sources\n got %v\nwant %v", label, got, want)
		}
	default:
		t.Fatalf("%s: empty control step", label)
	}
}

// libraryFiles lists the files under dir as NFC paths relative to the
// library root with '/' separators, sorted.
func (r *runner) libraryFiles(dir string) []string {
	root := r.a.Config().LibraryDir
	out := []string{}
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if os.IsNotExist(err) && p == dir {
				return filepath.SkipDir
			}
			return err
		}
		if d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return err
		}
		out = append(out, norm.NFC.String(filepath.ToSlash(rel)))
		return nil
	})
	if err != nil {
		r.t.Fatal(err)
	}
	sort.Strings(out)
	return out
}

// ---- invariants (S§11.2) ------------------------------------------------

func (r *runner) checkInvariants() {
	t := r.t
	t.Helper()
	cfg := r.a.Config()
	db := r.a.Store().R

	r.checkNoTempFiles("")
	// A library file of the recorded size for each asset and live video.
	for _, q := range []string{
		`SELECT id, original_path, size_bytes FROM assets`,
		`SELECT asset_id, original_path, size_bytes FROM live_videos`,
	} {
		rows, err := db.Query(q)
		if err != nil {
			t.Fatal(err)
		}
		for rows.Next() {
			var id, rel string
			var size int64
			if err := rows.Scan(&id, &rel, &size); err != nil {
				t.Fatal(err)
			}
			fi, err := os.Stat(filepath.Join(cfg.LibraryDir, filepath.FromSlash(rel)))
			if err != nil || fi.Size() != size {
				t.Errorf("invariant: %s %s: file %v size %v, want %d", id, rel, err, sizeOf(fi), size)
			}
		}
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}
		_ = rows.Close()
	}
	r.checkNoFinalizing()
	r.checkReservations()
	// Staging files belong only to receiving sessions…
	live := map[string]bool{}
	rows, err := db.Query(`SELECT id FROM upload_sessions WHERE state = 'receiving'`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			t.Fatal(err)
		}
		live[id+".part"] = true
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	_ = rows.Close()
	for _, f := range r.stagingFiles() {
		if !live[f] {
			t.Errorf("invariant: staging file %s has no receiving session", f)
		}
	}
	// …and once every session has expired nothing is left in uploads/.
	r.clk.Advance(25 * time.Hour)
	if err := r.a.Jobs().RunNow(context.Background(), app.JobExpireUploads); err != nil {
		t.Fatalf("expire_uploads: %v", err)
	}
	if left := r.stagingFiles(); len(left) != 0 {
		t.Errorf("invariant: uploads/ not empty after expiry: %v", left)
	}
	r.checkNoTempFiles(" after expiry")
	r.checkNoFinalizing()
	r.checkReservations()
}

// checkNoTempFiles: no *.ptpart anywhere under the library or data dir,
// and the library temp dir (.pictunnel-tmp) holds nothing.
func (r *runner) checkNoTempFiles(when string) {
	t := r.t
	t.Helper()
	cfg := r.a.Config()
	for _, root := range []string{cfg.LibraryDir, cfg.DataDir} {
		err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if !d.IsDir() && strings.HasSuffix(p, ".ptpart") {
				t.Errorf("invariant%s: stray %s", when, p)
			}
			return nil
		})
		if err != nil {
			t.Fatalf("walk %s: %v", root, err)
		}
	}
	entries, err := os.ReadDir(filepath.Join(cfg.LibraryDir, ".pictunnel-tmp"))
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	for _, e := range entries {
		t.Errorf("invariant%s: library temp dir holds %s", when, e.Name())
	}
}

func sizeOf(fi os.FileInfo) any {
	if fi == nil {
		return nil
	}
	return fi.Size()
}

func (r *runner) stagingFiles() []string {
	var out []string
	entries, err := os.ReadDir(filepath.Join(r.a.Config().DataDir, "uploads"))
	if err != nil && !os.IsNotExist(err) {
		r.t.Fatal(err)
	}
	for _, e := range entries {
		if !e.IsDir() {
			out = append(out, e.Name())
		}
	}
	return out
}

func (r *runner) checkNoFinalizing() {
	var n int
	if err := r.a.Store().R.QueryRow(`SELECT COUNT(*) FROM upload_sessions WHERE state = 'finalizing'`).Scan(&n); err != nil {
		r.t.Fatal(err)
	}
	if n != 0 {
		r.t.Errorf("invariant: %d sessions left finalizing", n)
	}
}

// checkReservations: every library path reservation is owned by an
// existing asset or by an upload session that is still receiving or
// finalizing.
func (r *runner) checkReservations() {
	rows, err := r.a.Store().R.Query(`
		SELECT lp.path, lp.asset_id, lp.upload_id,
		       (SELECT COUNT(*) FROM assets a WHERE a.id = lp.asset_id),
		       (SELECT COUNT(*) FROM upload_sessions s WHERE s.id = lp.upload_id AND s.state IN ('receiving', 'finalizing'))
		FROM library_paths lp`)
	if err != nil {
		r.t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var path string
		var assetID, uploadID *string
		var assets, sessions int
		if err := rows.Scan(&path, &assetID, &uploadID, &assets, &sessions); err != nil {
			r.t.Fatal(err)
		}
		if assets == 0 && sessions == 0 {
			r.t.Errorf("invariant: reservation %q has no owner (asset %v, upload %v)", path, deref(assetID), deref(uploadID))
		}
	}
	if err := rows.Err(); err != nil {
		r.t.Fatal(err)
	}
}

func deref(s *string) string {
	if s == nil {
		return "<nil>"
	}
	return *s
}

func TestMatchers(t *testing.T) {
	v := conformance.Vars{"asset": "01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f", "n": "5"}
	dec := func(s string) any {
		var x any
		if err := json.Unmarshal([]byte(s), &x); err != nil {
			t.Fatal(err)
		}
		return x
	}
	for _, c := range []struct {
		want, got string
		ok        bool
	}{
		{`"$any"`, `"x"`, true},
		{`"$any"`, `3`, true},
		{`"$uuid"`, `"01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f"`, true},
		{`"$uuid"`, `"nope"`, false},
		{`"$int"`, `"42"`, true},
		{`"$int"`, `42`, true},
		{`"$int"`, `4.5`, false},
		{`"$int"`, `"4x"`, false},
		{`"$sha256"`, `"fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83"`, true},
		{`"$sha256"`, `"FBBAB289F7F94B25736C58BE46A994C441FD02552CC6022352E3D86D2FAB7C83"`, false},
		{`"$datetime"`, `"2026-10-03T12:00:00.123Z"`, true},
		{`"$datetime"`, `"2026-10-03"`, false},
		{`"${asset}"`, `"01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f"`, true},
		{`"${asset}"`, `"other"`, false},
		{`"/a/${n}"`, `"/a/5"`, true},
		{`{"a":1}`, `{"a":1,"b":2}`, true},
		{`{"a":1,"c":3}`, `{"a":1,"b":2}`, false},
		{`[{"k":1},{"k":3}]`, `[{"k":1},{"k":2},{"k":3}]`, true},
		{`[{"k":3},{"k":1}]`, `[{"k":1},{"k":2},{"k":3}]`, false},
		{`{"$len":0}`, `[]`, true},
		{`{"$len":2}`, `[1]`, false},
		{`true`, `false`, false},
		{`null`, `null`, true},
		{`1048576`, `1048576`, true},
		{`1048576`, `"1048576"`, false},
		// $len: exact count, arrays only.
		{`{"$len":1}`, `[1,2]`, false},
		{`{"$len":0}`, `{}`, false},
		{`{"$len":0}`, `null`, false},
		// Shape mismatches.
		{`{"a":1}`, `[1]`, false},
		{`[1]`, `{"a":1}`, false},
		{`{"a":{"b":1}}`, `{"a":{"c":1}}`, false},
		{`{"a":{"b":1}}`, `{"a":{"b":1,"c":2}}`, true},
		{`[{"k":{"x":1}}]`, `[{"k":{"y":1}}]`, false},
		// $datetime is RFC 3339: any offset is fine, a missing offset is not.
		{`"$datetime"`, `"2026-10-03T17:30:00+05:30"`, true},
		{`"$datetime"`, `"2026-10-03T12:00:00-07:00"`, true},
		{`"$datetime"`, `"2026-10-03T12:00:00"`, false},
		{`"$datetime"`, `"2026-10-03 12:00:00Z"`, false},
		{`"$datetime"`, `1696334400`, false},
		// ${name} against a JSON number: saved values are decimal strings,
		// so the number's decimal form must equal the saved value.
		{`"${n}"`, `5`, true},
		{`"${n}"`, `6`, false},
		{`"${n}"`, `"5"`, true},
		{`"${missing}"`, `"x"`, false},
		{`"$uuid"`, `7`, false},
	} {
		err := conformance.MatchJSON(dec(c.want), dec(c.got), v)
		if (err == nil) != c.ok {
			t.Errorf("MatchJSON(%s, %s) = %v, want ok=%v", c.want, c.got, err, c.ok)
		}
	}
	if got := conformance.NormalizeLocation("https://127.0.0.1:8443/api/v1/uploads/x"); got != "/api/v1/uploads/x" {
		t.Errorf("NormalizeLocation = %q", got)
	}
	if got, err := conformance.JSONPointer(dec(`{"a":[{"b":12}],"c/d":"x"}`), "/a/0/b"); err != nil || got != "12" {
		t.Errorf("JSONPointer = %q %v", got, err)
	}
	if got, err := conformance.JSONPointer(dec(`{"c/d":"x"}`), "/c~1d"); err != nil || got != "x" {
		t.Errorf("JSONPointer escape = %q %v", got, err)
	}
	md, err := conformance.TusMetadata(&conformance.OrderedStrings{Keys: []string{"z", "a"}, Values: map[string]string{"z": "1", "a": "${n}"}}, v)
	if err != nil || md != "z MQ==,a NQ==" {
		t.Errorf("TusMetadata = %q %v", md, err)
	}
}

func TestLoadScenarioCasesRejectsMalformedSteps(t *testing.T) {
	const okStep = `{"actor":"a","request":{"method":"GET","path":"/x"},"expect":{"status":200}}`
	for name, steps := range map[string]string{
		"misspelled expect":  `[{"actor":"a","request":{"method":"GET","path":"/x"},"expectt":{"status":200}}]`,
		"no expect":          `[{"actor":"a","request":{"method":"GET","path":"/x"}}]`,
		"misspelled request": `[{"actor":"a","request":{"method":"GET","pth":"/x"},"expect":{"status":200}}]`,
		"misspelled header":  `[{"actor":"a","request":{"method":"GET","path":"/x"},"expect":{"status":200,"header":{"A":"b"}}}]`,
		"bad generate key":   `[{"actor":"a","request":{"method":"PATCH","path":"/x","body":{"generate":{"pattern":"counter","length":1,"sed":1}}},"expect":{"status":204}}]`,
		"unknown control":    `[{"control":{"advance_clock":1}}]`,
		"control with actor": `[{"actor":"a","control":{"run_job":"purge_trash"}}]`,
		"unknown actor":      `[{"actor":"b","request":{"method":"GET","path":"/x"},"expect":{"status":200}}]`,
		"status and none":    `[{"actor":"a","request":{"method":"GET","path":"/x"},"expect":{}}]`,
		"drop with status":   `[{"actor":"a","request":{"method":"GET","path":"/x"},"transport":{"drop_after_bytes":1},"expect":{"status":200}}]`,
	} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			sd := filepath.Join(dir, "vectors", "server-scenarios")
			if err := os.MkdirAll(sd, 0o755); err != nil {
				t.Fatal(err)
			}
			doc := `{"schema_version":1,"kind":"server-scenario","description":"d","cases":[{"name":"c","actors":{"a":{"user":"u"}},"steps":` + steps + `}]}`
			if err := os.WriteFile(filepath.Join(sd, "x.json"), []byte(doc), 0o644); err != nil {
				t.Fatal(err)
			}
			if _, err := conformance.LoadScenarioCases(dir); err == nil {
				t.Fatal("malformed vector accepted")
			}
			// The same file with a well-formed step loads, and raw
			// payloads (json, expect.body) may hold any keys.
			doc = `{"schema_version":1,"kind":"server-scenario","description":"d","cases":[{"name":"c","actors":{"a":{"user":"u"}},"steps":[` + okStep +
				`,{"actor":"a","request":{"method":"POST","path":"/x","json":{"anything":1}},"expect":{"status":200,"body":{"whatever":true}}}]}]}`
			if err := os.WriteFile(filepath.Join(sd, "x.json"), []byte(doc), 0o644); err != nil {
				t.Fatal(err)
			}
			if _, err := conformance.LoadScenarioCases(dir); err != nil {
				t.Fatalf("well-formed vector rejected: %v", err)
			}
		})
	}
}
