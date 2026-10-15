// Package httpapitest builds an in-process HTTP server over the real
// services (temp dirs, a fake clock, a fixed secret) and validates every
// response against the embedded OpenAPI contract.
//
// Task 15 switches the wiring to app.New; the helpers stay the same.
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

	"github.com/google/uuid"

	"github.com/PrithvirajG/pictunnel/server/internal/clock/clocktest"
	"github.com/PrithvirajG/pictunnel/server/internal/config"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
	"github.com/PrithvirajG/pictunnel/server/internal/jobs"
	"github.com/PrithvirajG/pictunnel/server/internal/media/probe"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

// T0 is the fake clock's start time.
var T0 = time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)

// ServerID is the server id reported by the default server info.
const ServerID = "01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f"

// Secret is the fixed 32-byte server secret.
var Secret = []byte("0123456789abcdef0123456789abcdef")

type options struct {
	local  bool
	tus    http.Handler
	info   func() gen.ServerInfo
	ready  func(context.Context) error
	cfg    []func(*config.Config)
	limits *httpapi.RateLimits
}

// Option customises New.
type Option func(*options)

// Local builds the loopback-listener handler (setup without token, cookie
// without Secure).
func Local() Option { return func(o *options) { o.local = true } }

// WithTus mounts h on /api/v1/uploads.
func WithTus(h http.Handler) Option { return func(o *options) { o.tus = h } }

// WithInfo replaces the server info source.
func WithInfo(f func() gen.ServerInfo) Option { return func(o *options) { o.info = f } }

// WithReady replaces the readiness check.
func WithReady(f func(context.Context) error) Option { return func(o *options) { o.ready = f } }

// WithConfig edits the configuration before the handler is built.
func WithConfig(f func(*config.Config)) Option { return func(o *options) { o.cfg = append(o.cfg, f) } }

// WithLimits replaces the rate limits.
func WithLimits(l httpapi.RateLimits) Option { return func(o *options) { o.limits = &l } }

