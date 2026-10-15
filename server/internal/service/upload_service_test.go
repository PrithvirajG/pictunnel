package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/ids"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

// fakeFree is a settable storage.FreeSpaceFunc.
type fakeFree struct {
	mu    sync.Mutex
	bytes uint64
	paths []string
}

func (f *fakeFree) fn(path string) (uint64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.paths = append(f.paths, path)
	return f.bytes, nil
}

func (f *fakeFree) set(b uint64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.bytes = b
}

// uenv is an upload test environment on top of the finalize environment.
type uenv struct {
	*fenv
	free *fakeFree
	up   *UploadService
	p    Principal
}

const testReserve = 1 << 20

func newUenv(t *testing.T) *uenv {
	t.Helper()
	e := &uenv{fenv: newFenv(t), free: &fakeFree{bytes: 1 << 40}}
	e.p = Principal{UserID: e.owner, Username: "alice", Slug: "alice", Role: "admin", DeviceID: e.device, Platform: "android", Via: ViaBearer}
	e.buildUpload()
	return e
}

func (e *uenv) buildUpload() {
	e.up = NewUploadService(UploadServiceDeps{
		Store: e.st, Sessions: repository.UploadSessionsRepository{}, Assets: repository.AssetsRepository{},
		LiveVideos: repository.LiveVideosRepository{}, Tombstones: repository.TombstonesRepository{},
		Users: repository.UsersRepository{}, AssetSources: repository.AssetSourcesRepository{},
		Finalize: e.fin, FS: e.fs, FreeSpace: e.free.fn, Clock: e.clk, Failpoints: e.fp,
		Cfg:     UploadConfig{MaxFileBytes: 64 << 20, ReserveBytes: testReserve, LockWait: 2 * time.Second},
		DataDir: e.dataDir, LibraryDir: e.libDir,
		Log: slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
}

// restart rebuilds every service over the same store and dirs.
func (e *uenv) restart() {
	e.rebuild()
	e.buildUpload()
}

func payload(n int, seed byte) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(i*7) + seed
	}
	return b
}

func metaFor(content []byte, name string) UploadMeta {
	return UploadMeta{SHA256: shaHex(content), Filename: name, Mime: "image/jpeg", PairRole: "primary"}
}

func wantUpCode(t *testing.T, err error, code string) *apperr.Error {
	t.Helper()
	ae, ok := apperr.As(err)
	if !ok || ae.Code != code {
		t.Fatalf("want %s, got %v", code, err)
	}
	return ae
}

func (e *uenv) create(t *testing.T, content []byte, withBody bool) UploadView {
	t.Helper()
	in := CreateInput{Length: int64(len(content)), Meta: metaFor(content, "IMG_0001.JPG")}
	if withBody {
		in.Body = bytes.NewReader(content)
	}
	v, err := e.up.Create(ctx, e.p, in)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	return v
}

func (e *uenv) stagingFile(id string) string {
	return filepath.Join(e.dataDir, "uploads", id+".part")
}

func (e *uenv) seedAsset(t *testing.T, content []byte) repository.UploadSession {
	t.Helper()
	s := e.stage(t, content, map[string]any{"filename": "seed.jpg", "mime": "image/jpeg"})
	e.finalize(t, s)
	return s
}

func checkDone(t *testing.T, v UploadView, created bool) {
	t.Helper()
	if !v.Done || v.AssetID == "" || v.AssetCreated != created || v.Offset != v.Length {
		t.Fatalf("view %+v", v)
	}
}

// --- POST precedence ---

func TestCreateOutcome1FileTooLarge(t *testing.T) {
	e := newUenv(t)
	// A tombstone too: #1 wins over #2.
	sha := shaHex([]byte("x"))
	repository.TombstonesRepository{}.Insert(ctx, e.st.W, repository.Tombstone{OwnerID: e.owner, SHA256: sha, Filename: "x", DeletedAt: fT0})
	_, err := e.up.Create(ctx, e.p, CreateInput{Length: 64<<20 + 1, Meta: UploadMeta{SHA256: sha, Filename: "x", Mime: "image/png"}})
	ae := wantUpCode(t, err, "file_too_large")
	if ae.Extra["max_file_bytes"] != int64(64<<20) {
		t.Fatalf("extra %+v", ae.Extra)
	}
}

func TestCreateOutcome2Tombstoned(t *testing.T) {
	e := newUenv(t)
	content := payload(1000, 1)
	repository.TombstonesRepository{}.Insert(ctx, e.st.W, repository.Tombstone{OwnerID: e.owner, SHA256: shaHex(content), Filename: "x", DeletedAt: fT0})
	e.free.set(0) // #2 wins over #6
	_, err := e.up.Create(ctx, e.p, CreateInput{Length: 1000, Meta: metaFor(content, "a.jpg"), Body: bytes.NewReader(content)})
	wantUpCode(t, err, "tombstoned")
	if len(e.strays(t)) != 0 {
		t.Fatalf("strays %v", e.strays(t))
	}
	// Override uploads it and clears the tombstone.
	e.free.set(1 << 40)
	m := metaFor(content, "a.jpg")
	m.OverrideTombstone = true
	v, err := e.up.Create(ctx, e.p, CreateInput{Length: 1000, Meta: m, Body: bytes.NewReader(content)})
	if err != nil {
		t.Fatal(err)
	}
	checkDone(t, v, true)
	if _, err := (repository.TombstonesRepository{}).Get(ctx, e.st.R, e.owner, shaHex(content)); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("tombstone remains: %v", err)
	}
}

