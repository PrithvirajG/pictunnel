package app_test

// Crash-test harness (S§11.4): the TestMain re-exec mode that turns the test
// binary into a child server, the failpoints, a minimal sync client that
// runs the convergence loop over HTTPS, and the post-crash assertions.

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/app"
	"github.com/PrithvirajG/pictunnel/server/internal/config"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/httpapitest"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
	"github.com/PrithvirajG/pictunnel/server/internal/storage/storagetest"
)

// Environment of a crash child (test binary only).
const (
	envCrashChild = "PICTUNNEL_CRASH_CHILD" // "1" selects child mode
	envCrashData  = "PICTUNNEL_CRASH_DATA_DIR"
	envCrashLib   = "PICTUNNEL_CRASH_LIBRARY_DIR"
	envCrashFP    = "PICTUNNEL_CRASH_FAILPOINT" // "" = no failpoint
	envCrashHit   = "PICTUNNEL_CRASH_HIT"       // which hit of the failpoint exits (1-based)
	envCrashCross = "PICTUNNEL_CRASH_CROSS"     // "1" = staging→library renames fail with EXDEV

	// crashExitCode is what a killed child exits with (128+SIGKILL).
	crashExitCode = 137
	// listenPrefix starts the line a child prints once it serves.
	listenPrefix = "LISTEN "
)

func TestMain(m *testing.M) {
	if os.Getenv(envCrashChild) == "1" {
		os.Exit(crashChild())
	}
	os.Exit(m.Run())
}

// crashChild serves the app on random loopback ports until stdin closes,
// printing "LISTEN <https addr>" once bound. An armed failpoint exits the
// process with 137 at its configured hit: no defer, cleanup or in-memory
// state survives.
func crashChild() int {
	hit, _ := strconv.Atoi(os.Getenv(envCrashHit))
	o := crashOptions(os.Getenv(envCrashData), os.Getenv(envCrashLib), os.Getenv(envCrashCross) == "1")
	o.Log = slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	if fp := os.Getenv(envCrashFP); fp != "" {
		o.Failpoints = &tripAt{name: fp, hit: max(hit, 1), trip: func() error {
			fmt.Fprintf(os.Stderr, "crash child: failpoint %s hit, exiting %d\n", fp, crashExitCode)
			os.Exit(crashExitCode)
			return nil
		}}
	}
	o.Listening = func(httpsAddr, _ string) { fmt.Printf("%s%s\n", listenPrefix, httpsAddr) }
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()
	go func() { // the parent stops a healthy child by closing stdin
		_, _ = io.Copy(io.Discard, os.Stdin)
		cancel()
	}()
	a, err := app.New(ctx, o)
	if err != nil {
		fmt.Fprintln(os.Stderr, "crash child: boot:", err)
		return 1
	}
	defer a.Close()
	if err := a.Run(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "crash child: run:", err)
		return 1
	}
	return 0
}

// crashOptions boots on dataDir/libDir with mDNS and the scheduler off,
// loopback listeners on random ports, plenty of free space, and, when cross
// is set, a filesystem on which the staging→library rename crosses volumes.
func crashOptions(dataDir, libDir string, cross bool) app.Options {
	cfg := config.Default()
	cfg.DataDir, cfg.LibraryDir = dataDir, libDir
	cfg.Server.Name = "Crash server"
	cfg.Server.HTTPSAddr = "127.0.0.1:0"
	cfg.Server.LocalAddr = "127.0.0.1:0"
	cfg.Discovery.MDNS = false
	cfg.Media.Workers = 1
	o := app.Options{
		Config: cfg, DisableScheduler: true,
		Log:       slog.New(slog.NewTextHandler(io.Discard, nil)),
		FreeSpace: func(string) (uint64, error) { return 1 << 40, nil },
	}
	if cross {
		o.FS = exdevFS()
	}
	return o
}

