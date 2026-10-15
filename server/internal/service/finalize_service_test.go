package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
	"github.com/PrithvirajG/pictunnel/server/internal/storage/storagetest"
)

var ctx = context.Background()

func (e *fenv) finalize(t *testing.T, s repository.UploadSession) FinalizeResult {
	t.Helper()
	r, err := e.fin.Finalize(ctx, s, s.SHA256)
	if err != nil {
		t.Fatalf("Finalize: %v", err)
	}
	return r
}

func (e *fenv) pendingJobs(t *testing.T, kind string) []repository.Job {
	t.Helper()
	j, err := repository.JobsRepository{}.ListPending(ctx, e.st.R, kind)
	if err != nil {
		t.Fatal(err)
	}
	return j
}

func (e *fenv) changes(t *testing.T) []repository.Change {
	t.Helper()
	c, err := repository.ChangeLogRepository{}.ListAfter(ctx, e.st.R, e.owner, 0, 1000)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestFinalizeCreatesAsset(t *testing.T) {
	e := newFenv(t)
	content := fixture(t, "exif.jpg")
	s := e.stage(t, content, map[string]any{"filename": "IMG_0001.JPG", "mime": "image/jpeg", "local_id": "L1"})
	r := e.finalize(t, s)
	if !r.Created || r.AssetID == "" {
		t.Fatalf("result %+v", r)
	}
	a, ok := e.assetBySHA(t, s.SHA256)
	if !ok || a.ID != r.AssetID {
		t.Fatal("asset row missing")
	}
	if a.OriginalPath != "alice/2024/05/IMG_0001.JPG" || a.Kind != "photo" || a.Filename != "IMG_0001.JPG" ||
		a.Mime != "image/jpeg" || a.SizeBytes != int64(len(content)) || a.State != "active" || !a.CreatedAt.Equal(fT0) {
		t.Fatalf("asset %+v", a)
	}
	if a.TakenAt == nil || !a.TakenAt.Equal(time.Date(2024, 5, 6, 8, 0, 0, 0, time.UTC)) ||
		a.TakenAtOffsetMinutes == nil || *a.TakenAtOffsetMinutes != 120 || a.TakenAtSource != "exif" {
		t.Fatalf("taken %v %v %q", a.TakenAt, a.TakenAtOffsetMinutes, a.TakenAtSource)
	}
	if a.StackID != nil || a.StackKey != nil {
		t.Fatal("unexpected stack")
	}
	b, err := os.ReadFile(e.libPath(a.OriginalPath))
	if err != nil || !bytes.Equal(b, content) {
		t.Fatalf("library file: %v", err)
	}
	if exists(s.StagingPath) {
		t.Fatal("staging remains")
	}
	ch := e.changes(t)
	if len(ch) != 1 || ch[0].Kind != "asset.upsert" || ch[0].AssetID != a.ID || a.UpdatedSeq != ch[0].Seq {
		t.Fatalf("changes %+v updated_seq %d", ch, a.UpdatedSeq)
	}
	for _, kind := range []string{"extract_metadata", "generate_thumbnails"} {
		j := e.pendingJobs(t, kind)
		if len(j) != 1 || j[0].DedupeKey != a.ID {
			t.Fatalf("%s jobs %+v", kind, j)
		}
		var p struct {
			AssetID string `json:"asset_id"`
		}
		if err := json.Unmarshal([]byte(j[0].Payload), &p); err != nil || p.AssetID != a.ID {
			t.Fatalf("%s payload %q", kind, j[0].Payload)
		}
	}
	src, err := repository.AssetSourcesRepository{}.ListByAsset(ctx, e.st.R, a.ID)
	if err != nil || len(src) != 1 || src[0].DeviceID != e.device || src[0].LocalID != "L1" {
		t.Fatalf("sources %+v %v", src, err)
	}
	res := e.reservations(t)
	if len(res) != 1 || res[0].AssetID == nil || *res[0].AssetID != a.ID || res[0].Path != a.OriginalPath {
		t.Fatalf("reservations %+v", res)
	}
	got := e.session(t, s.ID)
	if got.State != "done" || got.AssetID == nil || *got.AssetID != a.ID || !got.AssetCreated || got.DestPath != a.OriginalPath {
		t.Fatalf("session %+v", got)
	}
}

func TestFinalizeNoLocalIDNoSource(t *testing.T) {
	e := newFenv(t)
	s := e.stage(t, []byte("plain bytes"), map[string]any{"filename": "a.png", "mime": "image/png"})
	r := e.finalize(t, s)
	src, _ := repository.AssetSourcesRepository{}.ListByAsset(ctx, e.st.R, r.AssetID)
	if len(src) != 0 {
		t.Fatalf("sources %+v", src)
	}
}

func TestFinalizeDateFallbacks(t *testing.T) {
	e := newFenv(t)
	created := time.Date(2019, 7, 8, 23, 30, 0, 0, time.FixedZone("", -4*3600))
	modified := time.Date(2018, 3, 4, 5, 6, 7, 0, time.UTC)
	cases := []struct {
		name    string
		meta    map[string]any
		path    string
		source  string
		takenAt *time.Time
	}{
		// The path uses the client's wall-clock date (2019-07-08 at -04:00).
		{"client", map[string]any{"created_at": created, "modified_at": modified}, "alice/2019/07/a.jpg", "client", &created},
		{"file", map[string]any{"modified_at": modified}, "alice/2018/03/b.jpg", "file", &modified},
		{"unknown", map[string]any{}, "alice/2026/10/c.jpg", "unknown", nil},
	}
	for i, c := range cases {
		c.meta["filename"] = string(rune('a'+i)) + ".jpg"
		c.meta["mime"] = "image/jpeg"
		s := e.stage(t, []byte("no exif here "+c.name), c.meta)
		r := e.finalize(t, s)
		a, _ := e.assetBySHA(t, s.SHA256)
		if a.ID != r.AssetID || a.OriginalPath != c.path || a.TakenAtSource != c.source {
			t.Fatalf("%s: path %q source %q", c.name, a.OriginalPath, a.TakenAtSource)
		}
		if (c.takenAt == nil) != (a.TakenAt == nil) || (c.takenAt != nil && !a.TakenAt.Equal(*c.takenAt)) {
			t.Fatalf("%s: taken_at %v", c.name, a.TakenAt)
		}
		if a.TakenAtOffsetMinutes != nil {
			t.Fatalf("%s: offset %v", c.name, *a.TakenAtOffsetMinutes)
		}
	}
}

func TestFinalizeVideoKindAndContainerDate(t *testing.T) {
	e := newFenv(t)
	s := e.stage(t, fixture(t, "clip.mp4"), map[string]any{"filename": "clip.mp4", "mime": "video/mp4"})
	e.finalize(t, s)
	a, _ := e.assetBySHA(t, s.SHA256)
	if a.Kind != "video" || a.TakenAtSource != "container" || a.OriginalPath != "alice/2023/01/clip.mp4" {
		t.Fatalf("asset %+v", a)
	}
	s2 := e.stage(t, []byte("odd"), map[string]any{"filename": "x.bin", "mime": "application/octet-stream"})
	e.finalize(t, s2)
	if a, _ := e.assetBySHA(t, s2.SHA256); a.Kind != "photo" {
		t.Fatalf("kind = %q", a.Kind)
	}
}

func TestFinalizeStackID(t *testing.T) {
	e := newFenv(t)
	first := e.finalize(t, e.stage(t, []byte("one"), map[string]any{"filename": "1.jpg", "mime": "image/jpeg", "stack_key": "K"}))
	second := e.finalize(t, e.stage(t, []byte("two"), map[string]any{"filename": "2.jpg", "mime": "image/jpeg", "stack_key": "K"}))
	other := e.finalize(t, e.stage(t, []byte("three"), map[string]any{"filename": "3.jpg", "mime": "image/jpeg", "stack_key": "J"}))
	get := func(id string) repository.Asset {
		a, err := repository.AssetsRepository{}.GetByID(ctx, e.st.R, id)
		if err != nil {
			t.Fatal(err)
		}
		return a
	}
	if a := get(first.AssetID); a.StackID != nil || a.StackKey == nil || *a.StackKey != "K" {
		t.Fatalf("first %+v", a)
	}
	if a := get(second.AssetID); a.StackID == nil || *a.StackID != first.AssetID {
		t.Fatalf("second stack_id %v", a.StackID)
	}
	if a := get(other.AssetID); a.StackID != nil {
		t.Fatalf("other stack_id %v", *a.StackID)
	}
}

func TestFinalizeDigestMismatch(t *testing.T) {
	e := newFenv(t)
	s := e.stage(t, []byte("abc"), map[string]any{"filename": "a.jpg", "mime": "image/jpeg"})
	_, err := e.fin.Finalize(ctx, s, shaHex([]byte("abd")))
	wantCode(t, err, "checksum_mismatch")
	if exists(s.StagingPath) {
		t.Fatal("staging remains")
	}
	got := e.session(t, s.ID)
	if got.State != "failed" || got.FailureCode == nil || *got.FailureCode != "checksum_mismatch" {
		t.Fatalf("session %+v", got)
	}
	if _, ok := e.assetBySHA(t, s.SHA256); ok || len(e.reservations(t)) != 0 {
		t.Fatal("asset or reservation created")
	}
}

func TestFinalizeExistingResolves(t *testing.T) {
	e := newFenv(t)
	content := []byte("same bytes")
	first := e.finalize(t, e.stage(t, content, map[string]any{"filename": "a.jpg", "mime": "image/jpeg"}))
	// A second session for the same content (the first is done, so the
	// partial unique index allows it), e.g. a dedupe race.
	s := e.stage(t, content, map[string]any{"filename": "b.jpg", "mime": "image/jpeg", "local_id": "L2"})
	r := e.finalize(t, s)
	if r.Created || r.AssetID != first.AssetID {
		t.Fatalf("result %+v", r)
	}
	if exists(s.StagingPath) {
		t.Fatal("staging remains")
	}
	got := e.session(t, s.ID)
	if got.State != "done" || got.AssetCreated || *got.AssetID != first.AssetID {
		t.Fatalf("session %+v", got)
	}
	if len(e.reservations(t)) != 1 || exists(e.libPath("alice/2026/10/b.jpg")) {
		t.Fatal("second path reserved or written")
	}
	src, _ := repository.AssetSourcesRepository{}.ListByAsset(ctx, e.st.R, first.AssetID)
	if len(src) != 1 || src[0].LocalID != "L2" {
		t.Fatalf("sources %+v", src)
	}
}

func (e *fenv) tombstone(t *testing.T, sha string) {
	t.Helper()
	err := repository.TombstonesRepository{}.Insert(ctx, e.st.W, repository.Tombstone{
		OwnerID: e.owner, SHA256: sha, Filename: "gone.jpg", DeletedAt: fT0.Add(-time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestFinalizeTombstoned(t *testing.T) {
	e := newFenv(t)
	content := []byte("deleted once")
	e.tombstone(t, shaHex(content))
	s := e.stage(t, content, map[string]any{"filename": "a.jpg", "mime": "image/jpeg"})
	_, err := e.fin.Finalize(ctx, s, s.SHA256)
	wantCode(t, err, "tombstoned")
	if got := e.session(t, s.ID); got.State != "failed" || *got.FailureCode != "tombstoned" {
		t.Fatalf("session %+v", got)
	}
	if exists(s.StagingPath) {
		t.Fatal("staging remains")
	}
}

func TestFinalizeTombstoneOverride(t *testing.T) {
	e := newFenv(t)
	content := []byte("deleted once")
	e.tombstone(t, shaHex(content))
	s := e.stage(t, content, map[string]any{"filename": "a.jpg", "mime": "image/jpeg", "override_tombstone": true})
	r := e.finalize(t, s)
	if !r.Created {
		t.Fatal("not created")
	}
	if _, err := (repository.TombstonesRepository{}).Get(ctx, e.st.R, e.owner, s.SHA256); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("tombstone still there: %v", err)
	}
}

func TestFinalizeLiveVideoNeedsPrimary(t *testing.T) {
	e := newFenv(t)
	s := e.stage(t, []byte("video"), map[string]any{"filename": "IMG_1.MOV", "mime": "video/quicktime",
		"pair_role": "live_video", "pair_sha256": shaHex([]byte("missing still"))})
	_, err := e.fin.Finalize(ctx, s, s.SHA256)
	wantCode(t, err, "pair_primary_missing")
	if got := e.session(t, s.ID); got.State != "failed" || *got.FailureCode != "pair_primary_missing" {
		t.Fatalf("session %+v", got)
	}
	if exists(s.StagingPath) || len(e.reservations(t)) != 0 {
		t.Fatal("staging or reservation left")
	}
}

func TestFinalizeLiveVideoAttach(t *testing.T) {
	e := newFenv(t)
	still := fixture(t, "exif.jpg")
	p := e.finalize(t, e.stage(t, still, map[string]any{"filename": "IMG_1.HEIC", "mime": "image/heic"}))
	seqBefore := e.changes(t)[0].Seq
	video := []byte("live video bytes")
	s := e.stage(t, video, map[string]any{"filename": "IMG_1.MOV", "mime": "video/quicktime",
		"pair_role": "live_video", "pair_sha256": shaHex(still)})
	r := e.finalize(t, s)
	if !r.Created || r.AssetID != p.AssetID {
		t.Fatalf("result %+v", r)
	}
	a, _ := e.assetBySHA(t, shaHex(still))
	if a.Kind != "live_photo" {
		t.Fatalf("kind = %q", a.Kind)
	}
	lv, err := repository.LiveVideosRepository{}.GetByAsset(ctx, e.st.R, a.ID)
	if err != nil || lv.SHA256 != shaHex(video) || lv.OriginalPath != "alice/2024/05/IMG_1.MOV" || lv.Mime != "video/quicktime" {
		t.Fatalf("live video %+v %v", lv, err)
	}
	if b, err := os.ReadFile(e.libPath(lv.OriginalPath)); err != nil || !bytes.Equal(b, video) {
		t.Fatal("sibling file missing")
	}
	ch := e.changes(t)
	if len(ch) != 1 || ch[0].AssetID != a.ID || ch[0].Seq <= seqBefore || a.UpdatedSeq != ch[0].Seq {
		t.Fatalf("changes %+v", ch)
	}
	if _, ok := e.assetBySHA(t, shaHex(video)); ok {
		t.Fatal("live video became a standalone asset")
	}
	if exists(s.StagingPath) || len(e.reservations(t)) != 2 {
		t.Fatalf("staging left or reservations %+v", e.reservations(t))
	}
	// Re-uploading the attached component resolves like outcome #3.
	s2 := e.stage(t, video, map[string]any{"filename": "IMG_1.MOV", "mime": "video/quicktime",
		"pair_role": "live_video", "pair_sha256": shaHex(still)})
	r2 := e.finalize(t, s2)
	if r2.Created || r2.AssetID != a.ID || exists(s2.StagingPath) {
		t.Fatalf("re-upload %+v", r2)
	}
}

// syncDirFails wraps an FS whose SyncDir always fails, as on some NAS mounts.
type syncDirFails struct{ storage.FS }

func (syncDirFails) SyncDir(string) error { return syscall.EINVAL }

func TestFinalizeCommitErrorAfterDurableMove(t *testing.T) {
	e := newFenv(t)
	e.fs = syncDirFails{storage.OS()}
	e.rebuild()
	s := e.stage(t, []byte("nas"), map[string]any{"filename": "a.jpg", "mime": "image/jpeg"})
	r := e.finalize(t, s)
	if !r.Created || e.session(t, s.ID).State != "done" {
		t.Fatal("durable move treated as failure")
	}
}

func TestFinalizeCommitFailureLeavesFinalizing(t *testing.T) {
	e := newFenv(t)
	e.fs = &storagetest.FaultFS{FS: storage.OS(), RenameErr: func(from, to string) error {
		return &os.LinkError{Op: "rename", Old: from, New: to, Err: syscall.EIO}
	}}
	e.rebuild()
	s := e.stage(t, []byte("io error"), map[string]any{"filename": "a.jpg", "mime": "image/jpeg"})
	_, err := e.fin.Finalize(ctx, s, s.SHA256)
	wantCode(t, err, "internal")
	if got := e.session(t, s.ID); got.State != "finalizing" {
		t.Fatalf("state = %q", got.State)
	}
	e.fs = storage.OS()
	e.rebuild()
	if err := e.fin.Recover(ctx); err != nil {
		t.Fatal(err)
	}
	if got := e.session(t, s.ID); got.State != "done" || !got.AssetCreated {
		t.Fatalf("after recovery %+v", got)
	}
}

func exdevFS() storage.FS {
	return &storagetest.FaultFS{FS: storage.OS(), RenameErr: func(from, to string) error {
		if filepath.Ext(from) == ".part" {
			return &os.LinkError{Op: "rename", Old: from, New: to, Err: syscall.EXDEV}
		}
		return nil
	}}
}

func TestFinalizeCrossVolume(t *testing.T) {
	e := newFenv(t)
	e.fs = exdevFS()
	e.rebuild()
	s := e.stage(t, []byte("across"), map[string]any{"filename": "a.jpg", "mime": "image/jpeg"})
	r := e.finalize(t, s)
	a, _ := e.assetBySHA(t, s.SHA256)
	if !r.Created || !exists(e.libPath(a.OriginalPath)) || len(e.strays(t)) != 0 {
		t.Fatalf("cross volume: strays %v", e.strays(t))
	}
}

// TestFinalizeCrashMatrix trips each failpoint (same and cross volume),
// discards the service, boots a new one, runs recovery and lets the client
// retry; it must converge to exactly one correct asset with no strays.
func TestFinalizeCrashMatrix(t *testing.T) {
	points := []string{FPBeforeTx1, FPAfterTx1, FPAfterCopy, FPAfterRename, FPAfterTx2}
	for _, cross := range []bool{false, true} {
		for _, fp := range points {
			name := fp
			if cross {
				name += "/cross"
			}
			t.Run(name, func(t *testing.T) {
				e := newFenv(t)
				if cross {
					e.fs = exdevFS()
				}
				e.fp = trip(fp)
				e.rebuild()
				content := fixture(t, "exif.jpg")
				s := e.stage(t, content, map[string]any{"filename": "IMG.JPG", "mime": "image/jpeg", "local_id": "L"})
				if _, err := e.fin.Finalize(ctx, s, s.SHA256); !errors.Is(err, errTripped) {
					t.Fatalf("err = %v, want tripped", err)
				}
				e.fp = nil
				e.rebuild()
				for i := 0; i < 2; i++ { // idempotent
					if err := e.fin.Recover(ctx); err != nil {
						t.Fatal(err)
					}
				}
				got := e.session(t, s.ID)
				if got.State == "receiving" { // crash before tx1: the client's retry re-runs finalize
					e.finalize(t, got)
					got = e.session(t, s.ID)
				}
				if got.State != "done" || got.AssetID == nil {
					t.Fatalf("session %+v", got)
				}
				a, ok := e.assetBySHA(t, s.SHA256)
				if !ok || a.ID != *got.AssetID || a.OriginalPath != "alice/2024/05/IMG.JPG" {
					t.Fatalf("asset %+v ok=%v", a, ok)
				}
				if b, err := os.ReadFile(e.libPath(a.OriginalPath)); err != nil || !bytes.Equal(b, content) {
					t.Fatal("library bytes wrong")
				}
				if s := e.strays(t); len(s) != 0 {
					t.Fatalf("strays %v", s)
				}
				res := e.reservations(t)
				if len(res) != 1 || res[0].AssetID == nil || *res[0].AssetID != a.ID {
					t.Fatalf("reservations %+v", res)
				}
				src, _ := repository.AssetSourcesRepository{}.ListByAsset(ctx, e.st.R, a.ID)
				if len(src) != 1 || src[0].LocalID != "L" {
					t.Fatalf("sources %+v", src)
				}
				if n := len(e.pendingJobs(t, "extract_metadata")); n != 1 {
					t.Fatalf("extract jobs %d", n)
				}
			})
		}
	}
}

// setFinalizing moves a staged session to finalizing at rel with a
// reservation, as tx1 would.
func (e *fenv) setFinalizing(t *testing.T, s repository.UploadSession, rel string) {
	t.Helper()
	up := s.ID
	if err := (repository.LibraryPathsRepository{}).Reserve(ctx, e.st.W, repository.LibraryPath{
		PathKey: storage.PathKey(rel), Path: rel, UserID: e.owner, UploadID: &up,
	}); err != nil {
		t.Fatal(err)
	}
	if err := (repository.UploadSessionsRepository{}).SetFinalizing(ctx, e.st.W, s.ID, rel, e.clk.Now()); err != nil {
		t.Fatal(err)
	}
}

func writeAt(t *testing.T, p string, b []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func (e *fenv) recoverTwice(t *testing.T) {
	t.Helper()
	for i := 0; i < 2; i++ {
		if err := e.fin.Recover(ctx); err != nil {
			t.Fatalf("Recover #%d: %v", i+1, err)
		}
	}
}

func TestRecoverDestValid(t *testing.T) {
	e := newFenv(t)
	content := []byte("dest is valid")
	s := e.stage(t, content, map[string]any{"filename": "a.jpg", "mime": "image/jpeg"})
	rel := "alice/2026/10/a.jpg"
	e.setFinalizing(t, s, rel)
	writeAt(t, e.libPath(rel), content) // staging still there too ("any")
	e.recoverTwice(t)
	got := e.session(t, s.ID)
	a, ok := e.assetBySHA(t, s.SHA256)
	if got.State != "done" || !ok || *got.AssetID != a.ID || a.OriginalPath != rel || exists(s.StagingPath) {
		t.Fatalf("session %+v asset %+v", got, a)
	}
	if len(e.changes(t)) != 1 || len(e.pendingJobs(t, "generate_thumbnails")) != 1 {
		t.Fatal("tx2 side effects missing or duplicated")
	}
}

func TestRecoverStagingOnly(t *testing.T) {
	e := newFenv(t)
	content := []byte("only staging is valid")
	s := e.stage(t, content, map[string]any{"filename": "a.jpg", "mime": "image/jpeg"})
	rel := "alice/2026/10/a.jpg"
	e.setFinalizing(t, s, rel)
	writeAt(t, e.libPath(rel), []byte("torn")) // invalid dest
	writeAt(t, e.libPath(rel)+".ptpart", []byte("half"))
	e.recoverTwice(t)
	got := e.session(t, s.ID)
	if got.State != "done" || !got.AssetCreated {
		t.Fatalf("session %+v", got)
	}
	if b, _ := os.ReadFile(e.libPath(rel)); !bytes.Equal(b, content) {
		t.Fatalf("dest = %q", b)
	}
	if s := e.strays(t); len(s) != 0 {
		t.Fatalf("strays %v", s)
	}
}

func TestRecoverNeither(t *testing.T) {
	e := newFenv(t)
	content := []byte("nothing valid")
	s := e.stage(t, content, map[string]any{"filename": "a.jpg", "mime": "image/jpeg"})
	rel := "alice/2026/10/a.jpg"
	e.setFinalizing(t, s, rel)
	writeAt(t, s.StagingPath, []byte("corrupt staging!!"))
	writeAt(t, e.libPath(rel), []byte("x"))
	e.recoverTwice(t)
	got := e.session(t, s.ID)
	if got.State != "failed" || got.FailureCode == nil || *got.FailureCode != "internal" {
		t.Fatalf("session %+v", got)
	}
	if len(e.reservations(t)) != 0 || exists(e.libPath(rel)) || len(e.strays(t)) != 0 {
		t.Fatalf("leftovers: res %v strays %v", e.reservations(t), e.strays(t))
	}
	if _, ok := e.assetBySHA(t, s.SHA256); ok {
		t.Fatal("asset created")
	}
}

func TestRecoverSweepsStrays(t *testing.T) {
	e := newFenv(t)
	live := e.stage(t, []byte("still receiving"), map[string]any{"filename": "a.jpg", "mime": "image/jpeg"})
	// A done session whose cross-volume copy left <dest>.ptpart behind (crash
	// after tx2 before the copy's cleanup is impossible, but a failed remove
	// is not).
	done := e.stage(t, []byte("done"), map[string]any{"filename": "d.jpg", "mime": "image/jpeg"})
	e.finalize(t, done)
	donePart := e.libPath(e.session(t, done.ID).DestPath) + ".ptpart"
	writeAt(t, donePart, []byte("x"))
	orphanStaging := filepath.Join(e.dataDir, "uploads", "01900000-0000-7000-8000-00000000abcd.part")
	writeAt(t, orphanStaging, []byte("x"))
	foreign := filepath.Join(e.dataDir, "uploads", "notes.txt")
	writeAt(t, foreign, []byte("not ours"))
	// No session references this one; recovery no longer walks the library,
	// so it stays (the purge_trash orphan sweep owns unreferenced files).
	unreferenced := e.libPath("alice/2020/01/x.jpg.ptpart")
	writeAt(t, unreferenced, []byte("x"))
	keep := e.libPath("alice/2020/01/keep.jpg")
	writeAt(t, keep, []byte("user file"))
	e.recoverTwice(t)
	if exists(orphanStaging) || exists(donePart) {
		t.Fatal("strays not swept")
	}
	if !exists(live.StagingPath) || !exists(keep) || !exists(foreign) || !exists(unreferenced) {
		t.Fatal("live staging, a foreign file or a library file was removed")
	}
	var names []string
	for _, p := range e.strays(t) {
		names = append(names, filepath.Base(p))
	}
	sort.Strings(names)
	want := []string{filepath.Base(live.StagingPath), "notes.txt", "x.jpg.ptpart"}
	sort.Strings(want)
	if strings.Join(names, ",") != strings.Join(want, ",") {
		t.Fatalf("remaining %v, want %v", names, want)
	}
}

func TestRecoverStuck(t *testing.T) {
	e := newFenv(t)
	old := e.stage(t, []byte("old"), map[string]any{"filename": "old.jpg", "mime": "image/jpeg"})
	e.setFinalizing(t, old, "alice/2026/10/old.jpg")
	e.clk.Advance(11 * time.Minute)
	fresh := e.stage(t, []byte("fresh"), map[string]any{"filename": "fresh.jpg", "mime": "image/jpeg"})
	e.setFinalizing(t, fresh, "alice/2026/10/fresh.jpg")
	if err := e.fin.RecoverStuck(ctx, 10*time.Minute); err != nil {
		t.Fatal(err)
	}
	if got := e.session(t, old.ID); got.State != "done" {
		t.Fatalf("old %q", got.State)
	}
	if got := e.session(t, fresh.ID); got.State != "finalizing" {
		t.Fatalf("fresh %q", got.State)
	}
}