func TestCreateOutcome3AssetExists(t *testing.T) {
	e := newUenv(t)
	content := payload(2000, 2)
	s := e.seedAsset(t, content)
	a, _ := e.assetBySHA(t, s.SHA256)
	e.free.set(0) // #3 wins over #6
	m := metaFor(content, "copy.jpg")
	m.LocalID = "L9"
	v, err := e.up.Create(ctx, e.p, CreateInput{Length: 2000, Meta: m, Body: bytes.NewReader(content)})
	if err != nil {
		t.Fatal(err)
	}
	checkDone(t, v, false)
	if v.AssetID != a.ID || v.ID == "" {
		t.Fatalf("view %+v", v)
	}
	h, err := e.up.Head(ctx, e.p, v.ID)
	if err != nil {
		t.Fatal(err)
	}
	checkDone(t, h, false)
	if h.AssetID != a.ID {
		t.Fatalf("head %+v", h)
	}
	src, _ := repository.AssetSourcesRepository{}.ListByAsset(ctx, e.st.R, a.ID)
	if len(src) != 1 || src[0].LocalID != "L9" {
		t.Fatalf("sources %+v", src)
	}
	if len(e.strays(t)) != 0 {
		t.Fatalf("strays %v", e.strays(t))
	}
	// A different declared length for existing content is a client bug.
	_, err = e.up.Create(ctx, e.p, CreateInput{Length: 2001, Meta: m})
	wantUpCode(t, err, "length_mismatch")
}

func TestCreateOutcome3LiveVideo(t *testing.T) {
	e := newUenv(t)
	still := payload(1500, 3)
	video := payload(1700, 4)
	lm := UploadMeta{SHA256: shaHex(video), Filename: "IMG.MOV", Mime: "video/quicktime", PairRole: "live_video", PairSHA256: shaHex(still)}

	// pair_primary_missing before the primary exists; nothing stored.
	_, err := e.up.Create(ctx, e.p, CreateInput{Length: 1700, Meta: lm, Body: bytes.NewReader(video)})
	wantUpCode(t, err, "pair_primary_missing")
	if len(e.strays(t)) != 0 {
		t.Fatalf("strays %v", e.strays(t))
	}

	pv := e.create(t, still, true)
	checkDone(t, pv, true)
	v, err := e.up.Create(ctx, e.p, CreateInput{Length: 1700, Meta: lm, Body: bytes.NewReader(video)})
	if err != nil {
		t.Fatal(err)
	}
	checkDone(t, v, true)
	if v.AssetID != pv.AssetID {
		t.Fatalf("live attached to %s, want %s", v.AssetID, pv.AssetID)
	}
	// Re-uploading the attached component resolves like outcome #3.
	v2, err := e.up.Create(ctx, e.p, CreateInput{Length: 1700, Meta: lm})
	if err != nil {
		t.Fatal(err)
	}
	checkDone(t, v2, false)
	if v2.AssetID != pv.AssetID || v2.ID == v.ID {
		t.Fatalf("view %+v", v2)
	}
}

func TestCreateOutcome4ActiveSession(t *testing.T) {
	e := newUenv(t)
	content := payload(5000, 5)
	v1 := e.create(t, content, false)
	if v1.Offset != 0 || v1.Done {
		t.Fatalf("v1 %+v", v1)
	}
	if _, err := e.up.Append(ctx, e.p, v1.ID, 0, bytes.NewReader(content[:1000]), nil); err != nil {
		t.Fatal(err)
	}
	e.free.set(0) // #4 wins over #6
	v2, err := e.up.Create(ctx, e.p, CreateInput{Length: 5000, Meta: metaFor(content, "b.jpg"), Body: bytes.NewReader(content)})
	if err != nil {
		t.Fatal(err)
	}
	// Offset is not 0, so the body is discarded.
	if v2.ID != v1.ID || v2.Offset != 1000 || v2.Done {
		t.Fatalf("v2 %+v", v2)
	}
	if fi, _ := os.Stat(e.stagingFile(v1.ID)); fi.Size() != 1000 {
		t.Fatalf("staging size %d", fi.Size())
	}
}

func TestCreateOutcome4AppendsAtZero(t *testing.T) {
	e := newUenv(t)
	content := payload(5000, 6)
	v1 := e.create(t, content, false)
	v2, err := e.up.Create(ctx, e.p, CreateInput{Length: 5000, Meta: metaFor(content, "b.jpg"), Body: bytes.NewReader(content)})
	if err != nil {
		t.Fatal(err)
	}
	if v2.ID != v1.ID {
		t.Fatalf("v2 %+v", v2)
	}
	checkDone(t, v2, true)
}

