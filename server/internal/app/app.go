// Package app is the production wiring: boot sequence (S§10.1), services,
// job runner, HTTP handlers, listeners (S§5.2) and mDNS (S§5.3).
package app

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/clock"
	"github.com/PrithvirajG/pictunnel/server/internal/config"
	"github.com/PrithvirajG/pictunnel/server/internal/discovery"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/tus"
	"github.com/PrithvirajG/pictunnel/server/internal/jobs"
	"github.com/PrithvirajG/pictunnel/server/internal/media"
	"github.com/PrithvirajG/pictunnel/server/internal/media/probe"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
	"github.com/PrithvirajG/pictunnel/server/internal/tlsutil"
)

// Job kinds run by the periodic scheduler (S§9).
const (
	JobExpireUploads    = "expire_uploads"
	JobExpireTokens     = "expire_tokens"
	JobPurgeTrash       = "purge_trash"
	JobCompactChangeLog = "compact_change_log"
	JobBackupDatabase   = "backup_database"
)

const (
	// APIVersion is reported by server info.
	APIVersion = "1.0"
	// shutdownGrace bounds the HTTP drain and the job runner stop.
	shutdownGrace     = 30 * time.Second
	readHeaderTimeout = 10 * time.Second
	idleTimeout       = 120 * time.Second
)

// Periodic is the S§9 schedule.
var Periodic = []jobs.Periodic{
	{Kind: JobExpireUploads, Every: 15 * time.Minute},
	{Kind: JobExpireTokens, Every: time.Hour},
	{Kind: JobPurgeTrash, Every: 24 * time.Hour},
	{Kind: JobCompactChangeLog, Every: 24 * time.Hour},
	{Kind: JobBackupDatabase, Every: 24 * time.Hour},
}

var mediaKinds = []string{service.JobExtractMetadata, service.JobGenerateThumbnails, service.JobTranscodeVideo}

// Options configure New. Zero values select production defaults: the real
// clock, the OS filesystem, real free-space probing and slog.Default.
type Options struct {
	Config     config.Config
	Clock      clock.Clock
	Failpoints service.Failpoints
	FreeSpace  storage.FreeSpaceFunc
	FS         storage.FS
	Log        *slog.Logger
	// DisableScheduler keeps Run from starting the periodic scheduler;
	// Jobs().RunNow still treats the periodic kinds as periodic.
	DisableScheduler bool
	// Version is the server version (server info, mDNS TXT); default "dev".
	Version string
	// Listening, if set, is called by Run once both listeners are bound,
	// with their actual addresses (the HTTPS one is plain HTTP when
	// tls.mode=off).
	Listening func(httpsAddr, localAddr string)
}

// App is a booted server.
type App struct {
	o   Options
	cfg config.Config
	clk clock.Clock
	log *slog.Logger
	fs  storage.FS

	lock       *os.File
	st         *store.Store
	secret     []byte
	serverID   string
	tlsMat     *tlsutil.Material
	setupToken string
	httpsPort  atomic.Int32
	draining   atomic.Bool

	runner   *jobs.Runner
	users    *service.UserService
	auth     *service.AuthService
	devices  *service.DeviceService
	pairing  *service.PairingService
	check    *service.CheckService
	feed     *service.FeedService
	assets   *service.AssetService
	trash    *service.TrashService
	upload   *service.UploadService
	finalize *service.FinalizeService
	media    *service.MediaService
	maint    *service.MaintenanceService

	deps         httpapi.Deps
	handler      http.Handler
	localHandler http.Handler

	closeOnce sync.Once
	closeErr  error
}