// App is a running test server and the services behind it.
type App struct {
	Server  *httptest.Server
	Handler http.Handler
	Clock   *clocktest.Fake
	Store   *store.Store
	Cfg     config.Config
	DataDir string
	LibDir  string

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

// New wires the services on temp dirs and starts an httptest server.
func New(t *testing.T, opts ...Option) *App {
	t.Helper()
	var o options
	for _, f := range opts {
		f(&o)
	}
	root := t.TempDir()
	a := &App{Store: repotest.NewStore(t), Clock: clocktest.NewFake(T0),
		DataDir: filepath.Join(root, "data"), LibDir: filepath.Join(root, "library")}
	for _, d := range []string{a.DataDir, a.LibDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	cfg := config.Default()
	cfg.DataDir, cfg.LibraryDir = a.DataDir, a.LibDir
	cfg.Server.Name = "Test server"
	cfg.Log.Format = "text"
	for _, f := range o.cfg {
		f(&cfg)
	}
	a.Cfg = cfg

	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	st, clk, fs := a.Store, a.Clock, storage.OS()
	var err error
	a.Auth, err = service.NewAuthService(service.AuthServiceDeps{
		Store: st, Users: repository.UsersRepository{}, Devices: repository.DevicesRepository{},
		AccessTokens: repository.AccessTokensRepository{}, RefreshTokens: repository.RefreshTokensRepository{},
		WebSessions: repository.WebSessionsRepository{}, Audit: repository.AuditLogRepository{},
		Clock: clk, Secret: Secret,
	})
	if err != nil {
		t.Fatal(err)
	}
	a.Users = service.NewUserService(service.UserServiceDeps{
		Store: st, Users: repository.UsersRepository{}, ServerState: repository.ServerStateRepository{},
		Devices: repository.DevicesRepository{}, Audit: repository.AuditLogRepository{}, Auth: a.Auth, Clock: clk,
	})
	a.Devices = service.NewDeviceService(service.DeviceServiceDeps{
		Store: st, Devices: repository.DevicesRepository{}, Auth: a.Auth, Clock: clk,
	})
	a.Pairing, err = service.NewPairingService(service.PairingServiceDeps{
		Store: st, PairingCodes: repository.PairingCodesRepository{}, Devices: repository.DevicesRepository{},
		Users: repository.UsersRepository{}, Audit: repository.AuditLogRepository{}, Auth: a.Auth, Clock: clk,
		ServerID: ServerID, Fingerprint: "xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc",
		Endpoints: func() []string { return []string{"https://192.168.1.20:8443"} }, Secret: Secret,
	})
	if err != nil {
		t.Fatal(err)
	}
	runner := jobs.New(st, repository.JobsRepository{}, clk, log)
	a.Check = service.NewCheckService(service.CheckServiceDeps{
		Store: st, Assets: repository.AssetsRepository{}, LiveVideos: repository.LiveVideosRepository{},
		UploadSessions: repository.UploadSessionsRepository{}, Tombstones: repository.TombstonesRepository{},
		AssetSources: repository.AssetSourcesRepository{}, FS: fs, Clock: clk, LibraryDir: a.LibDir,
	})
	a.Feed = service.NewFeedService(service.FeedServiceDeps{
		Store: st, Assets: repository.AssetsRepository{}, LiveVideos: repository.LiveVideosRepository{},
		ChangeLog: repository.ChangeLogRepository{}, ServerState: repository.ServerStateRepository{},
	})
	a.Assets = service.NewAssetService(service.AssetServiceDeps{
		Store: st, Assets: repository.AssetsRepository{}, LiveVideos: repository.LiveVideosRepository{},
		FS: fs, LibraryDir: a.LibDir, DataDir: a.DataDir,
	})
	a.Trash = service.NewTrashService(service.TrashServiceDeps{
		Store: st, Assets: repository.AssetsRepository{}, LiveVideos: repository.LiveVideosRepository{},
		Tombstones: repository.TombstonesRepository{}, ChangeLog: repository.ChangeLogRepository{},
		LibraryPaths: repository.LibraryPathsRepository{}, Jobs: runner, FS: fs, Clock: clk,
		LibraryDir: a.LibDir, DataDir: a.DataDir, RetentionDays: cfg.Trash.RetentionDays, Log: log,
	})
	lib := service.NewLibraryService(service.LibraryServiceDeps{
		LibraryPaths: repository.LibraryPathsRepository{}, FS: fs, Clock: clk, LibraryDir: a.LibDir,
	})
	fin := service.NewFinalizeService(service.FinalizeServiceDeps{
		Store: st, Users: repository.UsersRepository{}, Assets: repository.AssetsRepository{},
		LiveVideos: repository.LiveVideosRepository{}, LibraryPaths: repository.LibraryPathsRepository{},
		AssetSources: repository.AssetSourcesRepository{}, UploadSessions: repository.UploadSessionsRepository{},
		Tombstones: repository.TombstonesRepository{}, ChangeLog: repository.ChangeLogRepository{},
		Jobs: runner, Library: lib, FS: fs, Clock: clk, Probe: probe.FastDate,
		DataDir: a.DataDir, LibraryDir: a.LibDir, Log: log,
	})
	a.Upload = service.NewUploadService(service.UploadServiceDeps{
		Store: st, Sessions: repository.UploadSessionsRepository{}, Assets: repository.AssetsRepository{},
		LiveVideos: repository.LiveVideosRepository{}, Tombstones: repository.TombstonesRepository{},
		Users: repository.UsersRepository{}, AssetSources: repository.AssetSourcesRepository{},
		Finalize: fin, FS: fs, FreeSpace: func(string) (uint64, error) { return 1 << 50, nil }, Clock: clk,
		Cfg:     service.UploadConfig{MaxFileBytes: cfg.Upload.MaxFileBytes, ReserveBytes: cfg.Storage.ReserveBytes},
		DataDir: a.DataDir, LibraryDir: a.LibDir, Log: log,
	})

	info := o.info
	if info == nil {
		info = func() gen.ServerInfo {
			return gen.ServerInfo{
				ServerId: uuid.MustParse(ServerID), Name: cfg.Server.Name, Version: "0.1.0", ApiVersion: "1.0",
				MinClientVersion: gen.ClientVersions{
					Android: cfg.Clients.MinVersion["android"], Ios: cfg.Clients.MinVersion["ios"], Web: cfg.Clients.MinVersion["web"],
				},
				Capabilities: []string{"tus"},
				Upload: gen.UploadLimits{TusVersion: "1.0.0", MaxFileBytes: cfg.Upload.MaxFileBytes,
					RecommendedChunkBytes: cfg.Upload.RecommendedChunkBytes},
			}
		}
	}
	a.Handler = httpapi.NewHandler(httpapi.Deps{
		Users: a.Users, Auth: a.Auth, Devices: a.Devices, Pairing: a.Pairing, Check: a.Check, Feed: a.Feed,
		Assets: a.Assets, Trash: a.Trash, Tus: o.tus, Info: info, Ready: o.ready, Cfg: cfg, Clock: clk,
		Log: log, Limits: o.limits,
	}, o.local)
	a.Server = httptest.NewServer(a.Handler)
	t.Cleanup(a.Server.Close)
	a.client = &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	return a
}

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