func TestCreateOutcome5QuotaExceeded(t *testing.T) {
	e := newUenv(t)
	q := int64(10000)
	if _, err := e.st.W.ExecContext(ctx, "UPDATE users SET quota_bytes = ? WHERE id = ?", q, e.owner); err != nil {
		t.Fatal(err)
	}
	e.seedAsset(t, payload(3000, 7))     // 3000 used by an asset
	e.create(t, payload(4000, 8), false) // 4000 reserved by an active session
	e.free.set(0)                        // #5 wins over #6
	_, err := e.up.Create(ctx, e.p, CreateInput{Length: 3001, Meta: metaFor(payload(3001, 9), "c.jpg")})
	wantUpCode(t, err, "quota_exceeded")
	e.free.set(1 << 40)
	if _, err := e.up.Create(ctx, e.p, CreateInput{Length: 3000, Meta: metaFor(payload(3000, 9), "c.jpg")}); err != nil {
		t.Fatalf("exactly at quota: %v", err)
	}
}

func TestCreateOutcome6InsufficientStorage(t *testing.T) {
	e := newUenv(t)
	content := payload(4096, 10)
	e.free.set(4096 + testReserve - 1)
	_, err := e.up.Create(ctx, e.p, CreateInput{Length: 4096, Meta: metaFor(content, "d.jpg")})
	wantUpCode(t, err, "insufficient_storage")
	if len(e.strays(t)) != 0 {
		t.Fatal("staging created")
	}
	// Both the staging volume and the library volume are probed.
	var sawStaging, sawLib bool
	for _, p := range e.free.paths {
		sawStaging = sawStaging || filepath.Clean(p) == filepath.Join(e.dataDir, "uploads")
		sawLib = sawLib || filepath.Clean(p) == filepath.Clean(e.libDir)
	}
	if !sawStaging || !sawLib {
		t.Fatalf("probed %v", e.free.paths)
	}
	e.free.set(4096 + testReserve)
	if _, err := e.up.Create(ctx, e.p, CreateInput{Length: 4096, Meta: metaFor(content, "d.jpg")}); err != nil {
		t.Fatal(err)
	}
}

func TestCreateOutcome7NewSession(t *testing.T) {
	e := newUenv(t)
	content := payload(4096, 11)
	v := e.create(t, content, false)
	if v.ID == "" || v.Offset != 0 || v.Length != 4096 || v.Done || !v.ExpiresAt.Equal(fT0.Add(24*time.Hour)) {
		t.Fatalf("view %+v", v)
	}
	s := e.session(t, v.ID)
	if s.State != "receiving" || s.DeviceID != e.device || s.SHA256 != shaHex(content) || s.PairRole == nil || *s.PairRole != "primary" {
		t.Fatalf("session %+v", s)
	}
	if fi, err := os.Stat(e.stagingFile(v.ID)); err != nil || fi.Size() != 0 {
		t.Fatalf("staging %v", err)
	}
	meta, err := parseSessionMeta(s)
	if err != nil || meta.SHA256 != s.SHA256 || meta.Filename != "IMG_0001.JPG" || meta.Mime != "image/jpeg" {
		t.Fatalf("meta %+v %v", meta, err)
	}
}

func TestCreateWithBodyFinalizes(t *testing.T) {
	e := newUenv(t)
	content := payload(9000, 12)
	v := e.create(t, content, true)
	checkDone(t, v, true)
	a, ok := e.assetBySHA(t, shaHex(content))
	if !ok || a.ID != v.AssetID {
		t.Fatal("asset missing")
	}
	b, _ := os.ReadFile(e.libPath(a.OriginalPath))
	if !bytes.Equal(b, content) {
		t.Fatal("library bytes differ")
	}
	if len(e.strays(t)) != 0 || e.up.locks.count() != 0 {
		t.Fatalf("strays %v locks %d", e.strays(t), e.up.locks.count())
	}
}

func TestCreateWithPartialBody(t *testing.T) {
	e := newUenv(t)
	content := payload(9000, 13)
	v, err := e.up.Create(ctx, e.p, CreateInput{Length: 9000, Meta: metaFor(content, "p.jpg"), Body: bytes.NewReader(content[:4000])})
	if err != nil || v.Offset != 4000 || v.Done {
		t.Fatalf("%+v %v", v, err)
	}
}

func TestCreateWithBodyChecksumMismatch(t *testing.T) {
	e := newUenv(t)
	content := payload(9000, 14)
	m := metaFor(content, "p.jpg")
	m.SHA256 = shaHex([]byte("other"))
	_, err := e.up.Create(ctx, e.p, CreateInput{Length: 9000, Meta: m, Body: bytes.NewReader(content)})
	wantUpCode(t, err, "checksum_mismatch")
	if len(e.strays(t)) != 0 || e.up.locks.count() != 0 {
		t.Fatal("leftovers")
	}
}

func TestCreateEmptyFile(t *testing.T) {
	e := newUenv(t)
	v := e.create(t, []byte{}, false)
	checkDone(t, v, true)
}