// New runs boot steps 1–6 of S§10.1: lock the data dir, open and check the
// database, back up and migrate, load or create secret.key, server_id and
// the TLS material, wire the services, register every job handler, run
// finalize recovery, re-enqueue missing media jobs and rotate the setup
// token. It opens no listener; Run does.
func New(ctx context.Context, o Options) (*App, error) {
	cfg := o.Config
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if o.Clock == nil {
		o.Clock = clock.Real{}
	}
	if o.FS == nil {
		o.FS = storage.OS()
	}
	if o.FreeSpace == nil {
		o.FreeSpace = storage.FreeSpace
	}
	if o.Log == nil {
		o.Log = slog.Default()
	}
	if o.Version == "" {
		o.Version = "dev"
	}
	a := &App{o: o, cfg: cfg, clk: o.Clock, log: o.Log, fs: o.FS}
	ok := false
	defer func() {
		if !ok {
			_ = a.Close()
		}
	}()

	if err := os.MkdirAll(cfg.DataDir, 0o700); err != nil {
		return nil, fmt.Errorf("create data dir: %w", err)
	}
	var err error
	if a.lock, err = acquireLock(cfg.DataDir); err != nil {
		return nil, err
	}
	if err := a.ensureLibraryDir(); err != nil {
		return nil, err
	}
	if a.st, err = openStore(ctx, cfg.DataDir, a.clk.Now()); err != nil {
		return nil, err
	}
	if a.secret, err = loadSecret(cfg.DataDir); err != nil {
		return nil, err
	}
	if a.serverID, err = loadServerID(ctx, a.st); err != nil {
		return nil, err
	}
	if err := a.loadTLS(); err != nil {
		return nil, err
	}
	a.httpsPort.Store(int32(addrPort(cfg.Server.HTTPSAddr)))
	if err := a.wire(); err != nil {
		return nil, err
	}
	if err := a.finalize.Recover(ctx); err != nil {
		return nil, fmt.Errorf("finalize recovery: %w", err)
	}
	if err := a.reenqueueMedia(ctx); err != nil {
		return nil, fmt.Errorf("re-enqueue media jobs: %w", err)
	}
	tok, created, err := a.users.EnsureSetupToken(ctx)
	if err != nil {
		return nil, err
	}
	if created {
		a.setupToken = tok
		a.log.Warn("no admin account yet: finish setup with this setup token (it changes on every start until setup is done)",
			"setup_token", tok, "setup_url", a.LocalSetupURL())
	}
	ok = true
	return a, nil
}

// ensureLibraryDir creates the default library dir (inside the data dir);
// a configured library elsewhere must already exist, so an unmounted volume
// is never mistaken for an empty library.
func (a *App) ensureLibraryDir() error {
	lib := a.cfg.LibraryDir
	rel, err := filepath.Rel(a.cfg.DataDir, lib)
	if err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return os.MkdirAll(lib, 0o755)
	}
	fi, err := os.Stat(lib)
	if err != nil {
		return fmt.Errorf("library_dir %s is not available (create it or mount the volume): %w", lib, err)
	}
	if !fi.IsDir() {
		return fmt.Errorf("library_dir %s is not a directory", lib)
	}
	return nil
}

func (a *App) loadTLS() error {
	switch a.cfg.TLS.Mode {
	case "off":
		a.log.Warn("tls.mode=off: HTTPS is disabled; only run this behind a TLS-terminating reverse proxy")
		return nil
	case "files":
		m, err := tlsutil.LoadFiles(a.cfg.TLS.CertFile, a.cfg.TLS.KeyFile)
		if err != nil {
			return fmt.Errorf("load tls.cert_file/tls.key_file: %w", err)
		}
		a.tlsMat = m
		return nil
	}
	dir := filepath.Join(a.cfg.DataDir, "tls")
	m, err := tlsutil.EnsureSelfSigned(dir, a.serverID, tlsHosts(), localIPs(), a.clk.Now())
	if err != nil {
		return fmt.Errorf("tls: %w", err)
	}
	if m.CARegenerated {
		a.log.Error("TLS: the local CA was missing, unreadable or expiring and has been REGENERATED; "+
			"devices and browsers that installed the old CA must re-trust the new one (the pairing pin is unchanged)",
			"ca", filepath.Join(dir, "ca.crt"))
	}
	a.tlsMat = m
	return nil
}

