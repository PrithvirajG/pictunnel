package service

import (
	"bytes"
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
)

// hookFP runs an action at a named failpoint and lets the operation go on.
type hookFP map[string]func()

func (h hookFP) Hit(name string) error {
	if f := h[name]; f != nil {
		f()
	}
	return nil
}

func TestFinalizePtpartNamesSurviveRecover(t *testing.T) {
	e := newFenv(t)
	a := e.finalize(t, e.stage(t, []byte("lower"), map[string]any{"filename": "x.ptpart", "mime": "image/jpeg"}))
	b := e.finalize(t, e.stage(t, []byte("upper"), map[string]any{"filename": "X.PTPART", "mime": "image/jpeg"}))
	e.recoverTwice(t)
	for id, want := range map[string]string{a.AssetID: "lower", b.AssetID: "upper"} {
		as, err := repository.AssetsRepository{}.GetByID(ctx, e.st.R, id)
		if err != nil {
			t.Fatal(err)
		}
		if strings.HasSuffix(strings.ToLower(as.OriginalPath), ".ptpart") {
			t.Fatalf("stored with reserved suffix: %q", as.OriginalPath)
		}
		if got, err := os.ReadFile(e.libPath(as.OriginalPath)); err != nil || string(got) != want {
			t.Fatalf("%s: %q %v", as.OriginalPath, got, err)
		}
	}
}

func TestFinalizeCrossVolumeKeepsExistingPtpartNamedFile(t *testing.T) {
	e := newFenv(t)
	e.fs = exdevFS()
	e.rebuild()
	// A file already in the library whose name equals <dest>.ptpart for an
	// upload named "y" (e.g. placed by the user before PicTunnel managed it).
	user := e.libPath("alice/2026/10/y.ptpart")
	writeAt(t, user, []byte("precious"))
	r := e.finalize(t, e.stage(t, []byte("new y"), map[string]any{"filename": "y", "mime": "image/jpeg"}))
	e.recoverTwice(t)
	a, _ := repository.AssetsRepository{}.GetByID(ctx, e.st.R, r.AssetID)
	if a.OriginalPath != "alice/2026/10/y~2" {
		t.Fatalf("path = %q, want y~2 (y.ptpart is occupied)", a.OriginalPath)
	}
	if got, err := os.ReadFile(user); err != nil || string(got) != "precious" {
		t.Fatalf("existing file damaged: %q %v", got, err)
	}
}

func TestFinalizeTx2UniqueConflict(t *testing.T) {
	e := newFenv(t)
	content := []byte("raced content")
	otherRel := "alice/other/z.jpg"
	writeAt(t, e.libPath(otherRel), content)
	var other repository.Asset
	e.fp = hookFP{FPAfterCopy: func() {
		// Another path created the same (owner, sha) asset after tx1.
		other = repository.Asset{
			ID: "01900000-0000-7000-8000-000000000001", OwnerID: e.owner, SHA256: shaHex(content),
			SizeBytes: int64(len(content)), Mime: "image/jpeg", Kind: "photo", Filename: "z.jpg",
			OriginalPath: otherRel, TakenAtSource: "unknown", State: "active", CreatedAt: fT0,
		}
		if err := (repository.AssetsRepository{}).Insert(ctx, e.st.W, other); err != nil {
			t.Error(err)
		}
	}}
	e.rebuild()
	s := e.stage(t, content, map[string]any{"filename": "a.jpg", "mime": "image/jpeg", "local_id": "L"})
	r := e.finalize(t, s)
	if r.Created || r.AssetID != other.ID {
		t.Fatalf("result %+v", r)
	}
	if exists(e.libPath("alice/2026/10/a.jpg")) {
		t.Fatal("moved file not removed")
	}
	if got, _ := os.ReadFile(e.libPath(otherRel)); !bytes.Equal(got, content) {
		t.Fatal("other asset's file damaged")
	}
	if res := e.reservations(t); len(res) != 0 {
		t.Fatalf("reservation not released: %+v", res)
	}
	got := e.session(t, s.ID)
	if got.State != "done" || got.AssetCreated || *got.AssetID != other.ID {
		t.Fatalf("session %+v", got)
	}
	src, _ := repository.AssetSourcesRepository{}.ListByAsset(ctx, e.st.R, other.ID)
	if len(src) != 1 || src[0].LocalID != "L" {
		t.Fatalf("sources %+v", src)
	}
	if len(e.changes(t)) != 0 || len(e.pendingJobs(t, JobExtractMetadata)) != 0 {
		t.Fatal("tx2 side effects of the discarded insert leaked")
	}
}