func TestCreateDuplicateReturnsSameSession(t *testing.T) {
	e := newUenv(t)
	content := payload(1<<20, 15)
	v1 := e.create(t, content, false)
	v2 := e.create(t, content, false)
	if v1.ID != v2.ID || v2.Offset != 0 {
		t.Fatalf("%+v %+v", v1, v2)
	}
}

func TestCreateDuplicateLengthMismatch(t *testing.T) {
	e := newUenv(t)
	content := payload(1<<20, 16)
	e.create(t, content, false)
	_, err := e.up.Create(ctx, e.p, CreateInput{Length: 1<<20 + 1, Meta: metaFor(content, "IMG_0001.JPG")})
	wantUpCode(t, err, "length_mismatch")
}

func TestCreateConcurrentSameContent(t *testing.T) {
	e := newUenv(t)
	content := payload(3000, 17)
	var wg sync.WaitGroup
	got := make([]string, 8)
	for i := range got {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			v, err := e.up.Create(ctx, e.p, CreateInput{Length: 3000, Meta: metaFor(content, "x.jpg")})
			if err != nil {
				t.Error(err)
				return
			}
			got[i] = v.ID
		}(i)
	}
	wg.Wait()
	for _, id := range got {
		if id != got[0] {
			t.Fatalf("ids %v", got)
		}
	}
}

// --- PATCH ---

func TestAppendChunksFinalize(t *testing.T) {
	e := newUenv(t)
	content := payload(10000, 18)
	v := e.create(t, content, false)
	e.clk.Advance(time.Hour)
	v, err := e.up.Append(ctx, e.p, v.ID, 0, bytes.NewReader(content[:3000]), nil)
	if err != nil || v.Offset != 3000 || !v.ExpiresAt.Equal(fT0.Add(25*time.Hour)) {
		t.Fatalf("%+v %v", v, err)
	}
	// The body may be longer than the remainder; only length-offset is read.
	v, err = e.up.Append(ctx, e.p, v.ID, 3000, bytes.NewReader(append(append([]byte{}, content[3000:]...), 1, 2, 3)), nil)
	if err != nil {
		t.Fatal(err)
	}
	checkDone(t, v, true)
	// A PATCH on a done session returns its view.
	v2, err := e.up.Append(ctx, e.p, v.ID, 10000, bytes.NewReader(nil), nil)
	if err != nil {
		t.Fatal(err)
	}
	checkDone(t, v2, true)
	if e.up.locks.count() != 0 {
		t.Fatalf("locks %d", e.up.locks.count())
	}
}

func TestAppendOffsetMismatch(t *testing.T) {
	e := newUenv(t)
	content := payload(10000, 19)
	v := e.create(t, content, false)
	e.up.Append(ctx, e.p, v.ID, 0, bytes.NewReader(content[:500]), nil)
	_, err := e.up.Append(ctx, e.p, v.ID, 100, bytes.NewReader(content[100:]), nil)
	ae := wantUpCode(t, err, "offset_mismatch")
	if ae.Headers.Get("Upload-Offset") != "500" {
		t.Fatalf("headers %v", ae.Headers)
	}
}

// dropReader yields n bytes of data then fails like a dropped connection.
type dropReader struct {
	r      io.Reader
	n      int
	onDrop func()
}

var errDropped = errors.New("connection reset")

func (d *dropReader) Read(p []byte) (int, error) {
	if d.n <= 0 {
		if d.onDrop != nil {
			d.onDrop()
		}
		return 0, errDropped
	}
	if len(p) > d.n {
		p = p[:d.n]
	}
	n, err := d.r.Read(p)
	d.n -= n
	return n, err
}

func TestAppendDropKeepsBytes(t *testing.T) {
	e := newUenv(t)
	content := payload(3<<20, 20)
	v := e.create(t, content, false)
	cctx, cancel := context.WithCancel(ctx)
	// The request context ends with the connection; the offset still commits.
	got, err := e.up.Append(cctx, e.p, v.ID, 0, &dropReader{r: bytes.NewReader(content), n: 1000000, onDrop: cancel}, nil)
	if !errors.Is(err, errDropped) || got.Offset != 1000000 {
		t.Fatalf("%+v %v", got, err)
	}
	h, err := e.up.Head(ctx, e.p, v.ID)
	if err != nil || h.Offset != 1000000 || h.Length != 3<<20 {
		t.Fatalf("head %+v %v", h, err)
	}
	f, err := e.up.Append(ctx, e.p, v.ID, h.Offset, bytes.NewReader(content[h.Offset:]), nil)
	if err != nil {
		t.Fatal(err)
	}
	checkDone(t, f, true)
}

func TestAppendResumeAfterRestart(t *testing.T) {
	e := newUenv(t)
	content := payload(2<<20, 21)
	v := e.create(t, content, false)
	if _, err := e.up.Append(ctx, e.p, v.ID, 0, bytes.NewReader(content[:700000]), nil); err != nil {
		t.Fatal(err)
	}
	// Junk past the committed offset (a crash after write, before commit).
	f, _ := os.OpenFile(e.stagingFile(v.ID), os.O_WRONLY|os.O_APPEND, 0)
	f.Write([]byte("garbage beyond the committed offset"))
	f.Close()
	e.restart()
	got, err := e.up.Append(ctx, e.p, v.ID, 700000, bytes.NewReader(content[700000:]), nil)
	if err != nil {
		t.Fatal(err)
	}
	checkDone(t, got, true)
	a, _ := e.assetBySHA(t, shaHex(content))
	b, _ := os.ReadFile(e.libPath(a.OriginalPath))
	if !bytes.Equal(b, content) {
		t.Fatal("bytes differ")
	}
}