// wire builds the services and handlers and registers every job handler
// before anything can enqueue (Enqueue reads max_attempts then).
func (a *App) wire() error {
	cfg, st, clk, fs, log := a.cfg, a.st, a.clk, a.fs, a.log
	a.runner = jobs.New(st, repository.JobsRepository{}, clk, log)

	var err error
	a.auth, err = service.NewAuthService(service.AuthServiceDeps{
		Store: st, Users: repository.UsersRepository{}, Devices: repository.DevicesRepository{},
		AccessTokens: repository.AccessTokensRepository{}, RefreshTokens: repository.RefreshTokensRepository{},
		WebSessions: repository.WebSessionsRepository{}, Audit: repository.AuditLogRepository{},
		Clock: clk, Secret: a.secret,
	})
	if err != nil {
		return err
	}
	a.users = service.NewUserService(service.UserServiceDeps{
		Store: st, Users: repository.UsersRepository{}, ServerState: repository.ServerStateRepository{},
		Devices: repository.DevicesRepository{}, Audit: repository.AuditLogRepository{}, Auth: a.auth, Clock: clk,
	})
	a.devices = service.NewDeviceService(service.DeviceServiceDeps{
		Store: st, Devices: repository.DevicesRepository{}, Auth: a.auth, Clock: clk,
	})
	a.pairing, err = service.NewPairingService(service.PairingServiceDeps{
		Store: st, PairingCodes: repository.PairingCodesRepository{}, Devices: repository.DevicesRepository{},
		Users: repository.UsersRepository{}, Audit: repository.AuditLogRepository{}, Auth: a.auth, Clock: clk,
		ServerID: a.serverID, Fingerprint: a.Fingerprint(), Endpoints: a.endpoints, Secret: a.secret,
	})
	if err != nil {
		return err
	}
	a.check = service.NewCheckService(service.CheckServiceDeps{
		Store: st, Assets: repository.AssetsRepository{}, LiveVideos: repository.LiveVideosRepository{},
		UploadSessions: repository.UploadSessionsRepository{}, Tombstones: repository.TombstonesRepository{},
		AssetSources: repository.AssetSourcesRepository{}, FS: fs, Clock: clk, LibraryDir: cfg.LibraryDir,
	})
	a.feed = service.NewFeedService(service.FeedServiceDeps{
		Store: st, Assets: repository.AssetsRepository{}, LiveVideos: repository.LiveVideosRepository{},
		ChangeLog: repository.ChangeLogRepository{}, ServerState: repository.ServerStateRepository{},
	})
	a.assets = service.NewAssetService(service.AssetServiceDeps{
		Store: st, Assets: repository.AssetsRepository{}, LiveVideos: repository.LiveVideosRepository{},
		FS: fs, LibraryDir: cfg.LibraryDir, DataDir: cfg.DataDir,
	})
	a.trash = service.NewTrashService(service.TrashServiceDeps{
		Store: st, Assets: repository.AssetsRepository{}, LiveVideos: repository.LiveVideosRepository{},
		Tombstones: repository.TombstonesRepository{}, ChangeLog: repository.ChangeLogRepository{},
		LibraryPaths: repository.LibraryPathsRepository{}, Jobs: a.runner, FS: fs, Clock: clk,
		LibraryDir: cfg.LibraryDir, DataDir: cfg.DataDir, RetentionDays: cfg.Trash.RetentionDays, Log: log,
	})
	lib := service.NewLibraryService(service.LibraryServiceDeps{
		LibraryPaths: repository.LibraryPathsRepository{}, FS: fs, Clock: clk, LibraryDir: cfg.LibraryDir,
	})
	a.finalize = service.NewFinalizeService(service.FinalizeServiceDeps{
		Store: st, Users: repository.UsersRepository{}, Assets: repository.AssetsRepository{},
		LiveVideos: repository.LiveVideosRepository{}, LibraryPaths: repository.LibraryPathsRepository{},
		AssetSources: repository.AssetSourcesRepository{}, UploadSessions: repository.UploadSessionsRepository{},
		Tombstones: repository.TombstonesRepository{}, ChangeLog: repository.ChangeLogRepository{},
		Jobs: a.runner, Library: lib, FS: fs, Clock: clk, Probe: probe.FastDate, Failpoints: a.o.Failpoints,
		DataDir: cfg.DataDir, LibraryDir: cfg.LibraryDir, Log: log,
	})
	a.upload = service.NewUploadService(service.UploadServiceDeps{
		Store: st, Sessions: repository.UploadSessionsRepository{}, Assets: repository.AssetsRepository{},
		LiveVideos: repository.LiveVideosRepository{}, Tombstones: repository.TombstonesRepository{},
		Users: repository.UsersRepository{}, AssetSources: repository.AssetSourcesRepository{},
		Finalize: a.finalize, FS: fs, FreeSpace: a.o.FreeSpace, Clock: clk, Failpoints: a.o.Failpoints,
		Cfg:     service.UploadConfig{MaxFileBytes: cfg.Upload.MaxFileBytes, ReserveBytes: cfg.Storage.ReserveBytes},
		DataDir: cfg.DataDir, LibraryDir: cfg.LibraryDir, Log: log,
	})
	tools := media.FindTools(cfg)
	if tools.FFmpeg == "" || tools.FFprobe == "" {
		log.Warn("ffmpeg/ffprobe not found: video metadata, non-JPEG/PNG thumbnails and transcodes will retry until it is installed",
			"ffmpeg", tools.FFmpeg, "ffprobe", tools.FFprobe)
	}
	a.media = service.NewMediaService(service.MediaServiceDeps{
		Store: st, Assets: repository.AssetsRepository{}, LiveVideos: repository.LiveVideosRepository{},
		ChangeLog: repository.ChangeLogRepository{}, Jobs: a.runner, FS: fs, Tools: tools, Clock: clk,
		Failpoints: a.o.Failpoints, DataDir: cfg.DataDir, LibraryDir: cfg.LibraryDir,
	})
	a.maint = service.NewMaintenanceService(service.MaintenanceServiceDeps{
		Store: st, ChangeLog: repository.ChangeLogRepository{}, ServerState: repository.ServerStateRepository{},
		AccessTokens: repository.AccessTokensRepository{}, RefreshTokens: repository.RefreshTokensRepository{},
		WebSessions: repository.WebSessionsRepository{}, PairingCodes: repository.PairingCodesRepository{},
		FS: fs, Clock: clk, DataDir: cfg.DataDir, Log: log,
	})

	periodic := func(f func(context.Context) error) jobs.Handler {
		return func(ctx context.Context, _ []byte) error { return f(ctx) }
	}
	r := a.runner
	r.Register(JobExpireUploads, periodic(a.upload.ExpireSessions), 0)
	r.Register(JobExpireTokens, periodic(a.maint.ExpireTokens), 0)
	r.Register(JobPurgeTrash, periodic(a.trash.PurgeExpired), 0)
	r.Register(JobCompactChangeLog, periodic(a.maint.CompactChangeLog), 0)
	r.Register(JobBackupDatabase, periodic(a.maint.BackupDatabase), 0)
	r.Register(service.JobDeleteFile, a.trash.DeleteFile, 0)
	r.Register(service.JobExtractMetadata, a.media.ExtractMetadata, service.MediaJobMaxAttempts)
	r.Register(service.JobGenerateThumbnails, a.media.GenerateThumbnails, service.MediaJobMaxAttempts)
	r.Register(service.JobTranscodeVideo, a.media.TranscodeVideo, service.MediaJobMaxAttempts)
	r.DeclarePeriodic(Periodic)

	a.deps = httpapi.Deps{
		Users: a.users, Auth: a.auth, Devices: a.devices, Pairing: a.pairing, Check: a.check, Feed: a.feed,
		Assets: a.assets, Trash: a.trash,
		Tus:  tus.New(a.upload, httpapi.TusPrincipal, cfg, log, httpapi.WriteProblem),
		Info: a.info, Ready: a.ready, Cfg: cfg, Clock: clk, Log: log,
	}
	a.handler = httpapi.NewHandler(a.deps, false)
	a.localHandler = httpapi.NewHandler(a.deps, true)
	return nil
}