func TestFinalizeLivePrimaryPurgedBeforeTx2(t *testing.T) {
	e := newFenv(t)
	still := fixture(t, "exif.jpg")
	p := e.finalize(t, e.stage(t, still, map[string]any{"filename": "IMG_1.HEIC", "mime": "image/heic"}))
	primary, _ := repository.AssetsRepository{}.GetByID(ctx, e.st.R, p.AssetID)
	e.fp = hookFP{FPAfterTx1: func() {
		if err := (repository.AssetsRepository{}).Delete(ctx, e.st.W, p.AssetID); err != nil {
			t.Error(err)
		}
	}}
	e.rebuild()
	s := e.stage(t, []byte("video"), map[string]any{"filename": "IMG_1.MOV", "mime": "video/quicktime",
		"pair_role": "live_video", "pair_sha256": shaHex(still)})
	_, err := e.fin.Finalize(ctx, s, s.SHA256)
	wantCode(t, err, "pair_primary_missing")
	if got := e.session(t, s.ID); got.State != "failed" || *got.FailureCode != "pair_primary_missing" {
		t.Fatalf("session %+v", got)
	}
	if exists(e.libPath("alice/2024/05/IMG_1.MOV")) || exists(s.StagingPath) {
		t.Fatal("moved file or staging left")
	}
	for _, r := range e.reservations(t) {
		if r.UploadID != nil && *r.UploadID == s.ID {
			t.Fatalf("reservation not released: %+v", r)
		}
	}
	if got, _ := os.ReadFile(e.libPath(primary.OriginalPath)); !bytes.Equal(got, still) {
		t.Fatal("primary file damaged")
	}
}

func TestFinalizeDigestMismatchOnlyFailsReceiving(t *testing.T) {
	e := newFenv(t)
	s := e.stage(t, []byte("abc"), map[string]any{"filename": "a.jpg", "mime": "image/jpeg"})
	e.setFinalizing(t, s, "alice/2026/10/a.jpg")
	_, err := e.fin.Finalize(ctx, s, shaHex([]byte("zzz")))
	wantCode(t, err, "checksum_mismatch")
	if got := e.session(t, s.ID); got.State != "finalizing" {
		t.Fatalf("state = %q", got.State)
	}
	if !exists(s.StagingPath) {
		t.Fatal("staging of a finalizing session removed")
	}
}

// failingFS fails Open (and optionally Stat) for paths containing match.
type failingFS struct {
	storage.FS
	match    string
	failStat bool
}

func (f failingFS) Open(name string) (storage.File, error) {
	if strings.Contains(filepath.ToSlash(name), f.match) {
		return nil, &os.PathError{Op: "open", Path: name, Err: syscall.EIO}
	}
	return f.FS.Open(name)
}

func (f failingFS) Stat(name string) (os.FileInfo, error) {
	if f.failStat && strings.Contains(filepath.ToSlash(name), f.match) {
		return nil, &os.PathError{Op: "stat", Path: name, Err: syscall.EACCES}
	}
	return f.FS.Stat(name)
}

func TestRecoverReadErrorKeepsOnlyCopy(t *testing.T) {
	e := newFenv(t)
	content := []byte("the only copy")
	s := e.stage(t, content, map[string]any{"filename": "a.jpg", "mime": "image/jpeg"})
	rel := "alice/2026/10/a.jpg"
	e.setFinalizing(t, s, rel)
	writeAt(t, e.libPath(rel), content)
	os.Remove(s.StagingPath)
	e.fs = failingFS{FS: storage.OS(), match: "/library/alice/"}
	e.rebuild()
	if err := e.fin.Recover(ctx); err == nil {
		t.Fatal("Recover hid a read error")
	}
	if got := e.session(t, s.ID); got.State != "finalizing" {
		t.Fatalf("state = %q", got.State)
	}
	if b, _ := os.ReadFile(e.libPath(rel)); !bytes.Equal(b, content) {
		t.Fatal("only copy deleted on a transient read error")
	}
	e.fs = storage.OS()
	e.rebuild()
	e.recoverTwice(t)
	if got := e.session(t, s.ID); got.State != "done" {
		t.Fatalf("after retry state = %q", got.State)
	}
}