func TestAppendStagingShorterFails(t *testing.T) {
	e := newUenv(t)
	content := payload(5000, 22)
	v := e.create(t, content, false)
	e.up.Append(ctx, e.p, v.ID, 0, bytes.NewReader(content[:3000]), nil)
	os.Truncate(e.stagingFile(v.ID), 1000)
	e.restart()
	_, err := e.up.Append(ctx, e.p, v.ID, 3000, bytes.NewReader(content[3000:]), nil)
	wantUpCode(t, err, "not_found")
	if s := e.session(t, v.ID); s.State != "failed" {
		t.Fatalf("state %s", s.State)
	}
	if exists(e.stagingFile(v.ID)) || e.up.locks.count() != 0 {
		t.Fatal("leftovers")
	}
}

func TestAppendChecksum(t *testing.T) {
	e := newUenv(t)
	content := payload(5000, 23)
	v := e.create(t, content, false)
	bad := sha256.Sum256([]byte("nope"))
	_, err := e.up.Append(ctx, e.p, v.ID, 0, bytes.NewReader(content[:2000]), bad[:])
	wantUpCode(t, err, "checksum_mismatch")
	if fi, _ := os.Stat(e.stagingFile(v.ID)); fi.Size() != 0 {
		t.Fatalf("not truncated: %d", fi.Size())
	}
	if s := e.session(t, v.ID); s.Offset != 0 || s.State != "receiving" {
		t.Fatalf("session %+v", s)
	}
	good := sha256.Sum256(content[:2000])
	got, err := e.up.Append(ctx, e.p, v.ID, 0, bytes.NewReader(content[:2000]), good[:])
	if err != nil || got.Offset != 2000 {
		t.Fatalf("%+v %v", got, err)
	}
	rest := sha256.Sum256(content[2000:])
	got, err = e.up.Append(ctx, e.p, v.ID, 2000, bytes.NewReader(content[2000:]), rest[:])
	if err != nil {
		t.Fatal(err)
	}
	checkDone(t, got, true)
}

func TestAppendFinalizeChecksumMismatch(t *testing.T) {
	e := newUenv(t)
	content := payload(5000, 24)
	m := metaFor(content, "x.jpg")
	m.SHA256 = shaHex([]byte("declared"))
	v, err := e.up.Create(ctx, e.p, CreateInput{Length: 5000, Meta: m})
	if err != nil {
		t.Fatal(err)
	}
	_, err = e.up.Append(ctx, e.p, v.ID, 0, bytes.NewReader(content), nil)
	wantUpCode(t, err, "checksum_mismatch")
	_, err = e.up.Head(ctx, e.p, v.ID)
	wantUpCode(t, err, "not_found")
	if len(e.strays(t)) != 0 || e.up.locks.count() != 0 {
		t.Fatal("leftovers")
	}
}

func TestConcurrentAppendLocked(t *testing.T) {
	e := newUenv(t)
	content := payload(5000, 25)
	v := e.create(t, content, false)
	pr, pw := io.Pipe()
	done := make(chan error, 1)
	go func() {
		_, err := e.up.Append(ctx, e.p, v.ID, 0, pr, nil)
		done <- err
	}()
	if _, err := pw.Write(content[:100]); err != nil { // returns once the first Append is reading
		t.Fatal(err)
	}
	_, err := e.up.Append(ctx, e.p, v.ID, 0, bytes.NewReader(content), nil)
	wantUpCode(t, err, "upload_locked")
	err = e.up.Terminate(ctx, e.p, v.ID)
	wantUpCode(t, err, "upload_locked")
	pw.Write(content[100:])
	pw.Close()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	h, err := e.up.Head(ctx, e.p, v.ID)
	if err != nil {
		t.Fatal(err)
	}
	checkDone(t, h, true)
}

func TestHeadWaitsForInflightAppend(t *testing.T) {
	e := newUenv(t)
	content := payload(5000, 26)
	v := e.create(t, content, false)
	pr, pw := io.Pipe()
	done := make(chan struct{})
	go func() {
		e.up.Append(ctx, e.p, v.ID, 0, pr, nil)
		close(done)
	}()
	pw.Write(content[:1234])
	go func() {
		time.Sleep(50 * time.Millisecond)
		pw.CloseWithError(errDropped)
	}()
	h, err := e.up.Head(ctx, e.p, v.ID)
	if err != nil || h.Offset != 1234 {
		t.Fatalf("head %+v %v", h, err)
	}
	<-done
}

// --- the crash gap: offset == length but never finalized ---

type tripOnce struct {
	mu   sync.Mutex
	name string
	used bool
}