// exdevFS fails every rename of a staging file (*.part) with EXDEV, so
// storage.Commit takes the cross-volume copy path.
func exdevFS() storage.FS {
	return &storagetest.FaultFS{FS: storage.OS(), RenameErr: func(from, to string) error {
		if filepath.Ext(from) == ".part" {
			return &os.LinkError{Op: "rename", Old: from, New: to, Err: syscall.EXDEV}
		}
		return nil
	}}
}

// errCrash is what an in-process failpoint aborts with.
var errCrash = errors.New("crash")

// tripAt fails at the hit-th time name is reached (1-based), once.
type tripAt struct {
	name    string
	hit     int
	trip    func() error // nil: return errCrash
	n       atomic.Int32
	tripped atomic.Bool
}

func (f *tripAt) Hit(name string) error {
	if name != f.name || int(f.n.Add(1)) != f.hit {
		return nil
	}
	f.tripped.Store(true)
	if f.trip != nil {
		return f.trip()
	}
	return errCrash
}

// failpointHit is which hit of a failpoint crashes: the append points trip
// on the second PATCH (so a committed prefix exists), the finalize points
// on their only hit.
func failpointHit(fp string) int {
	if fp == service.FPAppendAfterFsync || fp == service.FPAppendBeforeCommit {
		return 2
	}
	return 1
}

// ---- payload and client --------------------------------------------------

const (
	crashPayloadSize = 1 << 20
	crashUser        = "alice"
	crashLocalID     = "LOCAL-0001"
	crashFilename    = "IMG_0001.JPG"
	crashCreatedAt   = "2024-05-06T07:08:09Z"
	crashDestPath    = "alice/2024/05/IMG_0001.JPG"
)

// crashPayload is payload A: 1 MiB of deterministic bytes.
func crashPayload() []byte {
	b := make([]byte, crashPayloadSize)
	x := uint32(0x9e3779b9)
	for i := range b {
		x ^= x << 13
		x ^= x >> 17
		x ^= x << 5
		b[i] = byte(x)
	}
	return b
}

func sha256Hex(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// seedUser creates the user and logs a device in through the services,
// returning its access token.
func seedUser(t *testing.T, a *app.App) string {
	t.Helper()
	ctx := context.Background()
	if _, err := a.Users().Create(ctx, crashUser, pw, "", service.RoleUser); err != nil {
		t.Fatal(err)
	}
	_, _, tp, err := a.Auth().Login(ctx, crashUser, pw, service.DeviceInfo{Name: "Pixel", Platform: "android", AppVersion: "0.1.0"})
	if err != nil {
		t.Fatal(err)
	}
	return tp.AccessToken
}

// syncClient is a minimal sync client over HTTPS trusting the app's CA.
type syncClient struct {
	t       *testing.T
	base    string // https://host:port
	access  string
	http    *http.Client
	content []byte
	sha     string
}

func newSyncClient(t *testing.T, base string, caPEM []byte, access string, content []byte) *syncClient {
	t.Helper()
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		t.Fatal("app CA PEM unusable")
	}
	return &syncClient{
		t: t, base: base, access: access, content: content, sha: sha256Hex(content),
		http: &http.Client{
			Transport: &http.Transport{
				TLSClientConfig:    &tls.Config{RootCAs: pool, NextProtos: []string{"http/1.1"}},
				DisableCompression: true,
			},
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
			Timeout:       time.Minute,
		},
	}
}

func (c *syncClient) close() { c.http.CloseIdleConnections() }

func (c *syncClient) req(method, path string, body []byte) *http.Request {
	c.t.Helper()
	var r io.Reader
	if body != nil {
		r = bytes.NewReader(body)
	}
	req, err := http.NewRequest(method, c.base+path, r)
	if err != nil {
		c.t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+c.access)
	return req
}

func (c *syncClient) tusReq(method, path string, body []byte) *http.Request {
	req := c.req(method, path, body)
	req.Header.Set("Tus-Resumable", "1.0.0")
	if method == http.MethodPatch {
		req.Header.Set("Content-Type", "application/offset+octet-stream")
		req.ContentLength = int64(len(body))
	}
	return req
}

