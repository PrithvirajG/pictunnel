// Package httpapitest builds an in-process HTTP server over the production
// wiring (app.New on temp dirs, a fake clock, a fixed secret and server id)
// and validates every response against the embedded OpenAPI contract.
package httpapitest

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/app"
	"github.com/PrithvirajG/pictunnel/server/internal/clock/clocktest"
	"github.com/PrithvirajG/pictunnel/server/internal/config"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

// T0 is the fake clock's start time.
var T0 = time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)

// ServerID is the server id the test server boots with.
const ServerID = "01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f"

// Secret is the fixed 32-byte server secret.
var Secret = []byte("0123456789abcdef0123456789abcdef")

// Version is the server version reported by server info.
const Version = "0.1.0"

type options struct {
	local  bool
	tus    http.Handler
	info   func() gen.ServerInfo
	ready  func(context.Context) error
	cfg    []func(*config.Config)
	limits *httpapi.RateLimits
	free   func(string) (uint64, error)
}

// Option customises New.
type Option func(*options)

// Local builds the loopback-listener handler (setup without token, cookie
// without Secure).
func Local() Option { return func(o *options) { o.local = true } }

// WithTus mounts h on /api/v1/uploads instead of the real tus handler.
func WithTus(h http.Handler) Option { return func(o *options) { o.tus = h } }

// WithInfo replaces the server info source.
func WithInfo(f func() gen.ServerInfo) Option { return func(o *options) { o.info = f } }

// WithReady replaces the readiness check.
func WithReady(f func(context.Context) error) Option { return func(o *options) { o.ready = f } }

// WithConfig edits the configuration before the app boots.
func WithConfig(f func(*config.Config)) Option { return func(o *options) { o.cfg = append(o.cfg, f) } }

// WithLimits replaces the rate limits.
func WithLimits(l httpapi.RateLimits) Option { return func(o *options) { o.limits = &l } }

// WithFreeSpace replaces the free-space probe (default: 1 PiB free).
func WithFreeSpace(f func(string) (uint64, error)) Option { return func(o *options) { o.free = f } }

// StubHeader marks responses written by a WithTus stub, so the contract
// coverage recorder does not count them as server behaviour.
const StubHeader = "X-Httpapitest-Stub"

// App is a running test server and the services behind it.
type App struct {
	Server  *httptest.Server
	Handler http.Handler
	Clock   *clocktest.Fake
	Store   *store.Store
	Cfg     config.Config
	DataDir string
	LibDir  string
	// Core is the booted production app.
	Core *app.App

	Users   *service.UserService
	Auth    *service.AuthService
	Devices *service.DeviceService
	Pairing *service.PairingService
	Check   *service.CheckService
	Feed    *service.FeedService
	Assets  *service.AssetService
	Trash   *service.TrashService
	Upload  *service.UploadService

	client *http.Client
}

// Seed prepares dataDir so app.New boots with ServerID and Secret.
func Seed(t testing.TB, dataDir string) {
	t.Helper()
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dataDir, "secret.key"), Secret, 0o600); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(dataDir, "pictunnel.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := st.W.ExecContext(ctx, `INSERT INTO server_state(key, value) VALUES ('server_id', ?)`, ServerID); err != nil {
		t.Fatal(err)
	}
}

// New boots app.New on temp dirs and starts an httptest server over its
// handler (rebuilt from app.Deps with the options applied).
func New(t *testing.T, opts ...Option) *App {
	t.Helper()
	var o options
	for _, f := range opts {
		f(&o)
	}
	root := t.TempDir()
	a := &App{Clock: clocktest.NewFake(T0), DataDir: filepath.Join(root, "data"), LibDir: filepath.Join(root, "library")}
	for _, d := range []string{a.DataDir, a.LibDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	Seed(t, a.DataDir)
	cfg := config.Default()
	cfg.DataDir, cfg.LibraryDir = a.DataDir, a.LibDir
	cfg.Server.Name = "Test server"
	cfg.Discovery.MDNS = false
	cfg.Log.Format = "text"
	for _, f := range o.cfg {
		f(&cfg)
	}
	a.Cfg = cfg

	free := o.free
	if free == nil {
		free = func(string) (uint64, error) { return 1 << 50, nil }
	}
	core, err := app.New(context.Background(), app.Options{
		Config: cfg, Clock: a.Clock, Log: slog.New(slog.NewTextHandler(io.Discard, nil)),
		FreeSpace: free, DisableScheduler: true, Version: Version,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Close() })
	a.Core, a.Store = core, core.Store()
	a.Users, a.Auth, a.Devices, a.Pairing = core.Users(), core.Auth(), core.Devices(), core.Pairing()
	a.Check, a.Feed, a.Assets, a.Trash, a.Upload = core.Check(), core.Feed(), core.Assets(), core.Trash(), core.Upload()

	deps := core.Deps()
	if o.tus != nil {
		stub := o.tus
		deps.Tus = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set(StubHeader, "1")
			stub.ServeHTTP(w, r)
		})
	}
	if o.info != nil {
		deps.Info = o.info
	}
	if o.ready != nil {
		deps.Ready = o.ready
	}
	deps.Limits = o.limits
	a.Handler = httpapi.NewHandler(deps, o.local)
	a.Server = httptest.NewServer(a.Handler)
	t.Cleanup(a.Server.Close)
	a.client = &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	return a
}

