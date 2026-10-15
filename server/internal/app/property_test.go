package app_test

// Property and chaos test (S§11.5): random programs of sync-client
// operations against the real HTTP API of a freshly booted app, with the
// seven S§11.5 invariants (plus a few structural ones) checked after every
// step. The number of programs comes from -rapid.checks (CI passes 500).

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/crypto/argon2"
	"pgregory.net/rapid"

	"github.com/PrithvirajG/pictunnel/server/internal/app"
	"github.com/PrithvirajG/pictunnel/server/internal/clock/clocktest"
	"github.com/PrithvirajG/pictunnel/server/internal/config"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/httpapitest"
	"github.com/PrithvirajG/pictunnel/server/internal/ids"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
)

// ---- payloads ------------------------------------------------------------

type payload struct {
	name, sha, mime, filename string
	data                      []byte
}

// fixedPayloads are A, B, C and V of P§10.1 (counter pattern: byte i =
// (i + seed) mod 256).
var fixedPayloads = sync.OnceValue(func() []*payload {
	specs := []struct {
		name         string
		seed, length int
		sha          string
	}{
		{"A", 0, 1 << 20, "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83"},
		{"B", 1, 1 << 20, "18af9b054114c04a1eb836533a3e760dfa9dc53934ecb02fc059ff27150e77fb"},
		{"C", 0, 3 << 20, "f6dd7fec8584ad00219a447071c1fa368a1caee4d9c146083d233713ddccd2c0"},
		{"V", 2, 1 << 20, "c11788fa01aebe9ddeadf2d6fd661693d75a0ca28dc957a6042b5ff6d8a08e66"},
	}
	out := make([]*payload, len(specs))
	for i, s := range specs {
		b := make([]byte, s.length)
		for j := range b {
			b[j] = byte((j + s.seed) % 256)
		}
		p := &payload{name: s.name, sha: s.sha, data: b, mime: "image/jpeg", filename: "IMG_" + s.name + ".JPG"}
		if s.name == "V" {
			p.mime, p.filename = "video/mp4", "VID_V.MP4"
		}
		out[i] = p
	}
	return out
})

// randomPayload is n deterministic pseudo-random bytes (xorshift from seed).
func randomPayload(i int, seed uint32, n int) *payload {
	b := make([]byte, n)
	x := seed | 1
	for j := range b {
		x ^= x << 13
		x ^= x >> 17
		x ^= x << 5
		b[j] = byte(x)
	}
	return &payload{name: fmt.Sprintf("R%d", i), sha: sha256Hex(b), data: b, mime: "image/jpeg",
		filename: fmt.Sprintf("IMG_R%d.JPG", i)}
}

// cheapPasswordHash is an argon2id PHC string with minimal parameters.
// Verification honours the parameters encoded in the hash, so logins stay
// fast without touching the production parameters.
var cheapPasswordHash = sync.OnceValue(func() string {
	salt := []byte("pictunnel-prop-1")
	key := argon2.IDKey([]byte(pw), salt, 1, 8, 1, 32)
	b := base64.RawStdEncoding
	return fmt.Sprintf("$argon2id$v=%d$m=8,t=1,p=1$%s$%s", argon2.Version, b.EncodeToString(salt), b.EncodeToString(key))
})

// ---- model ---------------------------------------------------------------

type device struct{ id, access, refresh string }

type user struct {
	name, id string
	devs     []*device
	// live is a client that took one snapshot and has followed the change
	// feed since; checkpoints are retained (cursor, state) pairs replayed
	// from scratch at every step.
	live        *feedState
	checkpoints []*feedState
}

type feedAsset struct{ sha, state string }

type feedState struct {
	cursor string
	assets map[string]feedAsset
}

func (f *feedState) clone() *feedState {
	c := &feedState{cursor: f.cursor, assets: make(map[string]feedAsset, len(f.assets))}
	for k, v := range f.assets {
		c.assets[k] = v
	}
	return c
}

// handle is one client's handle on an upload session.
type handle struct {
	u        *user
	dev      *device
	p        *payload
	data     []byte // what this client sends (a corrupted copy for a lying client)
	corrupt  bool
	override bool
	loc      string
	offset   int64 // the client's belief
}

func (up *handle) length() int64 { return int64(len(up.data)) }

type assetRow struct {
	id, owner, sha, path, state string
	size                        int64
}

type fileSig struct {
	size int64
	mod  time.Time
}

type world struct {
	t   *testing.T
	rt  *rapid.T
	a   *app.App
	clk *clocktest.Fake
	srv *httptest.Server
	hc  *http.Client

	// sent counts client requests (including dropped ones); started and
	// inflight count the server side, so a step can wait until the server
	// has finished everything it was sent.
	sent, started, inflight atomic.Int64

	users     []*user
	payloads  []*payload
	bySHA     map[string]*payload
	uploads   []*handle
	corrupted map[string]bool // owner|sha with a lying client
	steps     int
	action    string

	// Observations of the previous invariant check.
	prev      map[string]assetRow
	prevTombs map[string]bool // owner|sha
	offsets   map[string]int64
	apiOffset map[string]int64 // upload path → highest offset reported by the API
	ever      map[string]bool  // every asset id ever observed
	hashed    map[string]fileSig
}

// propStats counts what the programs exercised (logged once at the end,
// so a run that silently stops reaching a branch is visible).
var propStats = struct {
	sync.Mutex
	n map[string]int
}{n: map[string]int{}}

func stat(format string, args ...any) {
	propStats.Lock()
	propStats.n[fmt.Sprintf(format, args...)]++
	propStats.Unlock()
}

// rapidTB routes the testing.TB calls the shared helpers make to the
// rapid.T of the current check, so failures shrink.
type rapidTB struct {
	testing.TB
	rt *rapid.T
}

func (r rapidTB) Helper()                           {}
func (r rapidTB) Errorf(format string, args ...any) { r.rt.Errorf(format, args...) }
func (r rapidTB) Error(args ...any)                 { r.rt.Error(args...) }
func (r rapidTB) Fatalf(format string, args ...any) { r.rt.Fatalf(format, args...) }
func (r rapidTB) Fatal(args ...any)                 { r.rt.Fatal(args...) }
func (r rapidTB) Logf(format string, args ...any)   { r.rt.Logf(format, args...) }
func (r rapidTB) Log(args ...any)                   { r.rt.Log(args...) }
func (r rapidTB) FailNow()                          { r.rt.FailNow() }
func (r rapidTB) Fail()                             { r.rt.Fail() }
func (r rapidTB) Failed() bool                      { return r.rt.Failed() }

func (w *world) tb() testing.TB { return rapidTB{TB: w.t, rt: w.rt} }