// send performs req; with validate the response is checked against the
// contract. A transport error (the server died mid-request) is returned.
func (c *syncClient) send(req *http.Request, validate bool) (*http.Response, []byte, error) {
	c.t.Helper()
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, nil, err
	}
	raw, err := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if err != nil {
		return nil, nil, err
	}
	if validate {
		resp.Body = io.NopCloser(bytes.NewReader(raw))
		httpapitest.AssertContract(c.t, req, resp)
	}
	resp.Body = io.NopCloser(bytes.NewReader(raw))
	return resp, raw, nil
}

// mustSend is send for requests that must get a response.
func (c *syncClient) mustSend(req *http.Request) (*http.Response, []byte) {
	c.t.Helper()
	resp, raw, err := c.send(req, true)
	if err != nil {
		c.t.Fatalf("%s %s: %v", req.Method, req.URL.Path, err)
	}
	return resp, raw
}

func (c *syncClient) metadata() string {
	kv := [][2]string{
		{"sha256", c.sha}, {"filename", crashFilename}, {"mime", "image/jpeg"},
		{"local_id", crashLocalID}, {"created_at", crashCreatedAt},
	}
	parts := make([]string, len(kv))
	for i, p := range kv {
		parts[i] = p[0] + " " + base64.StdEncoding.EncodeToString([]byte(p[1]))
	}
	return strings.Join(parts, ",")
}

// create is POST /api/v1/uploads without a body; it returns the upload
// path and its current offset.
func (c *syncClient) create(validate bool) (string, int64, error) {
	c.t.Helper()
	req := c.tusReq(http.MethodPost, "/api/v1/uploads", nil)
	req.Header.Set("Upload-Length", strconv.Itoa(len(c.content)))
	req.Header.Set("Upload-Metadata", c.metadata())
	resp, raw, err := c.send(req, validate)
	if err != nil {
		return "", 0, err
	}
	if resp.StatusCode != http.StatusCreated {
		return "", 0, fmt.Errorf("POST: status %d: %s", resp.StatusCode, raw)
	}
	off, _ := strconv.ParseInt(resp.Header.Get("Upload-Offset"), 10, 64)
	return resp.Header.Get("Location"), off, nil
}

// patch sends content[from:to] at offset from; it returns the response.
func (c *syncClient) patch(loc string, from, to int64, validate bool) (*http.Response, []byte, error) {
	c.t.Helper()
	req := c.tusReq(http.MethodPatch, loc, c.content[from:to])
	req.Header.Set("Upload-Offset", strconv.FormatInt(from, 10))
	return c.send(req, validate)
}

// crashUpload is the first attempt: POST, then two PATCH halves. It stops
// at the first failure and returns it (the failpoint is expected to abort
// the attempt with a 500 or a dropped connection).
func (c *syncClient) crashUpload() error {
	c.t.Helper()
	loc, _, err := c.create(false)
	if err != nil {
		return err
	}
	half := int64(len(c.content) / 2)
	for _, r := range [][2]int64{{0, half}, {half, int64(len(c.content))}} {
		resp, raw, err := c.patch(loc, r[0], r[1], false)
		if err != nil {
			return err
		}
		if resp.StatusCode != http.StatusNoContent {
			return fmt.Errorf("PATCH [%d,%d): status %d: %s", r[0], r[1], resp.StatusCode, raw)
		}
	}
	return nil
}

type checkResult struct {
	Verdict string `json:"verdict"`
	AssetID string `json:"asset_id"`
	Upload  *struct {
		URL    string `json:"url"`
		Offset int64  `json:"offset"`
		Length int64  `json:"length"`
	} `json:"upload"`
}

