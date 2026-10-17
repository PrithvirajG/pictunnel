package service

import (
	"context"
	"database/sql"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/clock/clocktest"
	"github.com/PrithvirajG/pictunnel/server/internal/ids"
	"github.com/PrithvirajG/pictunnel/server/internal/jobs"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

// senv is a sync/assets/trash test environment: a real store, temp data and
// library dirs, a fake clock, and users alice and bob with one device each.
type senv struct {
	st      *store.Store
	clk     *clocktest.Fake
	dataDir string
	libDir  string
	fs      *removeFaultFS
	runner  *jobs.Runner

	alice, bob Principal

	check  *CheckService
	feed   *FeedService
	assets *AssetService
	trash  *TrashService
	maint  *MaintenanceService
}

// removeFaultFS fails Remove/RemoveAll for paths in fail.
type removeFaultFS struct {
	storage.FS
	mu   sync.Mutex
	fail map[string]bool
}

func (f *removeFaultFS) failing(p string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.fail[filepath.Clean(p)]
}

func (f *removeFaultFS) setFail(p string, on bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.fail[filepath.Clean(p)] = on
}

func (f *removeFaultFS) Remove(p string) error {
	if f.failing(p) {
		return errors.New("injected remove failure")
	}
	return f.FS.Remove(p)
}

func (f *removeFaultFS) RemoveAll(p string) error {
	if f.failing(p) {
		return errors.New("injected remove failure")
	}
	return f.FS.RemoveAll(p)
}

func newSenv(t *testing.T) *senv {
	t.Helper()
	e := &senv{st: repotest.NewStore(t), clk: clocktest.NewFake(t0),
		fs: &removeFaultFS{FS: storage.OS(), fail: map[string]bool{}}}
	root := t.TempDir()
	e.dataDir, e.libDir = filepath.Join(root, "data"), filepath.Join(root, "library")
	for _, d := range []string{e.dataDir, e.libDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	e.alice = e.addUser(t, "alice")
	e.bob = e.addUser(t, "bob")
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	e.runner = jobs.New(e.st, repository.JobsRepository{}, e.clk, log)
	e.check = NewCheckService(CheckServiceDeps{
		Store: e.st, Assets: repository.AssetsRepository{}, LiveVideos: repository.LiveVideosRepository{},
		UploadSessions: repository.UploadSessionsRepository{}, Tombstones: repository.TombstonesRepository{},
		AssetSources: repository.AssetSourcesRepository{}, FS: e.fs, Clock: e.clk, LibraryDir: e.libDir,
	})
	e.feed = NewFeedService(FeedServiceDeps{
		Store: e.st, Assets: repository.AssetsRepository{}, LiveVideos: repository.LiveVideosRepository{},
		ChangeLog: repository.ChangeLogRepository{}, ServerState: repository.ServerStateRepository{},
	})
	e.assets = NewAssetService(AssetServiceDeps{
		Store: e.st, Assets: repository.AssetsRepository{}, LiveVideos: repository.LiveVideosRepository{},
		FS: e.fs, LibraryDir: e.libDir, DataDir: e.dataDir,
	})
	e.trash = NewTrashService(TrashServiceDeps{
		Store: e.st, Assets: repository.AssetsRepository{}, LiveVideos: repository.LiveVideosRepository{},
		Tombstones: repository.TombstonesRepository{}, ChangeLog: repository.ChangeLogRepository{},
		LibraryPaths: repository.LibraryPathsRepository{}, Jobs: e.runner, FS: e.fs, Clock: e.clk,
		LibraryDir: e.libDir, DataDir: e.dataDir, RetentionDays: 30, Log: log,
	})
	e.maint = NewMaintenanceService(MaintenanceServiceDeps{
		Store: e.st, ChangeLog: repository.ChangeLogRepository{}, ServerState: repository.ServerStateRepository{},
		AccessTokens: repository.AccessTokensRepository{}, RefreshTokens: repository.RefreshTokensRepository{},
		WebSessions: repository.WebSessionsRepository{}, PairingCodes: repository.PairingCodesRepository{},
		FS: e.fs, Clock: e.clk, DataDir: e.dataDir, Log: log,
	})
	return e
}

func (e *senv) addUser(t *testing.T, name string) Principal {
	t.Helper()
	id := ids.New()
	err := repository.UsersRepository{}.Insert(context.Background(), e.st.W, repository.User{
		ID: id, Username: name, Slug: name, DisplayName: name, Role: RoleUser, PasswordHash: "x", CreatedAt: t0,
	})
	if err != nil {
		t.Fatal(err)
	}
	dev := repotest.SeedDevice(t, e.st, id, ids.New())
	return Principal{UserID: id, Username: name, Slug: name, Role: RoleUser, DeviceID: dev, Platform: "ios", Via: ViaBearer}
}

// device registers another device for the principal's user.
func (e *senv) device(t *testing.T, p Principal) Principal {
	t.Helper()
	p.DeviceID = repotest.SeedDevice(t, e.st, p.UserID, ids.New())
	return p
}

// assetOpt customises a seeded asset.
type assetOpt func(a *repository.Asset)

func withMime(mime, kind string) assetOpt {
	return func(a *repository.Asset) { a.Mime, a.Kind = mime, kind }
}

// seed stores content as an asset of p, the way finalize leaves it: the
// library file, the row, its path reservation and an asset.upsert change.
func (e *senv) seed(t *testing.T, p Principal, content string, opts ...assetOpt) repository.Asset {
	t.Helper()
	ctx := context.Background()
	id := ids.New()
	a := repository.Asset{
		ID: id, OwnerID: p.UserID, SHA256: shaHex([]byte(content)), SizeBytes: int64(len(content)),
		Mime: "image/jpeg", Kind: "photo", Filename: id[len(id)-8:] + ".jpg",
		TakenAtSource: "unknown", State: "active", CreatedAt: e.clk.Now(),
	}
	for _, o := range opts {
		o(&a)
	}
	a.OriginalPath = p.Slug + "/2026/10/" + a.Filename
	e.writeLib(t, a.OriginalPath, content)
	err := e.st.WithTx(ctx, func(tx *sql.Tx) error {
		if err := (repository.AssetsRepository{}).Insert(ctx, tx, a); err != nil {
			return err
		}
		if err := (repository.LibraryPathsRepository{}).Reserve(ctx, tx, repository.LibraryPath{
			PathKey: storage.PathKey(a.OriginalPath), Path: a.OriginalPath, UserID: p.UserID, AssetID: &a.ID,
		}); err != nil {
			return err
		}
		_, err := appendAssetUpsert(ctx, tx, repository.ChangeLogRepository{}, repository.AssetsRepository{}, p.UserID, a.ID, e.clk.Now())
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return e.asset(t, a.ID)
}

// attachLive adds a live video component to a (kind becomes live_photo).
func (e *senv) attachLive(t *testing.T, a repository.Asset, content string) repository.LiveVideo {
	t.Helper()
	ctx := context.Background()
	lv := repository.LiveVideo{
		AssetID: a.ID, OwnerID: a.OwnerID, SHA256: shaHex([]byte(content)), SizeBytes: int64(len(content)),
		Mime: "video/quicktime", Filename: a.Filename + ".mov", OriginalPath: a.OriginalPath + ".mov", CreatedAt: e.clk.Now(),
	}
	e.writeLib(t, lv.OriginalPath, content)
	err := e.st.WithTx(ctx, func(tx *sql.Tx) error {
		if err := (repository.LiveVideosRepository{}).Insert(ctx, tx, lv); err != nil {
			return err
		}
		if err := (repository.AssetsRepository{}).SetKind(ctx, tx, a.ID, "live_photo"); err != nil {
			return err
		}
		if err := (repository.LibraryPathsRepository{}).Reserve(ctx, tx, repository.LibraryPath{
			PathKey: storage.PathKey(lv.OriginalPath), Path: lv.OriginalPath, UserID: a.OwnerID, AssetID: &a.ID,
		}); err != nil {
			return err
		}
		_, err := appendAssetUpsert(ctx, tx, repository.ChangeLogRepository{}, repository.AssetsRepository{}, a.OwnerID, a.ID, e.clk.Now())
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return lv
}

func (e *senv) writeLib(t *testing.T, rel, content string) {
	t.Helper()
	p := e.lib(rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (e *senv) lib(rel string) string { return filepath.Join(e.libDir, filepath.FromSlash(rel)) }

func (e *senv) derived(id string) string {
	return filepath.Join(e.dataDir, "derived", id[0:2], id[2:4], id)
}

// writeDerived creates a derived file (thumb.jpg, preview.jpg, web.mp4).
func (e *senv) writeDerived(t *testing.T, id, name, content string) {
	t.Helper()
	d := e.derived(id)
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (e *senv) asset(t *testing.T, id string) repository.Asset {
	t.Helper()
	a, err := repository.AssetsRepository{}.GetByID(context.Background(), e.st.R, id)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func (e *senv) assetGone(t *testing.T, id string) bool {
	t.Helper()
	_, err := repository.AssetsRepository{}.GetByID(context.Background(), e.st.R, id)
	if errors.Is(err, repository.ErrNotFound) {
		return true
	}
	if err != nil {
		t.Fatal(err)
	}
	return false
}

// session inserts an upload session of p for sha.
func (e *senv) session(t *testing.T, p Principal, sha, state string, offset, length int64, expires time.Time) repository.UploadSession {
	t.Helper()
	s := repository.UploadSession{
		ID: ids.New(), OwnerID: p.UserID, DeviceID: p.DeviceID, SHA256: sha, Length: length, Offset: offset,
		State: state, MetaJSON: "{}", StagingPath: "x.part", CreatedAt: e.clk.Now(), UpdatedAt: e.clk.Now(),
		ExpiresAt: expires,
	}
	if err := (repository.UploadSessionsRepository{}).Insert(context.Background(), e.st.W, s); err != nil {
		t.Fatal(err)
	}
	return s
}

func (e *senv) tombstone(t *testing.T, p Principal, sha, filename string, at time.Time) {
	t.Helper()
	err := repository.TombstonesRepository{}.Insert(context.Background(), e.st.W, repository.Tombstone{
		OwnerID: p.UserID, SHA256: sha, Filename: filename, DeletedAt: at,
	})
	if err != nil {
		t.Fatal(err)
	}
}

func (e *senv) pendingJobs(t *testing.T, kind string) []repository.Job {
	t.Helper()
	j, err := repository.JobsRepository{}.ListPending(context.Background(), e.st.R, kind)
	if err != nil {
		t.Fatal(err)
	}
	return j
}
