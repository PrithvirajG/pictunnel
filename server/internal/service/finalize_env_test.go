package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/clock/clocktest"
	"github.com/PrithvirajG/pictunnel/server/internal/ids"
	"github.com/PrithvirajG/pictunnel/server/internal/jobs"
	"github.com/PrithvirajG/pictunnel/server/internal/media/probe"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

// fenv is a finalize test environment: a real store, temp data and library
// dirs, a fake clock and the user "alice" with one device.
type fenv struct {
	st      *store.Store
	clk     *clocktest.Fake
	dataDir string
	libDir  string
	fs      storage.FS
	fp      Failpoints
	owner   string
	device  string
	runner  *jobs.Runner
	lib     *LibraryService
	fin     *FinalizeService
}

var fT0 = time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)

func newFenv(t *testing.T) *fenv {
	t.Helper()
	e := &fenv{st: repotest.NewStore(t), clk: clocktest.NewFake(fT0), fs: storage.OS()}
	root := t.TempDir()
	e.dataDir, e.libDir = filepath.Join(root, "data"), filepath.Join(root, "library")
	for _, d := range []string{filepath.Join(e.dataDir, "uploads"), e.libDir} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	e.owner = ids.New()
	err := repository.UsersRepository{}.Insert(context.Background(), e.st.W, repository.User{
		ID: e.owner, Username: "alice", Slug: "alice", DisplayName: "Alice", Role: "admin",
		PasswordHash: "x", CreatedAt: fT0,
	})
	if err != nil {
		t.Fatal(err)
	}
	e.device = repotest.SeedDevice(t, e.st, e.owner, ids.New())
	e.rebuild()
	return e
}

// rebuild constructs fresh services over the same store and dirs, which
// simulates a process restart (with whatever fs and fp are set).
func (e *fenv) rebuild() {
	e.runner = jobs.New(e.st, repository.JobsRepository{}, e.clk, nil)
	e.lib = NewLibraryService(LibraryServiceDeps{
		LibraryPaths: repository.LibraryPathsRepository{}, FS: e.fs, Clock: e.clk, LibraryDir: e.libDir,
	})
	e.fin = NewFinalizeService(FinalizeServiceDeps{
		Store: e.st, Users: repository.UsersRepository{}, Assets: repository.AssetsRepository{},
		LiveVideos: repository.LiveVideosRepository{}, LibraryPaths: repository.LibraryPathsRepository{},
		AssetSources: repository.AssetSourcesRepository{}, UploadSessions: repository.UploadSessionsRepository{},
		Tombstones: repository.TombstonesRepository{}, ChangeLog: repository.ChangeLogRepository{},
		Jobs: e.runner, Library: e.lib, FS: e.fs, Clock: e.clk, Probe: probe.FastDate,
		Failpoints: e.fp, DataDir: e.dataDir, LibraryDir: e.libDir,
		Log: slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
}

func shaHex(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "media", "probe", "testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// stage writes content as a complete staging file and inserts a receiving
// session for it with offset == length.
func (e *fenv) stage(t *testing.T, content []byte, meta map[string]any) repository.UploadSession {
	t.Helper()
	ctx := context.Background()
	sha := shaHex(content)
	if _, ok := meta["sha256"]; !ok {
		meta["sha256"] = sha
	}
	mj, err := json.Marshal(meta)
	if err != nil {
		t.Fatal(err)
	}
	id := ids.New()
	staging := filepath.Join(e.dataDir, "uploads", id+".part")
	if err := os.WriteFile(staging, content, 0o644); err != nil {
		t.Fatal(err)
	}
	s := repository.UploadSession{
		ID: id, OwnerID: e.owner, DeviceID: e.device, SHA256: sha, Length: int64(len(content)),
		Offset: int64(len(content)), State: "receiving", MetaJSON: string(mj), StagingPath: staging,
		CreatedAt: e.clk.Now(), UpdatedAt: e.clk.Now(), ExpiresAt: e.clk.Now().Add(24 * time.Hour),
	}
	if r, ok := meta["pair_role"].(string); ok {
		s.PairRole = &r
	}
	if p, ok := meta["pair_sha256"].(string); ok {
		s.PairSHA256 = &p
	}
	if err := (repository.UploadSessionsRepository{}).Insert(ctx, e.st.W, s); err != nil {
		t.Fatal(err)
	}
	return s
}

func (e *fenv) session(t *testing.T, id string) repository.UploadSession {
	t.Helper()
	s, err := repository.UploadSessionsRepository{}.Get(context.Background(), e.st.R, id)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func (e *fenv) assetBySHA(t *testing.T, sha string) (repository.Asset, bool) {
	t.Helper()
	a, err := repository.AssetsRepository{}.GetBySHA(context.Background(), e.st.R, e.owner, sha)
	if errors.Is(err, repository.ErrNotFound) {
		return a, false
	}
	if err != nil {
		t.Fatal(err)
	}
	return a, true
}

func (e *fenv) libPath(rel string) string { return filepath.Join(e.libDir, filepath.FromSlash(rel)) }

func exists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// tmpPath is where a cross-volume copy of the session is staged.
func (e *fenv) tmpPath(id string) string {
	return filepath.Join(e.libDir, ".pictunnel-tmp", id+".ptpart")
}

// strays lists every file in the library temp dir and in staging.
func (e *fenv) strays(t *testing.T) []string {
	t.Helper()
	var out []string
	tmps, _ := os.ReadDir(filepath.Join(e.libDir, ".pictunnel-tmp"))
	for _, d := range tmps {
		out = append(out, filepath.Join(".pictunnel-tmp", d.Name()))
	}
	ents, _ := os.ReadDir(filepath.Join(e.dataDir, "uploads"))
	for _, d := range ents {
		out = append(out, filepath.Join("uploads", d.Name()))
	}
	return out
}

func (e *fenv) reservations(t *testing.T) []repository.LibraryPath {
	t.Helper()
	l, err := repository.LibraryPathsRepository{}.ListAll(context.Background(), e.st.R)
	if err != nil {
		t.Fatal(err)
	}
	return l
}

// trip is a Failpoints that fails at one named point.
type trip string

var errTripped = errors.New("failpoint tripped")

func (t trip) Hit(name string) error {
	if string(t) == name {
		return errTripped
	}
	return nil
}