func (t *tripOnce) Hit(name string) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if name == t.name && !t.used {
		t.used = true
		return errTripped
	}
	return nil
}

func TestFullyReceivedUnfinalizedIsFinalized(t *testing.T) {
	for _, via := range []string{"head", "append", "create"} {
		t.Run(via, func(t *testing.T) {
			e := newUenv(t)
			content := payload(6000, 27)
			v := e.create(t, content, false)
			// Crash after the final offset commit, before finalize tx1.
			e.fp = &tripOnce{name: FPBeforeTx1}
			e.restart()
			_, err := e.up.Append(ctx, e.p, v.ID, 0, bytes.NewReader(content), nil)
			if !errors.Is(err, errTripped) {
				t.Fatalf("err %v", err)
			}
			if s := e.session(t, v.ID); s.State != "receiving" || s.Offset != 6000 {
				t.Fatalf("session %+v", s)
			}
			e.fp = nil
			e.restart()
			var got UploadView
			switch via {
			case "head":
				got, err = e.up.Head(ctx, e.p, v.ID)
			case "append":
				got, err = e.up.Append(ctx, e.p, v.ID, 6000, bytes.NewReader(nil), nil)
			case "create":
				got, err = e.up.Create(ctx, e.p, CreateInput{Length: 6000, Meta: metaFor(content, "IMG_0001.JPG")})
			}
			if err != nil {
				t.Fatal(err)
			}
			checkDone(t, got, true)
			if got.ID != v.ID {
				t.Fatalf("id %s", got.ID)
			}
			a, ok := e.assetBySHA(t, shaHex(content))
			if !ok || a.ID != got.AssetID {
				t.Fatal("asset missing")
			}
			if len(e.strays(t)) != 0 || e.up.locks.count() != 0 {
				t.Fatalf("leftovers %v", e.strays(t))
			}
		})
	}
}

func TestAppendFailpoints(t *testing.T) {
	for _, fp := range []string{FPAppendAfterFsync, FPAppendBeforeCommit} {
		t.Run(fp, func(t *testing.T) {
			e := newUenv(t)
			content := payload(6000, 28)
			v := e.create(t, content, false)
			e.fp = &tripOnce{name: fp}
			e.restart()
			_, err := e.up.Append(ctx, e.p, v.ID, 0, bytes.NewReader(content[:2500]), nil)
			if !errors.Is(err, errTripped) {
				t.Fatalf("err %v", err)
			}
			// The bytes are on disk but the offset never committed.
			if fi, _ := os.Stat(e.stagingFile(v.ID)); fi.Size() != 2500 {
				t.Fatalf("staging %d", fi.Size())
			}
			e.fp = nil
			e.restart()
			h, err := e.up.Head(ctx, e.p, v.ID)
			if err != nil || h.Offset != 0 {
				t.Fatalf("head %+v %v", h, err)
			}
			got, err := e.up.Append(ctx, e.p, v.ID, 0, bytes.NewReader(content), nil)
			if err != nil {
				t.Fatal(err)
			}
			checkDone(t, got, true)
		})
	}
}

// --- expiry, termination, ownership ---

func TestExpireSessions(t *testing.T) {
	e := newUenv(t)
	stale := payload(4000, 29)
	sv := e.create(t, stale, false)
	e.up.Append(ctx, e.p, sv.ID, 0, bytes.NewReader(stale[:100]), nil)
	dv := e.create(t, payload(100, 30), true)
	e.clk.Advance(23 * time.Hour)
	fresh := payload(4000, 31)
	fv := e.create(t, fresh, false)

	e.clk.Advance(time.Hour + time.Second) // stale is 24h+1s past its last activity
	if err := e.up.ExpireSessions(ctx); err != nil {
		t.Fatal(err)
	}
	if s := e.session(t, sv.ID); s.State != "failed" || s.FailureCode == nil || *s.FailureCode != "expired" {
		t.Fatalf("stale %+v", s)
	}
	if exists(e.stagingFile(sv.ID)) {
		t.Fatal("stale staging remains")
	}
	if s := e.session(t, fv.ID); s.State != "receiving" || !exists(e.stagingFile(fv.ID)) {
		t.Fatalf("fresh %+v", s)
	}
	_, err := e.up.Head(ctx, e.p, sv.ID)
	wantUpCode(t, err, "not_found")
	if e.up.locks.count() != 0 {
		t.Fatalf("locks %d", e.up.locks.count())
	}
	// A new upload of the expired content starts over.
	nv := e.create(t, stale, false)
	if nv.ID == sv.ID || nv.Offset != 0 {
		t.Fatalf("new %+v", nv)
	}

	e.clk.Advance(7*24*time.Hour + time.Second)
	if err := e.up.ExpireSessions(ctx); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{sv.ID, dv.ID} {
		if _, err := (repository.UploadSessionsRepository{}).Get(ctx, e.st.R, id); !errors.Is(err, repository.ErrNotFound) {
			t.Fatalf("%s not deleted: %v", id, err)
		}
	}
}