// endpoints are the pairing endpoints, computed when a code is created so
// they follow interface changes.
func (a *App) endpoints() []string {
	return PairingEndpoints(localIPs(), int(a.httpsPort.Load()), a.cfg.Server.PublicURLs, a.tlsMat != nil)
}

func (a *App) info() gen.ServerInfo {
	id, _ := uuid.Parse(a.serverID)
	return gen.ServerInfo{
		ServerId: id, Name: a.cfg.Server.Name, Version: a.o.Version, ApiVersion: APIVersion,
		MinClientVersion: gen.ClientVersions{
			Android: a.cfg.Clients.MinVersion["android"], Ios: a.cfg.Clients.MinVersion["ios"], Web: a.cfg.Clients.MinVersion["web"],
		},
		Capabilities: []string{"tus"},
		Upload: gen.UploadLimits{TusVersion: "1.0.0", MaxFileBytes: a.cfg.Upload.MaxFileBytes,
			RecommendedChunkBytes: a.cfg.Upload.RecommendedChunkBytes},
	}
}

// ready backs /readyz: the listeners serving it are open, so it only fails
// while draining or when the database does not answer.
func (a *App) ready(ctx context.Context) error {
	if a.draining.Load() {
		return apperr.ServerUnavailable(5 * time.Second)
	}
	return a.st.R.PingContext(ctx)
}

