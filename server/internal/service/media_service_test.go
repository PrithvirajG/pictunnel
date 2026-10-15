package service

import (
	"context"
	"encoding/json"
	"errors"
	"image"
	_ "image/jpeg"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/config"
	"github.com/PrithvirajG/pictunnel/server/internal/jobs"
	"github.com/PrithvirajG/pictunnel/server/internal/media"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
)

func mediaFixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "media", "testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func mediaToolsOrSkip(t *testing.T) media.Tools {
	t.Helper()
	tl := media.FindTools(config.Default())
	if tl.FFmpeg == "" || tl.FFprobe == "" {
		t.Skip("ffmpeg/ffprobe not found")
	}
	return tl
}

// fpFunc is a Failpoints whose Hit runs fn.
type fpFunc func(name string) error

func (f fpFunc) Hit(name string) error { return f(name) }

func (e *senv) media(tl media.Tools, fp Failpoints) *MediaService {
	return NewMediaService(MediaServiceDeps{
		Store: e.st, Assets: repository.AssetsRepository{}, LiveVideos: repository.LiveVideosRepository{},
		ChangeLog: repository.ChangeLogRepository{}, Jobs: e.runner, FS: e.fs, Tools: tl, Clock: e.clk,
		DataDir: e.dataDir, LibraryDir: e.libDir, Failpoints: fp,
	})
}

func assetPayload(id string) []byte {
	b, _ := json.Marshal(map[string]string{"asset_id": id})
	return b
}

// purgeNow trashes and purges the asset as its owner. Purge's own
// best-effort removal of the derived dir is made to fail, so the dir is only
// cleaned by whoever runs next (the media job under test).
func (e *senv) purgeNow(t *testing.T, p Principal, id string) {
	t.Helper()
	ctx := context.Background()
	e.fs.setFail(e.derived(id), true)
	defer e.fs.setFail(e.derived(id), false)
	if _, err := e.trash.Trash(ctx, p, []string{id}); err != nil {
		t.Fatal(err)
	}
	if res, err := e.trash.Purge(ctx, p, []string{id}); err != nil || len(res.Succeeded) != 1 {
		t.Fatalf("purge: %+v %v", res, err)
	}
}