func TestExpiredSessionNotFoundBeforeSweep(t *testing.T) {
	e := newUenv(t)
	content := payload(4000, 32)
	v := e.create(t, content, false)
	e.clk.Advance(24*time.Hour + time.Second)
	_, err := e.up.Head(ctx, e.p, v.ID)
	wantUpCode(t, err, "not_found")
	_, err = e.up.Append(ctx, e.p, v.ID, 0, bytes.NewReader(content), nil)
	wantUpCode(t, err, "not_found")
	nv := e.create(t, content, false)
	if nv.ID == v.ID {
		t.Fatal("expired session reused")
	}
	if exists(e.stagingFile(v.ID)) {
		t.Fatal("expired staging remains")
	}
}

func TestExpireSessionsRecoversStuckFinalizing(t *testing.T) {
	e := newUenv(t)
	content := payload(3000, 33)
	v := e.create(t, content, false)
	e.fp = &tripOnce{name: FPAfterTx1}
	e.restart()
	if _, err := e.up.Append(ctx, e.p, v.ID, 0, bytes.NewReader(content), nil); !errors.Is(err, errTripped) {
		t.Fatalf("err %v", err)
	}
	e.fp = nil
	e.restart()
	e.clk.Advance(11 * time.Minute)
	if err := e.up.ExpireSessions(ctx); err != nil {
		t.Fatal(err)
	}
	h, err := e.up.Head(ctx, e.p, v.ID)
	if err != nil {
		t.Fatal(err)
	}
	checkDone(t, h, true)
}

func TestTerminate(t *testing.T) {
	e := newUenv(t)
	content := payload(4000, 34)
	v := e.create(t, content, false)
	e.up.Append(ctx, e.p, v.ID, 0, bytes.NewReader(content[:10]), nil)
	if err := e.up.Terminate(ctx, e.p, v.ID); err != nil {
		t.Fatal(err)
	}
	if exists(e.stagingFile(v.ID)) || e.up.locks.count() != 0 {
		t.Fatal("leftovers")
	}
	_, err := e.up.Head(ctx, e.p, v.ID)
	wantUpCode(t, err, "not_found")
	wantUpCode(t, e.up.Terminate(ctx, e.p, v.ID), "not_found")
	wantUpCode(t, e.up.Terminate(ctx, e.p, ids.New()), "not_found")
	// Done: 204 with no effect.
	dv := e.create(t, payload(10, 35), true)
	if err := e.up.Terminate(ctx, e.p, dv.ID); err != nil {
		t.Fatal(err)
	}
	h, err := e.up.Head(ctx, e.p, dv.ID)
	if err != nil {
		t.Fatal(err)
	}
	checkDone(t, h, true)
}

func TestOtherOwnerNotFound(t *testing.T) {
	e := newUenv(t)
	content := payload(4000, 36)
	v := e.create(t, content, false)
	bob := repotest.SeedUser(t, e.st, ids.New())
	bp := Principal{UserID: bob, DeviceID: repotest.SeedDevice(t, e.st, bob, ids.New()), Via: ViaBearer}
	_, err := e.up.Head(ctx, bp, v.ID)
	wantUpCode(t, err, "not_found")
	_, err = e.up.Append(ctx, bp, v.ID, 0, bytes.NewReader(content), nil)
	wantUpCode(t, err, "not_found")
	wantUpCode(t, e.up.Terminate(ctx, bp, v.ID), "not_found")
	// Bob's create of the same content is his own session.
	bv, err := e.up.Create(ctx, bp, CreateInput{Length: 4000, Meta: metaFor(content, "b.jpg")})
	if err != nil || bv.ID == v.ID {
		t.Fatalf("%+v %v", bv, err)
	}
	if e.session(t, v.ID).Offset != 0 {
		t.Fatal("alice's session changed")
	}
}

// Vector two_devices_same_hash_cooperative.
func TestCooperativeDevices(t *testing.T) {
	e := newUenv(t)
	content := payload(3<<20, 37)
	am := metaFor(content, "VID_0009.MP4")
	am.LocalID = "a-9"
	v, err := e.up.Create(ctx, e.p, CreateInput{Length: 3 << 20, Meta: am})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.up.Append(ctx, e.p, v.ID, 0, bytes.NewReader(content[:1<<20]), nil); err != nil {
		t.Fatal(err)
	}
	b := e.p
	b.DeviceID = repotest.SeedDevice(t, e.st, e.owner, ids.New())
	b.Platform = "ios"
	bm := metaFor(content, "IMG_7731.MOV")
	bm.LocalID = "b-3"
	for i := 0; i < 2; i++ { // a retried create does not duplicate the join
		bv, err := e.up.Create(ctx, b, CreateInput{Length: 3 << 20, Meta: bm})
		if err != nil || bv.ID != v.ID || bv.Offset != 1<<20 {
			t.Fatalf("%+v %v", bv, err)
		}
	}
	// A's own retry adds nothing.
	if _, err := e.up.Create(ctx, e.p, CreateInput{Length: 3 << 20, Meta: am}); err != nil {
		t.Fatal(err)
	}
	sm, _ := parseSessionMeta(e.session(t, v.ID))
	if len(sm.JoinedSources) != 1 || sm.JoinedSources[0] != (joinedSource{DeviceID: b.DeviceID, LocalID: "b-3"}) || sm.LocalID != "a-9" {
		t.Fatalf("meta %+v", sm)
	}
	got, err := e.up.Append(ctx, b, v.ID, 1<<20, bytes.NewReader(content[1<<20:]), nil)
	if err != nil {
		t.Fatal(err)
	}
	checkDone(t, got, true)
	h, err := e.up.Head(ctx, e.p, v.ID)
	if err != nil || h.AssetID != got.AssetID {
		t.Fatalf("%+v %v", h, err)
	}
	src, err := repository.AssetSourcesRepository{}.ListByAsset(ctx, e.st.R, got.AssetID)
	if err != nil || len(src) != 2 {
		t.Fatalf("sources %+v %v", src, err)
	}
	want := map[string]string{e.device: "a-9", b.DeviceID: "b-3"}
	for _, r := range src {
		if want[r.DeviceID] != r.LocalID {
			t.Fatalf("sources %+v", src)
		}
	}
}