// Handler is the full API for the HTTPS listener (local=false).
func (a *App) Handler() http.Handler { return a.handler }

// LocalHandler is the full API for the 127.0.0.1 loopback listener
// (local=true: setup without a token, cookie without Secure).
func (a *App) LocalHandler() http.Handler { return a.localHandler }

// Deps returns the HTTP dependencies (tests build variant handlers).
func (a *App) Deps() httpapi.Deps { return a.deps }

// TLSConfig is the HTTPS listener's config (TLS 1.2+, h2), or nil when
// tls.mode=off.
func (a *App) TLSConfig() *tls.Config {
	if a.tlsMat == nil {
		return nil
	}
	return &tls.Config{
		MinVersion:   tls.VersionTLS12,
		Certificates: []tls.Certificate{a.tlsMat.Cert},
		NextProtos:   []string{"h2", "http/1.1"},
	}
}

// CACertPEM is the self-signed CA (empty unless tls.mode=self-signed).
func (a *App) CACertPEM() []byte {
	if a.tlsMat == nil {
		return nil
	}
	return a.tlsMat.CAPEM
}

// Fingerprint is the leaf SPKI pin (fp), empty when tls.mode=off.
func (a *App) Fingerprint() string {
	if a.tlsMat == nil {
		return ""
	}
	return a.tlsMat.SPKIFingerprint
}

// ServerID is the persistent server id.
func (a *App) ServerID() string { return a.serverID }

// SetupToken is the setup token generated by this boot, or "" once a user
// exists.
func (a *App) SetupToken() string { return a.setupToken }