// TestPropertySync runs random programs of 1–3 users with 1–4 devices each
// over payloads from A/B/C/V and random 1 B–200 KiB payloads.
func TestPropertySync(t *testing.T) {
	for _, p := range fixedPayloads() {
		if got := sha256Hex(p.data); got != p.sha {
			t.Fatalf("payload %s: sha256 %s, P§10.1 says %s", p.name, got, p.sha)
		}
	}
	rapid.Check(t, func(rt *rapid.T) {
		w := newWorld(t, rt)
		weights := map[string]struct {
			n int
			f func(*rapid.T)
		}{
			"create":          {4, w.actCreate},
			"patch":           {4, w.actPatch},
			"dropPatch":       {2, w.actDropPatch},
			"dropCreate":      {1, w.actDropCreate},
			"duplicate":       {2, w.actDuplicate},
			"reorder":         {1, w.actReorder},
			"concurrentPatch": {2, w.actConcurrentPatch},
			"head":            {2, w.actHead},
			"terminate":       {1, w.actTerminate},
			"check":           {2, w.actCheck},
			"trash":           {3, w.actTrash},
			"restore":         {1, w.actRestore},
			"purge":           {3, w.actPurge},
			"emptyTrash":      {1, w.actEmptyTrash},
			"deleteTombstone": {1, w.actDeleteTombstone},
			"download":        {1, w.actDownload},
			"advanceClock":    {2, w.actAdvanceClock},
			"runJob":          {2, w.actRunJob},
		}
		actions := map[string]func(*rapid.T){"": w.checkInvariants}
		for name, a := range weights {
			for i := range a.n {
				f, name := a.f, name
				actions[fmt.Sprintf("%s#%d", name, i)] = func(t *rapid.T) {
					w.action = name
					w.steps++
					f(t)
				}
			}
		}
		rt.Repeat(actions)
	})
	propStats.Lock()
	defer propStats.Unlock()
	keys := make([]string, 0, len(propStats.n))
	for k := range propStats.n {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		fmt.Fprintf(&b, "  %-40s %d\n", k, propStats.n[k])
	}
	t.Logf("exercised:\n%s", b.String())
}

func newWorld(t *testing.T, rt *rapid.T) *world {
	root, err := os.MkdirTemp("", "ptprop-")
	if err != nil {
		rt.Fatal(err)
	}
	cfg := config.Default()
	cfg.DataDir = filepath.Join(root, "data")
	cfg.LibraryDir = filepath.Join(cfg.DataDir, "library")
	cfg.Server.Name = "Property server"
	cfg.Server.HTTPSAddr = "127.0.0.1:0"
	cfg.Server.LocalAddr = "127.0.0.1:0"
	cfg.Discovery.MDNS = false
	clk := clocktest.NewFake(t0)
	a, err := app.New(context.Background(), app.Options{
		Config: cfg, Clock: clk, DisableScheduler: true,
		Log:       slog.New(slog.NewTextHandler(io.Discard, nil)),
		FreeSpace: func(string) (uint64, error) { return 1 << 40, nil },
	})
	if err != nil {
		_ = os.RemoveAll(root)
		rt.Fatal(err)
	}
	w := &world{
		t: t, rt: rt, a: a, clk: clk,
		bySHA: map[string]*payload{}, corrupted: map[string]bool{},
		prev: map[string]assetRow{}, prevTombs: map[string]bool{}, offsets: map[string]int64{},
		apiOffset: map[string]int64{}, ever: map[string]bool{}, hashed: map[string]fileSig{},
	}
	h := a.Handler()
	w.srv = httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		w.started.Add(1)
		w.inflight.Add(1)
		defer w.inflight.Add(-1)
		h.ServeHTTP(rw, r)
	}))
	w.hc = &http.Client{
		Transport:     &http.Transport{DisableCompression: true, MaxIdleConnsPerHost: 4},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		Timeout:       time.Minute,
	}
	rt.Cleanup(func() {
		w.hc.CloseIdleConnections()
		w.srv.Close()
		_ = a.Close()
		_ = os.RemoveAll(root)
	})

	// A small pool per program (1–2 of A/B/C/V plus 1–2 random payloads)
	// makes the clients collide on content: dedupe, joins, tombstones and
	// re-uploads over them.
	fixed := fixedPayloads()
	for _, i := range rapid.SliceOfNDistinct(rapid.IntRange(0, len(fixed)-1), 1, 2, rapid.ID[int]).Draw(rt, "fixed_payloads") {
		w.payloads = append(w.payloads, fixed[i])
	}
	for i := range rapid.IntRange(1, 2).Draw(rt, "random_payloads") {
		seed := rapid.Uint32().Draw(rt, "payload_seed")
		n := rapid.IntRange(1, 200<<10).Draw(rt, "payload_size")
		w.payloads = append(w.payloads, randomPayload(i, seed, n))
	}
	for _, p := range w.payloads {
		w.bySHA[p.sha] = p
	}

	ctx := context.Background()
	for i := range rapid.IntRange(1, 3).Draw(rt, "users") {
		name := fmt.Sprintf("user%d", i)
		// Users are inserted directly with a cheap password hash: account
		// creation is not under test, and the production argon2 parameters
		// would dominate the run time.
		id := ids.New()
		if _, err := a.Store().W.ExecContext(ctx, `INSERT INTO users (id, username, slug, display_name, role, password_hash, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?)`, id, name, name, name, service.RoleUser, cheapPasswordHash(),
			clk.Now().Format("2006-01-02T15:04:05.000Z")); err != nil {
			rt.Fatal(err)
		}
		usr := &user{name: name, id: id}
		for j := range rapid.IntRange(1, 4).Draw(rt, "devices") {
			usr.devs = append(usr.devs, w.login(usr, j))
		}
		w.users = append(w.users, usr)
	}
	return w
}

// ---- HTTP plumbing -------------------------------------------------------

func (w *world) newReq(method, path, token string, body []byte) *http.Request {
	var r io.Reader
	if body != nil {
		r = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, w.srv.URL+path, r)
	if err != nil {
		w.rt.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	return req
}

func (w *world) jsonReq(method, path, token string, v any) *http.Request {
	b, err := json.Marshal(v)
	if err != nil {
		w.rt.Fatal(err)
	}
	req := w.newReq(method, path, token, b)
	req.Header.Set("Content-Type", "application/json")
	return req
}

// rawSend performs req and reads the whole body; safe from goroutines.
func (w *world) rawSend(req *http.Request) (*http.Response, []byte, error) {
	w.sent.Add(1)
	resp, err := w.hc.Do(req)
	if err != nil {
		return nil, nil, err
	}
	raw, err := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if err != nil {
		return nil, nil, err
	}
	resp.Body = io.NopCloser(bytes.NewReader(raw))
	return resp, raw, nil
}

// validate checks a response against the OpenAPI contract.
func (w *world) validate(req *http.Request, resp *http.Response, raw []byte) {
	resp.Body = io.NopCloser(bytes.NewReader(raw))
	httpapitest.AssertContract(w.tb(), req, resp)
	resp.Body = io.NopCloser(bytes.NewReader(raw))
}

// send performs req, validates the response against the contract and
// returns it with its body.
func (w *world) send(req *http.Request) (*http.Response, []byte) {
	resp, raw, err := w.rawSend(req)
	if err != nil {
		w.rt.Fatalf("%s %s: %v", req.Method, req.URL.Path, err)
	}
	w.validate(req, resp, raw)
	return resp, raw
}

// drop writes the request head and the first k bytes of a body of
// len(body) bytes on a raw connection, then closes it (a client that went
// away mid-request).
func (w *world) drop(method, path string, hdr http.Header, body []byte, k int64) {
	addr := w.srv.Listener.Addr().String()
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		w.rt.Fatal(err)
	}
	var b bytes.Buffer
	fmt.Fprintf(&b, "%s %s HTTP/1.1\r\nHost: %s\r\n", method, path, addr)
	_ = hdr.Write(&b)
	fmt.Fprintf(&b, "Content-Length: %d\r\n\r\n", len(body))
	b.Write(body[:k])
	w.sent.Add(1)
	_, _ = conn.Write(b.Bytes())
	_ = conn.Close()
}

// settle waits until the server has started every request sent and none
// is still running (a dropped request finishes asynchronously).
func (w *world) settle() {
	deadline := time.Now().Add(20 * time.Second)
	for w.started.Load() < w.sent.Load() || w.inflight.Load() > 0 {
		if time.Now().After(deadline) {
			w.rt.Fatalf("server did not settle: sent %d, started %d, in flight %d",
				w.sent.Load(), w.started.Load(), w.inflight.Load())
		}
		time.Sleep(200 * time.Microsecond)
	}
}