// TusPrincipal is httpapi.TusPrincipal (kept for existing callers).
func TusPrincipal(r *http.Request) (service.Principal, error) { return httpapi.TusPrincipal(r) }

// Req builds a request to path. body may be nil, a string (sent as is) or
// any value (sent as JSON).
func (a *App) Req(t testing.TB, method, path string, body any) *http.Request {
	t.Helper()
	var r io.Reader
	isJSON := false
	switch b := body.(type) {
	case nil:
	case string:
		r, isJSON = strings.NewReader(b), true
	case []byte:
		r = bytes.NewReader(b)
	default:
		buf, err := json.Marshal(b)
		if err != nil {
			t.Fatal(err)
		}
		r, isJSON = bytes.NewReader(buf), true
	}
	req, err := http.NewRequest(method, a.Server.URL+path, r)
	if err != nil {
		t.Fatal(err)
	}
	if isJSON {
		req.Header.Set("Content-Type", "application/json")
	}
	return req
}

// Bearer sets the Authorization header.
func Bearer(req *http.Request, token string) *http.Request {
	req.Header.Set("Authorization", "Bearer "+token)
	return req
}

// Do sends req, validates the response against the contract and returns it
// with its body read.
func (a *App) Do(t testing.TB, req *http.Request) (*http.Response, []byte) {
	t.Helper()
	resp, err := a.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	resp.Body = io.NopCloser(bytes.NewReader(body))
	AssertContract(t, req, resp)
	resp.Body = io.NopCloser(bytes.NewReader(body))
	return resp, body
}

// Decode unmarshals body into out.
func Decode(t testing.TB, body []byte, out any) {
	t.Helper()
	if err := json.Unmarshal(body, out); err != nil {
		t.Fatalf("decode %s: %v", body, err)
	}
}

// Session is a logged-in device.
type Session struct {
	Access, Refresh, UserID, DeviceID string
}

// SetupAdmin creates the first admin directly through the service.
func (a *App) SetupAdmin(t testing.TB, username, password string) {
	t.Helper()
	if _, err := a.Users.Setup(context.Background(), username, password, ""); err != nil {
		t.Fatal(err)
	}
}

// CreateUser creates a regular user through the service.
func (a *App) CreateUser(t testing.TB, username, password string) {
	t.Helper()
	if _, err := a.Users.Create(context.Background(), username, password, "", service.RoleUser); err != nil {
		t.Fatal(err)
	}
}

// Login logs in through the service in tokens mode.
func (a *App) Login(t testing.TB, username, password string) Session {
	t.Helper()
	u, d, tp, err := a.Auth.Login(context.Background(), username, password,
		service.DeviceInfo{Name: "Pixel 9", Platform: "android", AppVersion: "0.1.0"})
	if err != nil {
		t.Fatal(err)
	}
	return Session{Access: tp.AccessToken, Refresh: tp.RefreshToken, UserID: u.ID, DeviceID: d.ID}
}

// Principal resolves an access token.
func (a *App) Principal(t testing.TB, access string) service.Principal {
	t.Helper()
	p, err := a.Auth.AuthenticateBearer(context.Background(), access)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// SeedAsset uploads content for the session's user through the upload
// service and returns the asset id.
func (a *App) SeedAsset(t testing.TB, s Session, content []byte, filename, mime string) string {
	t.Helper()
	sum := sha256.Sum256(content)
	v, err := a.Upload.Create(context.Background(), a.Principal(t, s.Access), service.CreateInput{
		Length: int64(len(content)),
		Meta:   service.UploadMeta{SHA256: hex.EncodeToString(sum[:]), Filename: filename, Mime: mime},
		Body:   bytes.NewReader(content),
	})
	if err != nil {
		t.Fatal(err)
	}
	if !v.Done || v.AssetID == "" {
		t.Fatalf("seed upload not finalized: %+v", v)
	}
	return v.AssetID
}

// SetThumbnails writes the derived JPEGs and marks the asset's thumbnails
// ready.
func (a *App) SetThumbnails(t testing.TB, assetID string, thumb, preview []byte) {
	t.Helper()
	dir := filepath.Join(a.DataDir, "derived", assetID[0:2], assetID[2:4], assetID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, b := range map[string][]byte{"thumb.jpg": thumb, "preview.jpg": preview} {
		if err := os.WriteFile(filepath.Join(dir, name), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := a.Store.W.ExecContext(context.Background(),
		`UPDATE assets SET thumbnails_ready = 1 WHERE id = ?`, assetID); err != nil {
		t.Fatal(err)
	}
}

// SetPlayable records whether a video's original is browser-playable.
func (a *App) SetPlayable(t testing.TB, assetID string, playable bool) {
	t.Helper()
	v := 0
	if playable {
		v = 1
	}
	if _, err := a.Store.W.ExecContext(context.Background(),
		`UPDATE assets SET playable = ? WHERE id = ?`, v, assetID); err != nil {
		t.Fatal(err)
	}
}