func TestExtractMetadataUpdatesAssetAndFeed(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	a := e.seed(t, e.alice, mediaFixture(t, "exif_rot6.jpg"))
	cursor := EncodeCursor(a.UpdatedSeq)
	if err := e.media(media.Tools{}, nil).ExtractMetadata(ctx, assetPayload(a.ID)); err != nil {
		t.Fatal(err)
	}
	ch, _, _, err := e.feed.Changes(ctx, e.alice, cursor, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(ch) != 1 || ch[0].Kind != "asset.upsert" || ch[0].Asset == nil {
		t.Fatalf("changes %+v", ch)
	}
	got := ch[0].Asset
	if got.Width == nil || *got.Width != 320 || got.Height == nil || *got.Height != 480 {
		t.Fatalf("dims %v x %v", got.Width, got.Height)
	}
	if got.Lat == nil || math.Abs(*got.Lat-38.7223) > 1e-4 || got.Lon == nil || math.Abs(*got.Lon+9.1393) > 1e-4 {
		t.Fatalf("gps %v %v", got.Lat, got.Lon)
	}
	want := time.Date(2024, 5, 6, 10, 0, 0, 0, time.UTC)
	if got.TakenAt == nil || !got.TakenAt.Equal(want) || got.TakenAtSource != "exif" {
		t.Fatalf("taken %v %q", got.TakenAt, got.TakenAtSource)
	}
	if got.OriginalPath != a.OriginalPath || got.Playable != nil || got.DurationMs != nil {
		t.Fatalf("unexpected changes: %+v", got.Asset)
	}
	if n := len(e.pendingJobs(t, JobTranscodeVideo)); n != 0 {
		t.Fatalf("transcode jobs for a photo: %d", n)
	}
}

func TestExtractMetadataKeepsBetterDate(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	taken := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	a := e.seed(t, e.alice, mediaFixture(t, "exif_rot6.jpg"), func(a *repository.Asset) {
		a.TakenAt, a.TakenAtSource = &taken, "container"
	})
	if err := e.media(media.Tools{}, nil).ExtractMetadata(ctx, assetPayload(a.ID)); err != nil {
		t.Fatal(err)
	}
	got := e.asset(t, a.ID)
	if !got.TakenAt.Equal(taken) || got.TakenAtSource != "container" {
		t.Fatalf("embedded date overwritten: %v %q", got.TakenAt, got.TakenAtSource)
	}
}

func TestExtractMetadataVideo(t *testing.T) {
	tl := mediaToolsOrSkip(t)
	e := newSenv(t)
	ctx := context.Background()
	svc := e.media(tl, nil)
	hevc := e.seed(t, e.alice, mediaFixture(t, "clip_hevc.mov"), withMime("video/quicktime", "video"))
	h264 := e.seed(t, e.alice, mediaFixture(t, "clip_h264.mp4"), withMime("video/mp4", "video"))
	for _, a := range []repository.Asset{hevc, h264} {
		if err := svc.ExtractMetadata(ctx, assetPayload(a.ID)); err != nil {
			t.Fatal(err)
		}
	}
	got := e.asset(t, hevc.ID)
	if *got.Width != 64 || *got.Height != 48 || *got.VideoCodec != "hevc" || *got.AudioCodec != "aac" ||
		*got.Container != "mov" || got.Playable == nil || *got.Playable {
		t.Fatalf("hevc: %+v", got)
	}
	if got.DurationMs == nil || *got.DurationMs < 950 || *got.DurationMs > 1100 {
		t.Fatalf("hevc duration %v", got.DurationMs)
	}
	got = e.asset(t, h264.ID)
	if got.Playable == nil || !*got.Playable || *got.Container != "mp4" {
		t.Fatalf("h264: %+v", got)
	}
	// The mp4's creation_time fills the missing date.
	if got.TakenAt == nil || !got.TakenAt.Equal(time.Date(2023, 1, 2, 3, 4, 5, 0, time.UTC)) || got.TakenAtSource != "container" {
		t.Fatalf("h264 date %v %q", got.TakenAt, got.TakenAtSource)
	}
	jobsQ := e.pendingJobs(t, JobTranscodeVideo)
	if len(jobsQ) != 1 || jobsQ[0].DedupeKey != hevc.ID {
		t.Fatalf("transcode jobs %+v", jobsQ)
	}
}

func TestExtractMetadataNoFFprobe(t *testing.T) {
	e := newSenv(t)
	a := e.seed(t, e.alice, "not really a video", withMime("video/mp4", "video"))
	err := e.media(media.Tools{}, nil).ExtractMetadata(context.Background(), assetPayload(a.ID))
	var perm *jobs.Permanent
	if !errors.Is(err, media.ErrToolMissing) || errors.As(err, &perm) {
		t.Fatalf("err = %v, want retryable ErrToolMissing", err)
	}
	if got := e.asset(t, a.ID); got.Playable != nil {
		t.Fatalf("playable = %v, want NULL", *got.Playable)
	}
}

func TestExtractMetadataLivePhoto(t *testing.T) {
	tl := mediaToolsOrSkip(t)
	e := newSenv(t)
	ctx := context.Background()
	a := e.seed(t, e.alice, mediaFixture(t, "exif_rot6.jpg"))
	e.attachLive(t, a, mediaFixture(t, "clip_hevc.mov"))
	if err := e.media(tl, nil).ExtractMetadata(ctx, assetPayload(a.ID)); err != nil {
		t.Fatal(err)
	}
	got := e.asset(t, a.ID)
	if got.Kind != "live_photo" || *got.Width != 320 || *got.Height != 480 {
		t.Fatalf("live still: %+v", got)
	}
	if got.DurationMs == nil || *got.DurationMs < 950 || *got.DurationMs > 1100 {
		t.Fatalf("live duration %v", got.DurationMs)
	}
	if n := len(e.pendingJobs(t, JobTranscodeVideo)); n != 0 {
		t.Fatalf("transcode enqueued for a live photo: %d", n)
	}
	// Without ffprobe the still's metadata lands and the job retries for
	// the duration.
	b := e.seed(t, e.alice, mediaFixture(t, "exif_rot6.jpg")+"x")
	e.attachLive(t, b, mediaFixture(t, "clip_hevc.mov")+"x")
	err := e.media(media.Tools{}, nil).ExtractMetadata(ctx, assetPayload(b.ID))
	if !errors.Is(err, media.ErrToolMissing) {
		t.Fatalf("err = %v, want ErrToolMissing", err)
	}
	if got := e.asset(t, b.ID); got.Width == nil || *got.Width != 320 || got.DurationMs != nil {
		t.Fatalf("partial live metadata: %+v", got)
	}
}

func TestMediaJobsGoneAndBadPayload(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	svc := e.media(media.Tools{}, nil)
	missing := assetPayload("01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f")
	for name, h := range map[string]jobs.Handler{
		"extract": svc.ExtractMetadata, "thumbs": svc.GenerateThumbnails, "transcode": svc.TranscodeVideo,
	} {
		if err := h(ctx, missing); err != nil {
			t.Fatalf("%s gone asset: %v", name, err)
		}
		for _, bad := range []string{`{`, `{}`, `{"asset_id":"../x"}`} {
			var perm *jobs.Permanent
			if err := h(ctx, []byte(bad)); !errors.As(err, &perm) {
				t.Fatalf("%s payload %s: err = %v, want permanent", name, bad, err)
			}
		}
	}
}

func TestGenerateThumbnailsJob(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	a := e.seed(t, e.alice, mediaFixture(t, "exif_rot6.jpg"))
	_, _, err := e.assets.OpenThumbnail(ctx, e.alice, a.ID, "thumb")
	wantCode(t, err, "not_ready")
	if err := e.media(media.Tools{}, nil).GenerateThumbnails(ctx, assetPayload(a.ID)); err != nil {
		t.Fatal(err)
	}
	got := e.asset(t, a.ID)
	if !got.ThumbnailsReady || got.UpdatedSeq <= a.UpdatedSeq {
		t.Fatalf("after job: ready=%v seq %d→%d", got.ThumbnailsReady, a.UpdatedSeq, got.UpdatedSeq)
	}
	for size, wh := range map[string][2]int{"thumb": {213, 320}, "preview": {320, 480}} {
		f, fa, err := e.assets.OpenThumbnail(ctx, e.alice, a.ID, size)
		if err != nil {
			t.Fatalf("%s: %v", size, err)
		}
		// The handler derives ETag "<sha256>-<size>" from the asset row.
		if fa.SHA256 != a.SHA256 || fa.SizeBytes != a.SizeBytes {
			t.Fatalf("%s: asset %+v", size, fa)
		}
		cfg, _, err := image.DecodeConfig(f)
		f.Close()
		if err != nil || cfg.Width != wh[0] || cfg.Height != wh[1] {
			t.Fatalf("%s: %dx%d %v", size, cfg.Width, cfg.Height, err)
		}
	}
	ch, _, _, err := e.feed.Changes(ctx, e.alice, EncodeCursor(a.UpdatedSeq), 0)
	if err != nil || len(ch) != 1 || !ch[0].Asset.ThumbnailsReady {
		t.Fatalf("feed %+v %v", ch, err)
	}
}

func TestThumbnailJobPurgedMeanwhile(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	a := e.seed(t, e.alice, mediaFixture(t, "plain.png"), withMime("image/png", "photo"))
	fp := fpFunc(func(name string) error {
		if name == FPMediaAfterWrite {
			if _, err := os.Stat(filepath.Join(e.derived(a.ID), "thumb.jpg")); err != nil {
				t.Errorf("thumb not written before the failpoint: %v", err)
			}
			e.purgeNow(t, e.alice, a.ID)
		}
		return nil
	})
	if err := e.media(media.Tools{}, fp).GenerateThumbnails(ctx, assetPayload(a.ID)); err != nil {
		t.Fatal(err)
	}
	if !e.assetGone(t, a.ID) {
		t.Fatal("asset not purged")
	}
	if _, err := os.Stat(e.derived(a.ID)); !os.IsNotExist(err) {
		t.Fatalf("derived dir left behind: %v", err)
	}
}

func jobState(t *testing.T, e *senv, kind string) (string, int) {
	t.Helper()
	var state string
	var attempts int
	err := e.st.R.QueryRowContext(context.Background(),
		`SELECT state, attempts FROM jobs WHERE kind = ? ORDER BY created_at DESC LIMIT 1`, kind).Scan(&state, &attempts)
	if err != nil {
		t.Fatal(err)
	}
	return state, attempts
}

func TestThumbnailJobCorruptInput(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	svc := e.media(media.Tools{}, nil)
	e.runner.Register(JobGenerateThumbnails, svc.GenerateThumbnails, MediaJobMaxAttempts)
	content := mediaFixture(t, "corrupt.jpg")
	a := e.seed(t, e.alice, content)
	if err := e.runner.Enqueue(ctx, e.st.W, JobGenerateThumbnails, a.ID, assetPayload(a.ID), time.Time{}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < MediaJobMaxAttempts; i++ {
		if err := e.runner.RunNow(ctx, JobGenerateThumbnails); err == nil {
			t.Fatalf("attempt %d succeeded", i+1)
		}
		e.clk.Advance(2 * time.Hour)
	}
	if state, attempts := jobState(t, e, JobGenerateThumbnails); state != "dead" || attempts != 3 {
		t.Fatalf("job %s after %d attempts, want dead after 3", state, attempts)
	}
	// The asset is still served; only its thumbnail is missing.
	f, _, err := e.assets.OpenOriginal(ctx, e.alice, a.ID)
	if err != nil {
		t.Fatal(err)
	}
	if readAll(t, f) != content {
		t.Fatal("original changed")
	}
	_, _, err = e.assets.OpenThumbnail(ctx, e.alice, a.ID, "thumb")
	wantCode(t, err, "not_ready")
}

func TestThumbnailJobNoFFmpeg(t *testing.T) {
	e := newSenv(t)
	a := e.seed(t, e.alice, "heic bytes", withMime("image/heic", "photo"))
	err := e.media(media.Tools{}, nil).GenerateThumbnails(context.Background(), assetPayload(a.ID))
	var perm *jobs.Permanent
	if !errors.Is(err, media.ErrToolMissing) || errors.As(err, &perm) {
		t.Fatalf("err = %v, want retryable ErrToolMissing", err)
	}
	if e.asset(t, a.ID).ThumbnailsReady {
		t.Fatal("thumbnails_ready set without thumbnails")
	}
}

func TestThumbnailsVideoJob(t *testing.T) {
	tl := mediaToolsOrSkip(t)
	e := newSenv(t)
	a := e.seed(t, e.alice, mediaFixture(t, "clip_h264.mp4"), withMime("video/mp4", "video"))
	if err := e.media(tl, nil).GenerateThumbnails(context.Background(), assetPayload(a.ID)); err != nil {
		t.Fatal(err)
	}
	if !e.asset(t, a.ID).ThumbnailsReady {
		t.Fatal("not ready")
	}
}

// TestPlaybackRulesService is the service-level form of TestPlaybackRules
// (the HTTP test lands with the app wiring in Task 15).
func TestPlaybackRulesService(t *testing.T) {
	tl := mediaToolsOrSkip(t)
	e := newSenv(t)
	ctx := context.Background()
	svc := e.media(tl, nil)
	mp4 := e.seed(t, e.alice, mediaFixture(t, "clip_h264.mp4"), withMime("video/mp4", "video"))
	mov := e.seed(t, e.alice, mediaFixture(t, "clip_hevc.mov"), withMime("video/quicktime", "video"))
	photo := e.seed(t, e.alice, mediaFixture(t, "plain.png"), withMime("image/png", "photo"))
	// Unknown playability is not_ready.
	_, _, err := e.assets.OpenPlayback(ctx, e.alice, mp4.ID)
	wantCode(t, err, "not_ready")
	for _, a := range []repository.Asset{mp4, mov} {
		if err := svc.ExtractMetadata(ctx, assetPayload(a.ID)); err != nil {
			t.Fatal(err)
		}
	}
	f, mime, err := e.assets.OpenPlayback(ctx, e.alice, mp4.ID)
	if err != nil || mime != "video/mp4" {
		t.Fatalf("mp4 playback %q %v", mime, err)
	}
	if readAll(t, f) != mediaFixture(t, "clip_h264.mp4") {
		t.Fatal("mp4 playback is not the original")
	}
	_, _, err = e.assets.OpenPlayback(ctx, e.alice, mov.ID)
	wantCode(t, err, "not_ready")
	before := e.asset(t, mov.ID).UpdatedSeq
	if err := svc.TranscodeVideo(ctx, assetPayload(mov.ID)); err != nil {
		t.Fatal(err)
	}
	f, mime, err = e.assets.OpenPlayback(ctx, e.alice, mov.ID)
	if err != nil || mime != "video/mp4" {
		t.Fatalf("mov playback %q %v", mime, err)
	}
	f.Close()
	p, err := media.FFprobe(ctx, tl, filepath.Join(e.derived(mov.ID), "web.mp4"))
	if err != nil || !media.Playable(p) {
		t.Fatalf("web.mp4 %+v %v", p, err)
	}
	if e.asset(t, mov.ID).UpdatedSeq <= before {
		t.Fatal("transcode did not append asset.upsert")
	}
	// Transcoding a playable video is a no-op.
	if err := svc.TranscodeVideo(ctx, assetPayload(mp4.ID)); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(e.derived(mp4.ID), "web.mp4")); !os.IsNotExist(err) {
		t.Fatalf("web.mp4 for a playable original: %v", err)
	}
	_, _, err = e.assets.OpenPlayback(ctx, e.alice, photo.ID)
	wantCode(t, err, "not_found")
}

func TestTranscodePurgedMeanwhile(t *testing.T) {
	tl := mediaToolsOrSkip(t)
	e := newSenv(t)
	ctx := context.Background()
	no := false
	mov := e.seed(t, e.alice, mediaFixture(t, "clip_hevc.mov"), withMime("video/quicktime", "video"),
		func(a *repository.Asset) { a.Playable = &no })
	fp := fpFunc(func(name string) error {
		if name == FPMediaAfterWrite {
			e.purgeNow(t, e.alice, mov.ID)
		}
		return nil
	})
	if err := e.media(tl, fp).TranscodeVideo(ctx, assetPayload(mov.ID)); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(e.derived(mov.ID)); !os.IsNotExist(err) {
		t.Fatalf("derived dir left behind: %v", err)
	}
}