func problemCode(raw []byte) string {
	var p struct {
		Code string `json:"code"`
	}
	_ = json.Unmarshal(raw, &p)
	return p.Code
}

func hdrInt(resp *http.Response, name string) int64 {
	v, err := strconv.ParseInt(resp.Header.Get(name), 10, 64)
	if err != nil {
		return -1
	}
	return v
}

// ---- auth ----------------------------------------------------------------

type tokenPair struct {
	Access  string `json:"access_token"`
	Refresh string `json:"refresh_token"`
}

func (w *world) login(u *user, j int) *device {
	resp, raw := w.send(w.jsonReq(http.MethodPost, "/api/v1/auth/login", "", map[string]any{
		"username": u.name, "password": pw, "mode": "tokens",
		"device": map[string]any{"device_name": fmt.Sprintf("Phone %d", j), "platform": "android", "app_version": "0.1.0"},
	}))
	if resp.StatusCode != http.StatusOK {
		w.rt.Fatalf("login %s: %d %s", u.name, resp.StatusCode, raw)
	}
	var out struct {
		Device struct {
			ID string `json:"id"`
		} `json:"device"`
		Tokens tokenPair `json:"tokens"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		w.rt.Fatal(err)
	}
	return &device{id: out.Device.ID, access: out.Tokens.Access, refresh: out.Tokens.Refresh}
}

func (w *world) refresh(d *device) {
	resp, raw := w.send(w.jsonReq(http.MethodPost, "/api/v1/auth/refresh", "", map[string]string{"refresh_token": d.refresh}))
	if resp.StatusCode != http.StatusOK {
		w.rt.Fatalf("refresh: %d %s", resp.StatusCode, raw)
	}
	var tp tokenPair
	if err := json.Unmarshal(raw, &tp); err != nil {
		w.rt.Fatal(err)
	}
	d.access, d.refresh = tp.Access, tp.Refresh
}

// ---- pickers -------------------------------------------------------------

func (w *world) pickUser(t *rapid.T, label string) *user {
	return w.users[rapid.IntRange(0, len(w.users)-1).Draw(t, label)]
}

func (w *world) pickPayload(t *rapid.T) *payload {
	return w.payloads[rapid.IntRange(0, len(w.payloads)-1).Draw(t, "payload")]
}

// pickUpload returns a known upload handle, or nil when there is none.
func (w *world) pickUpload(t *rapid.T) *handle {
	if len(w.uploads) == 0 {
		return nil
	}
	return w.uploads[rapid.IntRange(0, len(w.uploads)-1).Draw(t, "upload")]
}

// forget drops every handle on the upload path loc (the session is gone).
func (w *world) forget(loc string) {
	kept := w.uploads[:0]
	for _, up := range w.uploads {
		if up.loc != loc {
			kept = append(kept, up)
		}
	}
	w.uploads = kept
}

// ---- DB views ------------------------------------------------------------

func (w *world) rowsOf(q string, args ...any) [][]string {
	var out [][]string
	for _, s := range queryStrings(w.tb(), w.a, q, args...) {
		out = append(out, strings.Split(s, "|"))
	}
	return out
}

func (w *world) assets() map[string]assetRow {
	out := map[string]assetRow{}
	for _, r := range w.rowsOf(`SELECT id, owner_id, sha256, original_path, state, size_bytes FROM assets`) {
		n, _ := strconv.ParseInt(r[5], 10, 64)
		out[r[0]] = assetRow{id: r[0], owner: r[1], sha: r[2], path: r[3], state: r[4], size: n}
	}
	return out
}

func (w *world) ownAssets(u *user) []assetRow {
	var out []assetRow
	for _, a := range w.assets() {
		if a.owner == u.id {
			out = append(out, a)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].id < out[j].id })
	return out
}

func (w *world) foreignAssets(u *user) []assetRow {
	var out []assetRow
	for _, a := range w.assets() {
		if a.owner != u.id {
			out = append(out, a)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].id < out[j].id })
	return out
}

// contentState is what the database says about (owner, sha): the asset,
// the active (resumable) session and the tombstone.
type contentState struct {
	asset, assetState string
	session           string
	sessionOffset     int64
	tomb              bool
}

func (w *world) contentState(u *user, sha string) contentState {
	var cs contentState
	if r := w.rowsOf(`SELECT id, state FROM assets WHERE owner_id = ? AND sha256 = ?`, u.id, sha); len(r) > 0 {
		cs.asset, cs.assetState = r[0][0], r[0][1]
	}
	now := w.clk.Now()
	for _, r := range w.rowsOf(`SELECT id, "offset", state, expires_at FROM upload_sessions
		WHERE owner_id = ? AND sha256 = ? AND state IN ('receiving', 'finalizing')`, u.id, sha) {
		exp, err := time.Parse("2006-01-02T15:04:05.000Z", r[3])
		if err != nil {
			w.rt.Fatalf("expires_at %q: %v", r[3], err)
		}
		// Expired means strictly past expires_at, as for HEAD, create and
		// the expiry sweep (S§6.4).
		if r[2] == "receiving" && now.After(exp) {
			continue
		}
		cs.session = r[0]
		cs.sessionOffset, _ = strconv.ParseInt(r[1], 10, 64)
	}
	cs.tomb = len(w.rowsOf(`SELECT 1 FROM tombstones WHERE owner_id = ? AND sha256 = ?`, u.id, sha)) > 0
	return cs
}

// ---- tus requests --------------------------------------------------------

func (w *world) tusHeaders(req *http.Request) {
	req.Header.Set("Tus-Resumable", "1.0.0")
}

func (w *world) metadata(up *handle) string {
	kv := [][2]string{
		{"sha256", up.p.sha}, {"filename", up.p.filename}, {"mime", up.p.mime},
		{"local_id", "L-" + up.p.name}, {"created_at", "2024-05-06T07:08:09Z"},
	}
	if up.override {
		kv = append(kv, [2]string{"override_tombstone", "1"})
	}
	parts := make([]string, len(kv))
	for i, p := range kv {
		parts[i] = p[0] + " " + base64.StdEncoding.EncodeToString([]byte(p[1]))
	}
	return strings.Join(parts, ",")
}

func (w *world) createReq(up *handle, body []byte) *http.Request {
	req := w.newReq(http.MethodPost, "/api/v1/uploads", up.dev.access, body)
	w.tusHeaders(req)
	req.Header.Set("Upload-Length", strconv.FormatInt(up.length(), 10))
	req.Header.Set("Upload-Metadata", w.metadata(up))
	if len(body) > 0 {
		req.Header.Set("Content-Type", "application/offset+octet-stream")
	}
	return req
}

func (w *world) patchReq(up *handle, dev *device, off, n int64) *http.Request {
	req := w.newReq(http.MethodPatch, up.loc, dev.access, up.data[off:off+n])
	w.tusHeaders(req)
	req.Header.Set("Content-Type", "application/offset+octet-stream")
	req.Header.Set("Upload-Offset", strconv.FormatInt(off, 10))
	return req
}

// newUpload draws a client handle for (user, device, payload): rarely a
// tombstone override, rarely a lying client whose bytes do not match the
// declared sha256.
func (w *world) newUpload(t *rapid.T) *handle {
	u := w.pickUser(t, "user")
	d := u.devs[rapid.IntRange(0, len(u.devs)-1).Draw(t, "device")]
	p := w.pickPayload(t)
	up := &handle{u: u, dev: d, p: p, data: p.data}
	up.override = rapid.IntRange(0, 5).Draw(t, "override") == 0
	if rapid.IntRange(0, 11).Draw(t, "corrupt") == 0 {
		up.corrupt = true
		up.data = bytes.Clone(p.data)
		up.data[rapid.IntRange(0, len(p.data)-1).Draw(t, "corrupt_at")] ^= 0xff
		w.corrupted[u.id+"|"+p.sha] = true
	}
	return up
}

// observeOffset records an offset the API reported for an upload path and
// checks that it never decreases (invariant 7 at the API).
func (w *world) observeOffset(up *handle, off int64, what string) {
	if off < 0 || off > up.length() {
		w.rt.Errorf("%s: Upload-Offset %d outside [0, %d]", what, off, up.length())
	}
	if prev, ok := w.apiOffset[up.loc]; ok && off < prev {
		w.rt.Errorf("%s: Upload-Offset went back from %d to %d for %s", what, prev, off, up.loc)
	}
	w.apiOffset[up.loc] = max(w.apiOffset[up.loc], off)
}

// create POSTs up with body and checks the outcome against the database
// state before the request (P§7.3 precedence).
func (w *world) create(up *handle, body []byte) (*http.Response, []byte) {
	pre := w.contentState(up.u, up.p.sha)
	resp, raw := w.send(w.createReq(up, body))
	stat("POST %d %s asset=%v", resp.StatusCode, problemCode(raw), resp.Header.Get("PicTunnel-Asset-Id") != "")
	what := fmt.Sprintf("POST %s for %s (body %d)", up.p.name, up.u.name, len(body))
	switch resp.StatusCode {
	case http.StatusCreated:
		if pre.tomb && !up.override {
			w.rt.Errorf("%s: created although tombstoned and no override", what)
		}
		up.loc = resp.Header.Get("Location")
		off := hdrInt(resp, "Upload-Offset")
		w.observeOffset(up, off, what)
		up.offset = off
		id := resp.Header.Get("PicTunnel-Asset-Id")
		if pre.asset != "" && (id != pre.asset || resp.Header.Get("PicTunnel-Asset-Created") != "false") {
			w.rt.Errorf("%s: existing asset %s, got asset %q created %q", what, pre.asset, id,
				resp.Header.Get("PicTunnel-Asset-Created"))
		}
		if id != "" && off != up.length() {
			w.rt.Errorf("%s: asset %s with offset %d of %d", what, id, off, up.length())
		}
		if pre.asset == "" && pre.session != "" && up.loc != "/api/v1/uploads/"+pre.session && id == "" {
			w.rt.Errorf("%s: active session %s, got Location %s", what, pre.session, up.loc)
		}
		w.uploads = append(w.uploads, up)
	case http.StatusConflict:
		if c := problemCode(raw); c != "tombstoned" || !pre.tomb || up.override {
			w.rt.Errorf("%s: 409 %s (tombstone %v, override %v)", what, c, pre.tomb, up.override)
		}
	case 460:
		if c := problemCode(raw); c != "checksum_mismatch" || !w.corrupted[up.u.id+"|"+up.p.sha] {
			w.rt.Errorf("%s: 460 %s without a lying client", what, c)
		}
	default:
		w.rt.Errorf("%s: unexpected %d %s", what, resp.StatusCode, raw)
	}
	return resp, raw
}

// afterPatch checks one PATCH outcome of n bytes at off and updates the
// handle.
func (w *world) afterPatch(up *handle, off, n int64, resp *http.Response, raw []byte) {
	stat("PATCH %d %s asset=%v", resp.StatusCode, problemCode(raw), resp.Header.Get("PicTunnel-Asset-Id") != "")
	what := fmt.Sprintf("PATCH %s [%d,+%d) of %d", up.loc, off, n, up.length())
	switch resp.StatusCode {
	case http.StatusNoContent:
		o := hdrInt(resp, "Upload-Offset")
		w.observeOffset(up, o, what)
		id := resp.Header.Get("PicTunnel-Asset-Id")
		switch {
		case id != "" && o != up.length():
			w.rt.Errorf("%s: asset %s at offset %d", what, id, o)
		case id == "" && o != off+n:
			w.rt.Errorf("%s: 204 with offset %d, want %d", what, o, off+n)
		case id == "" && o == up.length():
			w.rt.Errorf("%s: complete upload without an asset", what)
		}
		up.offset = o
	case http.StatusConflict:
		switch c := problemCode(raw); c {
		case "offset_mismatch":
			o := hdrInt(resp, "Upload-Offset")
			w.observeOffset(up, o, what)
			if o == off {
				w.rt.Errorf("%s: offset_mismatch at the server offset", what)
			}
			up.offset = o
		case "tombstoned":
		default:
			w.rt.Errorf("%s: 409 %s", what, c)
		}
	case http.StatusNotFound:
		w.forget(up.loc)
	case 460:
		if c := problemCode(raw); c != "checksum_mismatch" || !w.corrupted[up.u.id+"|"+up.p.sha] {
			w.rt.Errorf("%s: 460 %s without a lying client", what, c)
		}
		w.forget(up.loc)
	default:
		w.rt.Errorf("%s: unexpected %d %s", what, resp.StatusCode, raw)
	}
}

// head refreshes the handle's offset; it reports false when the session is
// gone or done.
func (w *world) head(up *handle) bool {
	resp, raw := w.send(func() *http.Request {
		req := w.newReq(http.MethodHead, up.loc, up.dev.access, nil)
		w.tusHeaders(req)
		return req
	}())
	what := "HEAD " + up.loc
	switch resp.StatusCode {
	case http.StatusOK:
		o := hdrInt(resp, "Upload-Offset")
		w.observeOffset(up, o, what)
		if l := hdrInt(resp, "Upload-Length"); l != up.length() {
			w.rt.Errorf("%s: Upload-Length %d, want %d", what, l, up.length())
		}
		up.offset = o
		if id := resp.Header.Get("PicTunnel-Asset-Id"); id != "" {
			if o != up.length() {
				w.rt.Errorf("%s: asset %s at offset %d", what, id, o)
			}
			return false
		}
		return true
	case http.StatusNotFound:
		w.forget(up.loc)
		return false
	default:
		w.rt.Errorf("%s: unexpected %d %s", what, resp.StatusCode, raw)
		return false
	}
}

// chunk draws a chunk size in [1, rem], often the whole rest.
func chunk(t *rapid.T, rem int64) int64 {
	if rem <= 1 || rapid.Bool().Draw(t, "whole_rest") {
		return rem
	}
	return rapid.Int64Range(1, rem).Draw(t, "chunk")
}

// ---- actions -------------------------------------------------------------

func (w *world) actCreate(t *rapid.T) {
	up := w.newUpload(t)
	var body []byte
	switch rapid.SampledFrom([]string{"none", "partial", "full"}).Draw(t, "body") {
	case "partial":
		body = up.data[:rapid.IntRange(1, len(up.data)).Draw(t, "body_len")]
	case "full":
		body = up.data
	}
	w.create(up, body)
}

func (w *world) actPatch(t *rapid.T) {
	up := w.pickUpload(t)
	if up == nil {
		w.actCreate(t)
		return
	}
	off := up.offset
	if rapid.IntRange(0, 4).Draw(t, "wrong_offset") == 0 {
		off = rapid.Int64Range(0, up.length()).Draw(t, "offset")
	}
	n := chunk(t, up.length()-off)
	dev := up.u.devs[rapid.IntRange(0, len(up.u.devs)-1).Draw(t, "patch_device")]
	resp, raw := w.send(w.patchReq(up, dev, off, n))
	w.afterPatch(up, off, n, resp, raw)
}

func (w *world) actDropPatch(t *rapid.T) {
	up := w.pickUpload(t)
	if up == nil || up.offset >= up.length() {
		w.actPatch(t)
		return
	}
	n := chunk(t, up.length()-up.offset)
	k := rapid.Int64Range(0, n-1).Draw(t, "sent_bytes")
	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer "+up.dev.access)
	hdr.Set("Tus-Resumable", "1.0.0")
	hdr.Set("Content-Type", "application/offset+octet-stream")
	hdr.Set("Upload-Offset", strconv.FormatInt(up.offset, 10))
	w.drop(http.MethodPatch, up.loc, hdr, up.data[up.offset:up.offset+n], k)
	stat("dropped PATCH")
}

func (w *world) actDropCreate(t *rapid.T) {
	up := w.newUpload(t)
	k := rapid.Int64Range(0, up.length()-1).Draw(t, "sent_bytes")
	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer "+up.dev.access)
	hdr.Set("Tus-Resumable", "1.0.0")
	hdr.Set("Content-Type", "application/offset+octet-stream")
	hdr.Set("Upload-Length", strconv.FormatInt(up.length(), 10))
	hdr.Set("Upload-Metadata", w.metadata(up))
	// The client never sees the Location: it has to find the session again
	// through check or a new POST.
	w.drop(http.MethodPost, "/api/v1/uploads", hdr, up.data, k)
	stat("dropped POST")
}

// actDuplicate sends the same request twice (a client retry after a lost
// response).
func (w *world) actDuplicate(t *rapid.T) {
	up := w.pickUpload(t)
	if up == nil || rapid.Bool().Draw(t, "dup_post") {
		if up == nil {
			up = w.newUpload(t)
		} else {
			up = &handle{u: up.u, dev: up.dev, p: up.p, data: up.data, corrupt: up.corrupt, override: up.override}
		}
		var body []byte
		if rapid.Bool().Draw(t, "dup_body") {
			body = up.data
		}
		second := *up
		r1, _ := w.create(up, body)
		r2, _ := w.create(&second, body)
		if r1.StatusCode == http.StatusCreated && r2.StatusCode == http.StatusCreated {
			id1, id2 := r1.Header.Get("PicTunnel-Asset-Id"), r2.Header.Get("PicTunnel-Asset-Id")
			switch {
			case id1 != "" && id1 != id2:
				w.rt.Errorf("duplicate POST: asset %s then %q", id1, id2)
			case id1 == "" && id2 == "" && up.loc != second.loc:
				w.rt.Errorf("duplicate POST: Location %s then %s", up.loc, second.loc)
			}
		}
		return
	}
	off := up.offset
	n := chunk(t, up.length()-off)
	r1, raw1 := w.send(w.patchReq(up, up.dev, off, n))
	w.afterPatch(up, off, n, r1, raw1)
	r2, raw2 := w.send(w.patchReq(up, up.dev, off, n))
	w.afterPatch(up, off, n, r2, raw2)
	if r1.StatusCode == http.StatusNoContent && r1.Header.Get("PicTunnel-Asset-Id") == "" && n > 0 {
		if r2.StatusCode != http.StatusConflict || problemCode(raw2) != "offset_mismatch" || hdrInt(r2, "Upload-Offset") != off+n {
			w.rt.Errorf("duplicate PATCH: second got %d %s offset %s", r2.StatusCode, problemCode(raw2), r2.Header.Get("Upload-Offset"))
		}
	}
}

// actReorder sends the second of two chunks before the first.
func (w *world) actReorder(t *rapid.T) {
	up := w.pickUpload(t)
	if up == nil || !w.head(up) || up.length()-up.offset < 2 {
		return
	}
	off := up.offset
	a := rapid.Int64Range(1, up.length()-off-1).Draw(t, "first")
	b := rapid.Int64Range(1, up.length()-off-a).Draw(t, "second")
	r, raw := w.send(w.patchReq(up, up.dev, off+a, b))
	if r.StatusCode != http.StatusConflict || problemCode(raw) != "offset_mismatch" || hdrInt(r, "Upload-Offset") != off {
		w.rt.Errorf("out-of-order PATCH at %d (server at %d): %d %s", off+a, off, r.StatusCode, raw)
	}
	r, raw = w.send(w.patchReq(up, up.dev, off, a))
	w.afterPatch(up, off, a, r, raw)
	if r.StatusCode != http.StatusNoContent {
		return
	}
	r, raw = w.send(w.patchReq(up, up.dev, off+a, b))
	w.afterPatch(up, off+a, b, r, raw)
}

// actConcurrentPatch races two PATCHes of the same bytes at the same
// offset: exactly one wins; the other sees the lock (423) or the moved
// offset (409), or, when the winner finalized, the finished upload.
func (w *world) actConcurrentPatch(t *rapid.T) {
	up := w.pickUpload(t)
	if up == nil || !w.head(up) || up.offset >= up.length() {
		return
	}
	off := up.offset
	n := chunk(t, up.length()-off)
	devs := [2]*device{up.dev, up.u.devs[rapid.IntRange(0, len(up.u.devs)-1).Draw(t, "other_device")]}
	type result struct {
		req  *http.Request
		resp *http.Response
		raw  []byte
		err  error
	}
	var res [2]result
	var wg sync.WaitGroup
	for i := range res {
		res[i].req = w.patchReq(up, devs[i], off, n)
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			res[i].resp, res[i].raw, res[i].err = w.rawSend(res[i].req)
		}(i)
	}
	wg.Wait()
	final := off+n == up.length()
	winners, winnerAsset := 0, ""
	for _, r := range res {
		if r.err != nil {
			w.rt.Fatalf("concurrent PATCH: %v", r.err)
		}
		w.validate(r.req, r.resp, r.raw)
	}
	for _, r := range res {
		if r.resp.StatusCode == http.StatusNoContent && (r.resp.Header.Get("PicTunnel-Asset-Id") == "" || winners == 0) {
			winners++
			winnerAsset = r.resp.Header.Get("PicTunnel-Asset-Id")
		}
	}
	for _, r := range res {
		s, code := r.resp.StatusCode, problemCode(r.raw)
		ok := s == http.StatusNoContent ||
			s == http.StatusLocked && code == "upload_locked" ||
			s == http.StatusConflict && code == "offset_mismatch" ||
			(s == 460 || s == http.StatusNotFound) && w.corrupted[up.u.id+"|"+up.p.sha]
		if s == http.StatusNoContent && final && r.resp.Header.Get("PicTunnel-Asset-Id") != winnerAsset {
			ok = false
		}
		if !ok {
			w.rt.Errorf("concurrent PATCH [%d,+%d): %d %s", off, n, s, r.raw)
		}
	}
	lying := w.corrupted[up.u.id+"|"+up.p.sha]
	stat("concurrent PATCH %d/%d final=%v", min(res[0].resp.StatusCode, res[1].resp.StatusCode),
		max(res[0].resp.StatusCode, res[1].resp.StatusCode), final)
	if winners != 1 && !(lying && final) {
		w.rt.Errorf("concurrent PATCH [%d,+%d) of %d: %d winners (%d, %d)", off, n, up.length(), winners,
			res[0].resp.StatusCode, res[1].resp.StatusCode)
	}
	for _, r := range res {
		switch r.resp.StatusCode {
		case http.StatusNoContent:
			w.observeOffset(up, hdrInt(r.resp, "Upload-Offset"), "concurrent PATCH")
			up.offset = hdrInt(r.resp, "Upload-Offset")
		case 460, http.StatusNotFound:
			w.forget(up.loc)
			return
		}
	}
	if up.offset < up.length() {
		w.head(up)
		if up.offset != off+n {
			w.rt.Errorf("concurrent PATCH [%d,+%d): server offset %d", off, n, up.offset)
		}
	}
}

func (w *world) actHead(t *rapid.T) {
	if up := w.pickUpload(t); up != nil {
		w.head(up)
	}
}

func (w *world) actTerminate(t *rapid.T) {
	up := w.pickUpload(t)
	if up == nil {
		return
	}
	req := w.newReq(http.MethodDelete, up.loc, up.dev.access, nil)
	w.tusHeaders(req)
	resp, raw := w.send(req)
	switch resp.StatusCode {
	case http.StatusNoContent, http.StatusNotFound:
		w.forget(up.loc)
	default:
		w.rt.Errorf("DELETE %s: %d %s", up.loc, resp.StatusCode, raw)
	}
}

// actCheck asks sync/check about every payload (and an unknown hash) and
// compares each verdict with the database.
func (w *world) actCheck(t *rapid.T) {
	u := w.pickUser(t, "user")
	d := u.devs[rapid.IntRange(0, len(u.devs)-1).Draw(t, "device")]
	unknown := strings.Repeat("0", 63) + "1"
	var items []map[string]any
	for _, p := range w.payloads {
		items = append(items, map[string]any{"sha256": p.sha, "size_bytes": len(p.data), "local_id": "L-" + p.name,
			"confirm_on_disk": true})
	}
	items = append(items, map[string]any{"sha256": unknown, "size_bytes": 1})
	resp, raw := w.send(w.jsonReq(http.MethodPost, "/api/v1/sync/check", d.access, map[string]any{"items": items}))
	if resp.StatusCode != http.StatusOK {
		w.rt.Fatalf("check: %d %s", resp.StatusCode, raw)
	}
	var out struct {
		Results []struct {
			SHA256     string `json:"sha256"`
			Verdict    string `json:"verdict"`
			AssetID    string `json:"asset_id"`
			AssetState string `json:"asset_state"`
			OnDisk     *bool  `json:"on_disk"`
			Upload     *struct {
				URL    string `json:"url"`
				Offset int64  `json:"offset"`
			} `json:"upload"`
		} `json:"results"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || len(out.Results) != len(items) {
		w.rt.Fatalf("check: %v: %s", err, raw)
	}
	for i, r := range out.Results {
		sha := items[i]["sha256"].(string)
		cs := w.contentState(u, sha)
		want := "missing"
		switch {
		case cs.asset != "":
			want = "exists"
		case cs.session != "":
			want = "partial"
		case cs.tomb:
			want = "tombstoned"
		}
		stat("check verdict %s", r.Verdict)
		if r.SHA256 != sha || r.Verdict != want {
			w.rt.Errorf("check %s for %s: verdict %q, database says %q (%+v)", sha[:8], u.name, r.Verdict, want, cs)
			continue
		}
		switch want {
		case "exists":
			if r.AssetID != cs.asset || r.AssetState != cs.assetState || r.OnDisk == nil || !*r.OnDisk {
				w.rt.Errorf("check %s: exists %s/%s on_disk %v, database %s/%s", sha[:8], r.AssetID, r.AssetState,
					r.OnDisk, cs.asset, cs.assetState)
			}
		case "partial":
			if r.Upload == nil || r.Upload.URL != "/api/v1/uploads/"+cs.session || r.Upload.Offset != cs.sessionOffset {
				w.rt.Errorf("check %s: partial %+v, database session %s at %d", sha[:8], r.Upload, cs.session, cs.sessionOffset)
			}
		}
	}
}

// bulk posts asset ids to a trash endpoint: a random subset of the user's
// own assets, sometimes another user's asset and an unknown id, which must
// fail with not_found (no asset is visible to another user).
func (w *world) bulk(t *rapid.T, op string) (*user, []assetRow, map[string]bool, map[string]string) {
	u := w.pickUser(t, "user")
	own := w.ownAssets(u)
	var ids []string
	for i, a := range own {
		if rapid.Bool().Draw(t, fmt.Sprintf("include_%d", i)) {
			ids = append(ids, a.id)
		}
	}
	foreign := map[string]bool{}
	if fa := w.foreignAssets(u); len(fa) > 0 && rapid.IntRange(0, 3).Draw(t, "foreign") == 0 {
		id := fa[rapid.IntRange(0, len(fa)-1).Draw(t, "foreign_id")].id
		ids, foreign[id] = append(ids, id), true
	}
	if len(ids) == 0 || rapid.IntRange(0, 5).Draw(t, "unknown") == 0 {
		id := "00000000-0000-7000-8000-000000000000"
		ids, foreign[id] = append(ids, id), true
	}
	resp, raw := w.send(w.jsonReq(http.MethodPost, "/api/v1/assets/"+op, u.devs[0].access, map[string]any{"asset_ids": ids}))
	if resp.StatusCode != http.StatusOK {
		w.rt.Fatalf("%s: %d %s", op, resp.StatusCode, raw)
	}
	var out struct {
		Succeeded []string `json:"succeeded"`
		Failed    []struct {
			AssetID string `json:"asset_id"`
			Code    string `json:"code"`
		} `json:"failed"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		w.rt.Fatal(err)
	}
	failed := map[string]string{}
	for _, f := range out.Failed {
		failed[f.AssetID] = f.Code
		if foreign[f.AssetID] != (f.Code == "not_found") {
			w.rt.Errorf("%s %s: failed %s (foreign %v)", op, f.AssetID, f.Code, foreign[f.AssetID])
		}
	}
	succeeded := map[string]bool{}
	for _, id := range out.Succeeded {
		succeeded[id] = true
		if foreign[id] {
			w.rt.Errorf("%s: another user's or unknown asset %s succeeded", op, id)
		}
	}
	var sent []assetRow
	for _, a := range own {
		for _, id := range ids {
			if id == a.id {
				sent = append(sent, a)
			}
		}
	}
	return u, sent, succeeded, failed
}

func (w *world) actTrash(t *rapid.T) {
	_, sent, ok, _ := w.bulk(t, "trash")
	after := w.assets()
	for _, a := range sent {
		if !ok[a.id] || after[a.id].state != "trashed" {
			w.rt.Errorf("trash %s: succeeded %v, state %q", a.id, ok[a.id], after[a.id].state)
		}
	}
}

func (w *world) actRestore(t *rapid.T) {
	_, sent, ok, _ := w.bulk(t, "restore")
	after := w.assets()
	for _, a := range sent {
		if !ok[a.id] || after[a.id].state != "active" {
			w.rt.Errorf("restore %s: succeeded %v, state %q", a.id, ok[a.id], after[a.id].state)
		}
	}
}

func (w *world) actPurge(t *rapid.T) {
	u, sent, ok, failed := w.bulk(t, "purge")
	after := w.assets()
	for _, a := range sent {
		_, still := after[a.id]
		tomb := w.contentState(u, a.sha).tomb
		if a.state == "trashed" && (!ok[a.id] || still || !tomb) {
			w.rt.Errorf("purge trashed %s: succeeded %v, still there %v, tombstone %v", a.id, ok[a.id], still, tomb)
		}
		if a.state == "active" && (failed[a.id] != "not_trashed" || !still) {
			w.rt.Errorf("purge active %s: failure %q, still there %v", a.id, failed[a.id], still)
		}
	}
}

func (w *world) actEmptyTrash(t *rapid.T) {
	u := w.pickUser(t, "user")
	var trashed []assetRow
	for _, a := range w.ownAssets(u) {
		if a.state == "trashed" {
			trashed = append(trashed, a)
		}
	}
	resp, raw := w.send(w.newReq(http.MethodPost, "/api/v1/trash/empty", u.devs[0].access, nil))
	if resp.StatusCode != http.StatusOK {
		w.rt.Fatalf("empty trash: %d %s", resp.StatusCode, raw)
	}
	var out struct {
		N int `json:"purged_count"`
	}
	_ = json.Unmarshal(raw, &out)
	if out.N != len(trashed) {
		w.rt.Errorf("empty trash: purged %d, %d were trashed", out.N, len(trashed))
	}
	for _, a := range w.ownAssets(u) {
		if a.state == "trashed" {
			w.rt.Errorf("empty trash: %s still trashed", a.id)
		}
	}
}

func (w *world) actDeleteTombstone(t *rapid.T) {
	u := w.pickUser(t, "user")
	p := w.pickPayload(t)
	resp, raw := w.send(w.newReq(http.MethodDelete, "/api/v1/tombstones/"+p.sha, u.devs[0].access, nil))
	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusNotFound {
		w.rt.Errorf("delete tombstone: %d %s", resp.StatusCode, raw)
	}
	if w.contentState(u, p.sha).tomb {
		w.rt.Errorf("delete tombstone %s: still there", p.name)
	}
}

// actDownload reads an asset's original (whole or a range) as its owner,
// and as every other user (404).
func (w *world) actDownload(t *rapid.T) {
	u := w.pickUser(t, "user")
	own := w.ownAssets(u)
	if len(own) == 0 {
		return
	}
	a := own[rapid.IntRange(0, len(own)-1).Draw(t, "asset")]
	p := w.bySHA[a.sha]
	req := w.newReq(http.MethodGet, "/api/v1/assets/"+a.id+"/original", u.devs[0].access, nil)
	from, to := int64(0), a.size-1
	ranged := a.size > 1 && rapid.Bool().Draw(t, "range")
	if ranged {
		from = rapid.Int64Range(0, a.size-1).Draw(t, "range_from")
		to = rapid.Int64Range(from, a.size-1).Draw(t, "range_to")
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", from, to))
	}
	resp, raw := w.send(req)
	want := http.StatusOK
	if ranged {
		want = http.StatusPartialContent
	}
	if resp.StatusCode != want || p == nil || !bytes.Equal(raw, p.data[from:to+1]) {
		w.rt.Errorf("download %s [%d,%d]: %d, %d bytes", a.id, from, to, resp.StatusCode, len(raw))
	}
	for _, o := range w.users {
		if o == u {
			continue
		}
		resp, _ := w.send(w.newReq(http.MethodGet, "/api/v1/assets/"+a.id+"/original", o.devs[0].access, nil))
		if resp.StatusCode != http.StatusNotFound {
			w.rt.Errorf("download %s as %s: %d, want 404", a.id, o.name, resp.StatusCode)
		}
	}
}

// actAdvanceClock moves the fake clock (across the access-token TTL, the
// upload expiry, the trash retention and, cumulatively, the change-log
// retention) and then refreshes every device's tokens.
func (w *world) actAdvanceClock(t *rapid.T) {
	d := rapid.SampledFrom([]time.Duration{
		time.Second, 10 * time.Minute, 16 * time.Minute, time.Hour,
		24 * time.Hour, 25 * time.Hour, 8 * 24 * time.Hour, 31 * 24 * time.Hour,
	}).Draw(t, "advance")
	w.clk.Advance(d)
	for _, u := range w.users {
		for _, dev := range u.devs {
			w.refresh(dev)
		}
	}
}

func (w *world) actRunJob(t *rapid.T) {
	kinds := []string{service.JobDeleteFile}
	for _, p := range app.Periodic {
		kinds = append(kinds, p.Kind)
	}
	kind := rapid.SampledFrom(kinds).Draw(t, "job")
	w.action = "runJob:" + kind
	stat("job %s", kind)
	if err := w.a.Jobs().RunNow(context.Background(), kind); err != nil {
		w.rt.Errorf("RunNow(%s): %v", kind, err)
	}
}

// ---- feed client ---------------------------------------------------------

type wireAsset struct {
	ID     string `json:"id"`
	SHA256 string `json:"sha256"`
	State  string `json:"state"`
}

func (w *world) snapshot(u *user, limit int) *feedState {
	f := &feedState{assets: map[string]feedAsset{}}
	token := ""
	for range 1000 {
		q := url.Values{"limit": {strconv.Itoa(limit)}}
		if token != "" {
			q.Set("page_token", token)
		}
		resp, raw := w.send(w.newReq(http.MethodGet, "/api/v1/sync/snapshot?"+q.Encode(), u.devs[0].access, nil))
		if resp.StatusCode != http.StatusOK {
			w.rt.Fatalf("snapshot: %d %s", resp.StatusCode, raw)
		}
		var page struct {
			Cursor  string      `json:"cursor"`
			Assets  []wireAsset `json:"assets"`
			Next    *string     `json:"next_page_token"`
			HasMore bool        `json:"has_more"`
		}
		if err := json.Unmarshal(raw, &page); err != nil {
			w.rt.Fatal(err)
		}
		if token == "" {
			f.cursor = page.Cursor
		}
		for _, a := range page.Assets {
			if _, dup := f.assets[a.ID]; dup {
				w.rt.Errorf("snapshot: asset %s on two pages", a.ID)
			}
			f.assets[a.ID] = feedAsset{sha: a.SHA256, state: a.State}
		}
		if !page.HasMore {
			return f
		}
		if page.Next == nil || *page.Next == "" {
			w.rt.Fatalf("snapshot: has_more without next_page_token")
		}
		token = *page.Next
	}
	w.rt.Fatalf("snapshot: too many pages")
	return nil
}

// pull applies the change feed after f.cursor to f; it reports false when
// the cursor expired (410).
func (w *world) pull(u *user, f *feedState) bool {
	for range 1000 {
		q := url.Values{"cursor": {f.cursor}, "limit": {"3"}}
		resp, raw := w.send(w.newReq(http.MethodGet, "/api/v1/sync/changes?"+q.Encode(), u.devs[0].access, nil))
		if resp.StatusCode == http.StatusGone && problemCode(raw) == "cursor_expired" {
			stat("changes 410 cursor_expired")
			return false
		}
		if resp.StatusCode != http.StatusOK {
			w.rt.Fatalf("changes from %s: %d %s", f.cursor, resp.StatusCode, raw)
		}
		var page struct {
			Changes []struct {
				Seq     int64      `json:"seq"`
				Kind    string     `json:"kind"`
				Asset   *wireAsset `json:"asset"`
				AssetID string     `json:"asset_id"`
			} `json:"changes"`
			Next    string `json:"next_cursor"`
			HasMore bool   `json:"has_more"`
		}
		if err := json.Unmarshal(raw, &page); err != nil {
			w.rt.Fatal(err)
		}
		for _, c := range page.Changes {
			switch c.Kind {
			case "asset.upsert":
				if c.Asset == nil {
					w.rt.Fatalf("asset.upsert without asset: %s", raw)
				}
				f.assets[c.Asset.ID] = feedAsset{sha: c.Asset.SHA256, state: c.Asset.State}
			case "asset.removed":
				delete(f.assets, c.AssetID)
			default:
				w.rt.Errorf("change kind %q", c.Kind)
			}
		}
		f.cursor = page.Next
		if !page.HasMore {
			return true
		}
	}
	w.rt.Fatalf("changes: too many pages")
	return false
}

// assertExpired checks that a 410 for cursor is justified: compaction set
// a floor at or above it.
func (w *world) assertExpired(cursor string) {
	seq, err := service.DecodeCursor(cursor)
	if err != nil {
		w.rt.Fatalf("cursor %q: %v", cursor, err)
	}
	r := w.rowsOf(`SELECT value FROM server_state WHERE key = 'change_log_floor'`)
	if len(r) == 0 {
		w.rt.Errorf("cursor %s expired without compaction", cursor)
		return
	}
	floor, _ := strconv.ParseInt(r[0][0], 10, 64)
	if seq > floor {
		w.rt.Errorf("cursor %s (seq %d) expired above the floor %d", cursor, seq, floor)
	}
}

func (w *world) compareFeed(what string, got map[string]feedAsset, want map[string]feedAsset) {
	for id, a := range want {
		if g, ok := got[id]; !ok || g != a {
			w.rt.Errorf("%s: asset %s is %+v (present %v), database has %+v", what, id, g, ok, a)
		}
	}
	for id, g := range got {
		if _, ok := want[id]; !ok {
			w.rt.Errorf("%s: asset %s (%+v) is not the user's in the database", what, id, g)
		}
	}
}

// ---- invariants ----------------------------------------------------------

// checkInvariants runs after every step (S§11.5 1–7, plus no lost assets
// and no stray staging or temp files).
func (w *world) checkInvariants(*rapid.T) {
	w.settle()
	assets := w.assets()

	// 1. At most one asset per (owner, sha256).
	seen := map[string]string{}
	for _, a := range assets {
		k := a.owner + "|" + a.sha
		if other, dup := seen[k]; dup {
			w.rt.Errorf("inv1: assets %s and %s share (owner, sha256)", other, a.id)
		}
		seen[k] = a.id
	}

	// 2. Every asset's file exists with the right size and hash.
	lib := w.a.Config().LibraryDir
	for _, a := range assets {
		p := filepath.Join(lib, filepath.FromSlash(a.path))
		fi, err := os.Stat(p)
		if err != nil || fi.Size() != a.size {
			w.rt.Errorf("inv2: asset %s file %s: %v (size %v, want %d)", a.id, a.path, err, fi, a.size)
			continue
		}
		sig := fileSig{fi.Size(), fi.ModTime()}
		if w.hashed[a.id] == sig {
			continue
		}
		b, err := os.ReadFile(p)
		if err != nil || sha256Hex(b) != a.sha {
			w.rt.Errorf("inv2: asset %s file %s: %v, content does not hash to %s", a.id, a.path, err, a.sha)
			continue
		}
		w.hashed[a.id] = sig
	}

	// No asset is lost: one disappears only when a purge removes it from
	// the trash.
	for id, a := range w.prev {
		if _, ok := assets[id]; ok {
			continue
		}
		purging := w.action == "purge" || w.action == "emptyTrash" || w.action == "runJob:"+app.JobPurgeTrash
		if !purging || a.state != "trashed" {
			w.rt.Errorf("asset %s (%s) disappeared during %s", id, a.state, w.action)
		}
		stat("asset purged by %s", w.action)
	}

	// 3 and 6. Each user's feed (a fresh snapshot, the long-lived client
	// and every retained checkpoint replayed) is exactly the user's assets;
	// other users' assets are not visible.
	for _, u := range w.users {
		want := map[string]feedAsset{}
		for _, a := range assets {
			if a.owner == u.id {
				want[a.id] = feedAsset{sha: a.sha, state: a.state}
			}
		}
		snap := w.snapshot(u, 3)
		w.compareFeed("inv3/6 snapshot of "+u.name, snap.assets, want)
		if u.live == nil {
			u.live = snap.clone()
		} else if !w.pull(u, u.live) {
			w.assertExpired(u.live.cursor)
			u.live = snap.clone()
		}
		w.compareFeed("inv6 live feed of "+u.name, u.live.assets, want)
		kept := u.checkpoints[:0]
		for _, cp := range u.checkpoints {
			r := cp.clone()
			if !w.pull(u, r) {
				w.assertExpired(cp.cursor)
				continue
			}
			w.compareFeed("inv6 replay of "+u.name+" from "+cp.cursor, r.assets, want)
			kept = append(kept, cp)
		}
		u.checkpoints = kept
		if w.steps%3 == 0 {
			if len(u.checkpoints) >= 3 {
				u.checkpoints = u.checkpoints[1:]
			}
			u.checkpoints = append(u.checkpoints, snap)
		}
		probes := 0
		for _, a := range assets {
			if a.owner == u.id || probes == 2 {
				continue
			}
			probes++
			resp, raw := w.send(w.newReq(http.MethodGet, "/api/v1/assets/"+a.id, u.devs[0].access, nil))
			if resp.StatusCode != http.StatusNotFound {
				w.rt.Errorf("inv3: %s reads %s's asset %s: %d %s", u.name, a.owner, a.id, resp.StatusCode, raw)
			}
		}
	}

	// 4. Every done session points to an existing or purged asset.
	for _, r := range w.rowsOf(`SELECT id, COALESCE(asset_id, '') FROM upload_sessions WHERE state = 'done'`) {
		if _, ok := assets[r[1]]; !ok && !w.ever[r[1]] {
			w.rt.Errorf("inv4: done session %s points to %q, which never existed", r[0], r[1])
		}
	}

	// 5. Tombstoned content is never re-created without override: no
	// (owner, sha256) has both, and an asset that appeared over a tombstone
	// came from an override upload.
	tombs := map[string]bool{}
	for _, r := range w.rowsOf(`SELECT owner_id, sha256 FROM tombstones`) {
		tombs[r[0]+"|"+r[1]] = true
	}
	for _, a := range assets {
		k := a.owner + "|" + a.sha
		if tombs[k] {
			w.rt.Errorf("inv5: asset %s coexists with its tombstone", a.id)
		}
		if _, old := w.prev[a.id]; old || !w.prevTombs[k] {
			continue
		}
		override := false
		for _, r := range w.rowsOf(`SELECT meta_json FROM upload_sessions WHERE asset_id = ? AND asset_created = 1`, a.id) {
			var m struct {
				Override bool `json:"override_tombstone"`
			}
			_ = json.Unmarshal([]byte(r[0]), &m)
			override = override || m.Override
		}
		if !override {
			w.rt.Errorf("inv5: asset %s re-created over a tombstone without override", a.id)
		}
		stat("asset re-created over a tombstone (override)")
	}

	// 7. Offsets never decrease and never exceed the length.
	offsets := map[string]int64{}
	active := map[string]bool{}
	for _, r := range w.rowsOf(`SELECT id, "offset", length, state FROM upload_sessions`) {
		off, _ := strconv.ParseInt(r[1], 10, 64)
		n, _ := strconv.ParseInt(r[2], 10, 64)
		if off < 0 || off > n {
			w.rt.Errorf("inv7: session %s offset %d outside [0, %d]", r[0], off, n)
		}
		if prev, ok := w.offsets[r[0]]; ok && off < prev {
			w.rt.Errorf("inv7: session %s offset went back from %d to %d", r[0], prev, off)
		}
		offsets[r[0]] = off
		if r[3] == "receiving" || r[3] == "finalizing" {
			active[r[0]+".part"] = true
		}
	}

	// Staging files belong to active sessions; no finalize temp files.
	for _, f := range treeFiles(w.tb(), filepath.Join(w.a.Config().DataDir, "uploads")) {
		name, _, _ := strings.Cut(f, ":")
		if !active[name] {
			w.rt.Errorf("staging file %s without an active session", f)
		}
	}
	_ = filepath.WalkDir(lib, func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && strings.HasSuffix(p, ".ptpart") {
			w.rt.Errorf("stray %s", p)
		}
		return nil
	})

	w.prev, w.prevTombs, w.offsets = assets, tombs, offsets
	for id := range assets {
		w.ever[id] = true
	}
}