func (c *syncClient) check() checkResult {
	c.t.Helper()
	body, _ := json.Marshal(map[string]any{"items": []map[string]any{
		{"sha256": c.sha, "size_bytes": len(c.content), "local_id": crashLocalID},
	}})
	req := c.req(http.MethodPost, "/api/v1/sync/check", body)
	req.Header.Set("Content-Type", "application/json")
	resp, raw := c.mustSend(req)
	if resp.StatusCode != http.StatusOK {
		c.t.Fatalf("check: status %d: %s", resp.StatusCode, raw)
	}
	var out struct {
		Results []checkResult `json:"results"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || len(out.Results) != 1 {
		c.t.Fatalf("check: %v: %s", err, raw)
	}
	return out.Results[0]
}

// converge runs the client retry loop (check → HEAD/POST → PATCH the
// remaining bytes) until check says exists; it returns the asset id.
func (c *syncClient) converge() string {
	t := c.t
	t.Helper()
	var trail []string
	for range 6 {
		res := c.check()
		trail = append(trail, "check:"+res.Verdict)
		var loc string
		var offset int64
		switch res.Verdict {
		case "exists":
			if res.AssetID == "" {
				t.Fatal("exists without asset_id")
			}
			t.Logf("converged: %s", strings.Join(trail, " → "))
			return res.AssetID
		case "partial":
			loc = res.Upload.URL
			resp, raw := c.mustSend(c.tusReq(http.MethodHead, loc, nil))
			trail = append(trail, "HEAD:"+strconv.Itoa(resp.StatusCode))
			switch {
			case resp.StatusCode == http.StatusNotFound:
				loc = "" // gone: restart with POST
			case resp.StatusCode != http.StatusOK:
				t.Fatalf("HEAD %s: status %d: %s (trail %v)", loc, resp.StatusCode, raw, trail)
			case resp.Header.Get("PicTunnel-Asset-Id") != "":
				continue // finalized by HEAD; the next check says exists
			default:
				offset, _ = strconv.ParseInt(resp.Header.Get("Upload-Offset"), 10, 64)
			}
		case "missing":
		default:
			t.Fatalf("check verdict %q (trail %v)", res.Verdict, trail)
		}
		if loc == "" {
			var err error
			if loc, offset, err = c.create(true); err != nil {
				t.Fatalf("%v (trail %v)", err, trail)
			}
			trail = append(trail, "POST")
		}
		resp, raw := c.mustSendPatch(loc, offset)
		trail = append(trail, "PATCH:"+strconv.Itoa(resp.StatusCode))
		if resp.StatusCode != http.StatusNoContent || resp.Header.Get("PicTunnel-Asset-Id") == "" {
			t.Fatalf("PATCH %s from %d: status %d asset %q: %s (trail %v)", loc, offset, resp.StatusCode,
				resp.Header.Get("PicTunnel-Asset-Id"), raw, trail)
		}
	}
	t.Fatalf("no convergence (trail %v)", trail)
	return ""
}

func (c *syncClient) mustSendPatch(loc string, offset int64) (*http.Response, []byte) {
	c.t.Helper()
	resp, raw, err := c.patch(loc, offset, int64(len(c.content)), true)
	if err != nil {
		c.t.Fatalf("PATCH %s: %v", loc, err)
	}
	return resp, raw
}

// ---- assertions ----------------------------------------------------------

func queryStrings(t *testing.T, a *app.App, q string, args ...any) []string {
	t.Helper()
	rows, err := a.Store().R.Query(q, args...)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	cols, _ := rows.Columns()
	var out []string
	for rows.Next() {
		vals := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range vals {
			ptrs[i] = &vals[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			t.Fatal(err)
		}
		parts := make([]string, len(vals))
		for i, v := range vals {
			if b, ok := v.([]byte); ok {
				v = string(b)
			}
			parts[i] = fmt.Sprint(v)
		}
		out = append(out, strings.Join(parts, "|"))
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// treeFiles lists the files under root as slash paths relative to root
// with their sizes, sorted.
func treeFiles(t *testing.T, root string) []string {
	t.Helper()
	var out []string
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if os.IsNotExist(err) && p == root {
				return filepath.SkipDir
			}
			return err
		}
		if d.IsDir() {
			return nil
		}
		fi, err := d.Info()
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		out = append(out, fmt.Sprintf("%s:%d", filepath.ToSlash(rel), fi.Size()))
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(out)
	return out
}

// recoveryState is everything recovery may touch: sessions, assets,
// reservations, sources, change log, jobs, staging and library files.
func recoveryState(t *testing.T, a *app.App) string {
	t.Helper()
	cfg := a.Config()
	var b strings.Builder
	for _, q := range []string{
		`SELECT id, state, "offset", length, dest_path, asset_id, asset_created, failure_code FROM upload_sessions ORDER BY id`,
		`SELECT id, sha256, size_bytes, original_path FROM assets ORDER BY id`,
		`SELECT path_key, path, upload_id, asset_id FROM library_paths ORDER BY path_key`,
		`SELECT device_id, local_id, asset_id FROM asset_sources ORDER BY device_id, local_id`,
		`SELECT COUNT(*) FROM change_log`,
		`SELECT kind, dedupe_key, state FROM jobs ORDER BY kind, dedupe_key, state`,
	} {
		fmt.Fprintf(&b, "%s\n  %s\n", q, strings.Join(queryStrings(t, a, q), "\n  "))
	}
	fmt.Fprintf(&b, "uploads/ %v\nlibrary %v\n",
		treeFiles(t, filepath.Join(cfg.DataDir, "uploads")), treeFiles(t, cfg.LibraryDir))
	return b.String()
}

// assertConverged checks the S§11.4 outcome on a booted app: exactly one
// asset with the right bytes and hash at the expected path, no session
// left receiving or finalizing, no staging file, no *.ptpart, every
// reservation owned (and one pointing at the asset), the asset_sources
// link, and the tx2 side effects exactly once.
//
// With strictJobs every media job is still pending and must exist exactly
// once; a child that ran its job runner may have finished (and a later boot
// re-enqueued) them, so then only "at least one, at most one active" holds.
func assertConverged(t *testing.T, a *app.App, assetID string, content []byte, strictJobs bool) {
	t.Helper()
	cfg := a.Config()
	sha := sha256Hex(content)
	assets := queryStrings(t, a, `SELECT id, sha256, size_bytes, original_path FROM assets`)
	want := fmt.Sprintf("%s|%s|%d|%s", assetID, sha, len(content), crashDestPath)
	if len(assets) != 1 || assets[0] != want {
		t.Fatalf("assets %v, want [%s]", assets, want)
	}
	got, err := os.ReadFile(filepath.Join(cfg.LibraryDir, filepath.FromSlash(crashDestPath)))
	if err != nil || !bytes.Equal(got, content) || sha256Hex(got) != sha {
		t.Fatalf("library file: err %v, %d bytes, equal %v", err, len(got), bytes.Equal(got, content))
	}
	if lib := treeFiles(t, cfg.LibraryDir); len(lib) != 1 || lib[0] != fmt.Sprintf("%s:%d", crashDestPath, len(content)) {
		t.Fatalf("library files %v", lib)
	}
	if s := queryStrings(t, a, `SELECT id, state FROM upload_sessions WHERE state IN ('receiving', 'finalizing')`); len(s) != 0 {
		t.Fatalf("active sessions left: %v", s)
	}
	if s := queryStrings(t, a, `SELECT id FROM upload_sessions WHERE state = 'done' AND asset_id = ?`, assetID); len(s) == 0 {
		t.Fatal("no done session points at the asset")
	}
	if left := treeFiles(t, filepath.Join(cfg.DataDir, "uploads")); len(left) != 0 {
		t.Fatalf("staging files left: %v", left)
	}
	for _, root := range []string{cfg.DataDir, cfg.LibraryDir} {
		_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
			if err == nil && !d.IsDir() && strings.HasSuffix(p, ".ptpart") {
				t.Errorf("stray %s", p)
			}
			return nil
		})
	}
	unowned := queryStrings(t, a, `
		SELECT lp.path FROM library_paths lp
		WHERE NOT EXISTS (SELECT 1 FROM assets x WHERE x.id = lp.asset_id)
		  AND NOT EXISTS (SELECT 1 FROM upload_sessions s WHERE s.id = lp.upload_id AND s.state IN ('receiving', 'finalizing'))`)
	if len(unowned) != 0 {
		t.Fatalf("unowned reservations: %v", unowned)
	}
	if res := queryStrings(t, a, `SELECT path FROM library_paths WHERE asset_id = ?`, assetID); len(res) != 1 || res[0] != crashDestPath {
		t.Fatalf("asset reservation %v", res)
	}
	if src := queryStrings(t, a, `SELECT local_id, asset_id FROM asset_sources`); len(src) != 1 || src[0] != crashLocalID+"|"+assetID {
		t.Fatalf("asset_sources %v", src)
	}
	for _, kind := range []string{service.JobExtractMetadata, service.JobGenerateThumbnails} {
		all := count(t, a, `SELECT COUNT(*) FROM jobs WHERE kind = ? AND dedupe_key = ?`, kind, assetID)
		active := count(t, a, `SELECT COUNT(*) FROM jobs WHERE kind = ? AND dedupe_key = ? AND state IN ('pending', 'running')`, kind, assetID)
		if (strictJobs && (all != 1 || active != 1)) || all < 1 || active > 1 {
			t.Fatalf("%s jobs for the asset: %d (%d active)", kind, all, active)
		}
	}
	if n := count(t, a, `SELECT COUNT(*) FROM change_log`); n != 1 {
		t.Fatalf("change_log entries: %d", n)
	}
}

// ---- child process -------------------------------------------------------

// crashProc is a running crash child.
type crashProc struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	addr   string
	stderr *lockedBuffer
	done   chan struct{}
	err    error // Wait's result, valid once done is closed
}

type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// startChild re-executes the test binary as a child server on dataDir and
// libDir, armed with fp (or none), and waits until it listens.
func startChild(t *testing.T, dataDir, libDir, fp string, cross bool) *crashProc {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(exe, "-test.run=^$")
	cmd.Env = append(os.Environ(),
		envCrashChild+"=1", envCrashData+"="+dataDir, envCrashLib+"="+libDir,
		envCrashFP+"="+fp, envCrashHit+"="+strconv.Itoa(failpointHit(fp)),
		envCrashCross+"="+map[bool]string{true: "1", false: "0"}[cross])
	p := &crashProc{cmd: cmd, stderr: &lockedBuffer{}, done: make(chan struct{})}
	cmd.Stderr = p.stderr
	if p.stdin, err = cmd.StdinPipe(); err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	addr := make(chan string, 1)
	go func() {
		sc := bufio.NewScanner(stdout)
		for sc.Scan() {
			if a, ok := strings.CutPrefix(sc.Text(), listenPrefix); ok {
				addr <- a
			}
		}
	}()
	go func() {
		p.err = cmd.Wait()
		close(p.done)
	}()
	t.Cleanup(func() {
		select {
		case <-p.done:
		default:
			_ = cmd.Process.Kill()
			<-p.done
		}
	})
	select {
	case p.addr = <-addr:
	case <-p.done:
		t.Fatalf("child exited before listening: %v\n%s", p.err, p.stderr)
	case <-time.After(30 * time.Second):
		t.Fatalf("child not listening\n%s", p.stderr)
	}
	return p
}

// wait waits for the child to exit and returns its exit code.
func (p *crashProc) wait(t *testing.T) int {
	t.Helper()
	select {
	case <-p.done:
	case <-time.After(30 * time.Second):
		t.Fatalf("child did not exit\n%s", p.stderr)
	}
	return p.cmd.ProcessState.ExitCode()
}

// stop shuts a healthy child down by closing its stdin and asserts a
// clean exit.
func (p *crashProc) stop(t *testing.T) {
	t.Helper()
	_ = p.stdin.Close()
	if code := p.wait(t); code != 0 {
		t.Fatalf("child exit code %d: %v\n%s", code, p.err, p.stderr)
	}
}