func TestRecoverLibraryRootMissing(t *testing.T) {
	e := newFenv(t)
	s := e.stage(t, []byte("x"), map[string]any{"filename": "a.jpg", "mime": "image/jpeg"})
	e.setFinalizing(t, s, "alice/2026/10/a.jpg")
	e.libDir = filepath.Join(e.libDir, "unmounted")
	e.rebuild()
	if err := e.fin.Recover(ctx); err == nil {
		t.Fatal("Recover ran with the library root missing")
	}
	if got := e.session(t, s.ID); got.State != "finalizing" || !exists(s.StagingPath) {
		t.Fatalf("state %q staging %v", got.State, exists(s.StagingPath))
	}
	if exists(e.libDir) {
		t.Fatal("recovery created the missing library root")
	}
}

func TestRecoverStaleSessionRereadsState(t *testing.T) {
	e := newFenv(t)
	s := e.stage(t, []byte("done already"), map[string]any{"filename": "a.jpg", "mime": "image/jpeg"})
	r := e.finalize(t, s)
	stale := s
	stale.State, stale.DestPath = "finalizing", "alice/2026/10/missing.jpg"
	if err := e.fin.recoverOne(ctx, stale); err != nil {
		t.Fatal(err)
	}
	got := e.session(t, s.ID)
	if got.State != "done" || *got.AssetID != r.AssetID {
		t.Fatalf("stale recovery changed a done session: %+v", got)
	}
}

func TestAssignStatErrorIsReturned(t *testing.T) {
	e := newFenv(t)
	e.fs = failingFS{FS: storage.OS(), match: "/locked/", failStat: true}
	e.rebuild()
	err := e.st.WithTx(ctx, func(tx *sql.Tx) error {
		_, err := e.lib.Assign(ctx, tx, AssignInput{UserID: e.owner, UserSlug: "locked", Filename: "a.jpg", Date: may2024, UploadID: "u"})
		return err
	})
	if err == nil {
		t.Fatal("Stat error swallowed")
	}
}

// TestFinalizeLongNameNeverEndsInPtpart is the re-review reproduction: an
// over-long "extension" makes the whole name the stem, and truncation to
// 240 bytes could cut right after ".ptpart", putting asset A at <B>.ptpart.
func TestFinalizeLongNameNeverEndsInPtpart(t *testing.T) {
	for _, cross := range []bool{false, true} {
		t.Run(map[bool]string{false: "same", true: "cross"}[cross], func(t *testing.T) {
			e := newFenv(t)
			if cross {
				e.fs = exdevFS()
				e.rebuild()
			}
			nameB := strings.Repeat("a", 218)
			nameA := strings.Repeat("a", 218) + ".ptpart." + strings.Repeat("x", 20)
			rb := e.finalize(t, e.stage(t, []byte("asset B"), map[string]any{"filename": nameB, "mime": "image/jpeg"}))
			ra := e.finalize(t, e.stage(t, []byte("asset A"), map[string]any{"filename": nameA, "mime": "image/jpeg"}))
			e.recoverTwice(t)
			for id, want := range map[string]string{rb.AssetID: "asset B", ra.AssetID: "asset A"} {
				a, err := repository.AssetsRepository{}.GetByID(ctx, e.st.R, id)
				if err != nil {
					t.Fatal(err)
				}
				if strings.HasSuffix(strings.ToLower(a.OriginalPath), ".ptpart") || len(a.OriginalPath) >= 240 {
					t.Fatalf("bad path %q (%d bytes)", a.OriginalPath, len(a.OriginalPath))
				}
				if got, err := os.ReadFile(e.libPath(a.OriginalPath)); err != nil || string(got) != want {
					t.Fatalf("%s: %q %v", a.OriginalPath, got, err)
				}
			}
		})
	}
}

func TestAssignRejectsPtpartAfterTruncation(t *testing.T) {
	e := newFenv(t)
	name := strings.Repeat("b", 218) + ".PtPart." + strings.Repeat("y", 20)
	got := e.assign(t, AssignInput{Filename: name, Date: may2024, UploadID: "u1"})
	if strings.HasSuffix(strings.ToLower(got), ".ptpart") || len(got) >= 240 {
		t.Fatalf("rel %q", got)
	}
}