// LocalSetupURL is the loopback URL where first-run setup is done.
func (a *App) LocalSetupURL() string {
	host, port, err := net.SplitHostPort(a.cfg.Server.LocalAddr)
	if err != nil {
		return "http://127.0.0.1:8080"
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	return "http://" + net.JoinHostPort(host, port)
}

// Config is the configuration the app booted with.
func (a *App) Config() config.Config { return a.cfg }

func (a *App) Users() *service.UserService              { return a.users }
func (a *App) Auth() *service.AuthService               { return a.auth }
func (a *App) Devices() *service.DeviceService          { return a.devices }
func (a *App) Pairing() *service.PairingService         { return a.pairing }
func (a *App) Check() *service.CheckService             { return a.check }
func (a *App) Feed() *service.FeedService               { return a.feed }
func (a *App) Assets() *service.AssetService            { return a.assets }
func (a *App) Trash() *service.TrashService             { return a.trash }
func (a *App) Upload() *service.UploadService           { return a.upload }
func (a *App) Media() *service.MediaService             { return a.media }
func (a *App) Jobs() *jobs.Runner                       { return a.runner }
func (a *App) Store() *store.Store                      { return a.st }
func (a *App) Maintenance() *service.MaintenanceService { return a.maint }

// Run starts the job runner (default and media pools, scheduler unless
// disabled), opens the HTTPS and loopback listeners and mDNS (S§10.1 steps
// 7–9), and blocks until ctx is done. Shutdown runs in reverse: mDNS
// goodbye, a 30 s HTTP drain, then the job runner.
func (a *App) Run(ctx context.Context) error {
	jobCtx, cancelJobs := context.WithCancel(context.WithoutCancel(ctx))
	defer cancelJobs()
	var other []string
	for _, p := range Periodic {
		other = append(other, p.Kind)
	}
	other = append(other, service.JobDeleteFile)
	pools := []jobs.Pool{
		{Name: "default", Workers: a.cfg.Jobs.Workers, Kinds: other},
		{Name: "media", Workers: a.cfg.Media.Workers, Kinds: mediaKinds},
	}
	var periodic []jobs.Periodic
	if !a.o.DisableScheduler {
		periodic = Periodic
	}
	a.runner.Start(jobCtx, pools, periodic)
	defer a.runner.StopWithTimeout(shutdownGrace)

	lc := net.ListenConfig{}
	httpsLn, err := lc.Listen(ctx, "tcp", a.cfg.Server.HTTPSAddr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", a.cfg.Server.HTTPSAddr, err)
	}
	localLn, err := lc.Listen(ctx, "tcp", a.cfg.Server.LocalAddr)
	if err != nil {
		_ = httpsLn.Close()
		return fmt.Errorf("listen %s: %w", a.cfg.Server.LocalAddr, err)
	}
	if tcp, ok := httpsLn.Addr().(*net.TCPAddr); ok {
		a.httpsPort.Store(int32(tcp.Port))
	}
	base := func(h http.Handler) *http.Server {
		return &http.Server{
			Handler: h, ReadHeaderTimeout: readHeaderTimeout, IdleTimeout: idleTimeout,
			ErrorLog: slog.NewLogLogger(a.log.Handler(), slog.LevelDebug),
		}
	}
	httpsSrv, localSrv := base(a.handler), base(a.localHandler)
	scheme := "https"
	if tc := a.TLSConfig(); tc != nil {
		httpsSrv.TLSConfig = tc
		httpsLn = tls.NewListener(httpsLn, tc)
	} else {
		scheme = "http"
	}
	errc := make(chan error, 2)
	serve := func(s *http.Server, ln net.Listener) {
		if err := s.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errc <- err
		}
	}
	go serve(httpsSrv, httpsLn)
	go serve(localSrv, localLn)
	a.log.Info("listening", "api", scheme+"://"+httpsLn.Addr().String(), "local", "http://"+localLn.Addr().String(),
		"server_id", a.serverID, "fingerprint", a.Fingerprint())
	if a.o.Listening != nil {
		a.o.Listening(httpsLn.Addr().String(), localLn.Addr().String())
	}

	var mdns discovery.Responder
	if a.cfg.Discovery.MDNS {
		mdns = discovery.New(a.cfg.Server.Name, int(a.httpsPort.Load()),
			discovery.TXT(a.serverID, a.o.Version, a.Fingerprint()), a.log)
		_ = mdns.Start(context.WithoutCancel(ctx))
	}

	var runErr error
	select {
	case <-ctx.Done():
	case runErr = <-errc:
		a.log.Error("listener failed", "err", runErr)
	}
	a.draining.Store(true)
	if mdns != nil {
		mdns.Stop()
	}
	sctx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
	defer cancel()
	var wg sync.WaitGroup
	for _, s := range []*http.Server{httpsSrv, localSrv} {
		wg.Add(1)
		go func(s *http.Server) {
			defer wg.Done()
			if err := s.Shutdown(sctx); err != nil {
				_ = s.Close()
			}
		}(s)
	}
	wg.Wait()
	return runErr
}

// Close releases the database and the data-dir lock. It is idempotent.
func (a *App) Close() error {
	a.closeOnce.Do(func() {
		var errs []error
		if a.st != nil {
			errs = append(errs, a.st.Close())
		}
		if a.lock != nil {
			errs = append(errs, a.lock.Close())
		}
		a.closeErr = errors.Join(errs...)
	})
	return a.closeErr
}