func TestFinalizeLinksJoinedSourcesWhenAssetExists(t *testing.T) {
	e := newUenv(t)
	content := payload(2000, 38)
	e.seedAsset(t, content)
	a, _ := e.assetBySHA(t, shaHex(content))
	other := repotest.SeedDevice(t, e.st, e.owner, ids.New())
	s := e.stage(t, content, map[string]any{
		"filename": "x.jpg", "mime": "image/jpeg", "local_id": "own-1",
		"joined_sources": []map[string]string{{"device_id": other, "local_id": "j-1"}},
	})
	r := e.finalize(t, s)
	if r.AssetID != a.ID || r.Created {
		t.Fatalf("result %+v", r)
	}
	src, _ := repository.AssetSourcesRepository{}.ListByAsset(ctx, e.st.R, a.ID)
	if len(src) != 2 {
		t.Fatalf("sources %+v", src)
	}
}

// P§7.3 #4: a create that finds the session busy answers at once with 201
// and the committed offset.
func TestCreateOutcome4WhileLockedReturnsPromptly(t *testing.T) {
	e := newUenv(t)
	content := payload(5000, 39)
	v := e.create(t, content, false)
	pr, pw := io.Pipe()
	done := make(chan struct{})
	go func() {
		e.up.Append(ctx, e.p, v.ID, 0, pr, nil)
		close(done)
	}()
	pw.Write(content[:100]) // A holds the lock mid-PATCH
	b := e.p
	b.DeviceID = repotest.SeedDevice(t, e.st, e.owner, ids.New())
	start := time.Now()
	bv, err := e.up.Create(ctx, b, CreateInput{Length: 5000, Meta: metaFor(content, "b.jpg"), Body: bytes.NewReader(content)})
	if err != nil || bv.ID != v.ID || bv.Offset != 0 || bv.Done {
		t.Fatalf("%+v %v", bv, err)
	}
	if d := time.Since(start); d > time.Second {
		t.Fatalf("create took %v", d)
	}
	pw.Write(content[100:])
	pw.Close()
	<-done
	h, err := e.up.Head(ctx, e.p, v.ID)
	if err != nil {
		t.Fatal(err)
	}
	checkDone(t, h, true)
}

// HEAD and the expire job agree: a session is expired only strictly after
// expires_at.
func TestExpiryBoundary(t *testing.T) {
	e := newUenv(t)
	v := e.create(t, payload(4000, 40), false)
	e.clk.Set(v.ExpiresAt)
	if _, err := e.up.Head(ctx, e.p, v.ID); err != nil {
		t.Fatalf("at expires_at: %v", err)
	}
	if err := e.up.ExpireSessions(ctx); err != nil {
		t.Fatal(err)
	}
	if s := e.session(t, v.ID); s.State != "receiving" {
		t.Fatalf("state %s", s.State)
	}
	e.clk.Advance(time.Millisecond)
	_, err := e.up.Head(ctx, e.p, v.ID)
	wantUpCode(t, err, "not_found")
	if s := e.session(t, v.ID); s.State != "failed" {
		t.Fatalf("state %s", s.State)
	}
}

func TestLockMapDoesNotLeak(t *testing.T) {
	e := newUenv(t)
	for i := 0; i < 5; i++ {
		c := payload(1000+i, byte(40+i))
		v := e.create(t, c, false)
		e.up.Append(ctx, e.p, v.ID, 0, bytes.NewReader(c[:10]), nil)
		e.up.Head(ctx, e.p, v.ID)
		e.up.Append(ctx, e.p, v.ID, 5, bytes.NewReader(c), nil) // mismatch
		switch i % 3 {
		case 0:
			e.up.Append(ctx, e.p, v.ID, 10, bytes.NewReader(c[10:]), nil)
		case 1:
			e.up.Terminate(ctx, e.p, v.ID)
		}
	}
	e.clk.Advance(25 * time.Hour)
	if err := e.up.ExpireSessions(ctx); err != nil {
		t.Fatal(err)
	}
	if n := e.up.locks.count(); n != 0 {
		t.Fatalf("lock entries %d", n)
	}
}
