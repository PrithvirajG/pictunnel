package media

import (
	"context"
	"errors"
	"image"
	_ "image/jpeg"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/config"
)

func fixture(name string) string { return filepath.Join("testdata", name) }

// toolsOrSkip returns ffmpeg/ffprobe from PATH or skips the test.
func toolsOrSkip(t *testing.T) Tools {
	t.Helper()
	tl := FindTools(config.Default())
	if tl.FFmpeg == "" || tl.FFprobe == "" {
		t.Skip("ffmpeg/ffprobe not found")
	}
	return tl
}

func decodeSize(t *testing.T, p string) image.Image {
	t.Helper()
	f, err := os.Open(p)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	img, _, err := image.Decode(f)
	if err != nil {
		t.Fatalf("decode %s: %v", p, err)
	}
	return img
}

func wantDims(t *testing.T, p string, w, h int) image.Image {
	t.Helper()
	img := decodeSize(t, p)
	if b := img.Bounds(); b.Dx() != w || b.Dy() != h {
		t.Fatalf("%s is %dx%d, want %dx%d", filepath.Base(p), b.Dx(), b.Dy(), w, h)
	}
	return img
}

func noTempFiles(t *testing.T, dir string) {
	t.Helper()
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range ents {
		if n := e.Name(); n != "thumb.jpg" && n != "preview.jpg" && n != "web.mp4" {
			t.Fatalf("leftover file %q in %s", n, dir)
		}
	}
}

func TestFindTools(t *testing.T) {
	cfg := config.Default()
	cfg.Media.FFmpegPath = filepath.Join(t.TempDir(), "nope", "ffmpeg")
	cfg.Media.FFprobePath = filepath.Join(t.TempDir(), "nope", "ffprobe")
	if tl := FindTools(cfg); tl.FFmpeg != "" || tl.FFprobe != "" {
		t.Fatalf("configured missing paths resolved to %+v", tl)
	}
	// A configured path that exists is used as is.
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cfg.Media.FFmpegPath = exe
	if tl := FindTools(cfg); tl.FFmpeg != exe {
		t.Fatalf("FFmpeg = %q, want %q", tl.FFmpeg, exe)
	}
}

func TestReadImageMetaRotGPS(t *testing.T) {
	m, err := ReadImageMeta(fixture("exif_rot6.jpg"))
	if err != nil {
		t.Fatal(err)
	}
	if m.Width != 320 || m.Height != 480 || m.Orientation != 6 {
		t.Fatalf("dims %dx%d orientation %d, want 320x480 6", m.Width, m.Height, m.Orientation)
	}
	if m.Lat == nil || m.Lon == nil || math.Abs(*m.Lat-38.7223) > 1e-4 || math.Abs(*m.Lon-(-9.1393)) > 1e-4 {
		t.Fatalf("gps %v %v", m.Lat, m.Lon)
	}
	want := time.Date(2024, 5, 6, 10, 0, 0, 0, time.UTC)
	if m.Taken == nil || !m.Taken.Time.Equal(want) || m.Taken.Source != "exif" {
		t.Fatalf("taken %+v", m.Taken)
	}
}

func TestReadImageMetaFormats(t *testing.T) {
	for name, wh := range map[string][2]int{"plain.png": {64, 48}, "anim.gif": {40, 30}, "small.webp": {64, 48}} {
		m, err := ReadImageMeta(fixture(name))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if m.Width != wh[0] || m.Height != wh[1] || m.Lat != nil || m.Lon != nil || m.Taken != nil {
			t.Fatalf("%s: %+v", name, m)
		}
	}
	if _, err := ReadImageMeta(fixture("corrupt.jpg")); err == nil {
		t.Fatal("corrupt.jpg: want error")
	}
}

func TestThumbnailsJPEGOriented(t *testing.T) {
	dir := t.TempDir()
	if err := MakeThumbnails(context.Background(), Tools{}, fixture("exif_rot6.jpg"), "image/jpeg", false, dir); err != nil {
		t.Fatal(err)
	}
	// 480x320 stored, orientation 6 → 320x480 displayed; the thumb's long
	// side is 320 and it is portrait. The preview never upscales.
	th := wantDims(t, filepath.Join(dir, "thumb.jpg"), 213, 320)
	wantDims(t, filepath.Join(dir, "preview.jpg"), 320, 480)
	// The stored bottom-left corner (green, no red) rotates to the top-left.
	r, g, _, _ := th.At(2, 2).RGBA()
	if g>>8 < 180 || r>>8 > 60 {
		t.Fatalf("top-left pixel r=%d g=%d: orientation not applied", r>>8, g>>8)
	}
	noTempFiles(t, dir)
}

func TestThumbnailsPNGNoUpscale(t *testing.T) {
	dir := t.TempDir()
	if err := MakeThumbnails(context.Background(), Tools{}, fixture("plain.png"), "image/png", false, dir); err != nil {
		t.Fatal(err)
	}
	wantDims(t, filepath.Join(dir, "thumb.jpg"), 64, 48)
	wantDims(t, filepath.Join(dir, "preview.jpg"), 64, 48)
	noTempFiles(t, dir)
}

func TestThumbnailsGIFAndWebP(t *testing.T) {
	for name, mime := range map[string]string{"anim.gif": "image/gif", "small.webp": "image/webp"} {
		dir := t.TempDir()
		if err := MakeThumbnails(context.Background(), Tools{}, fixture(name), mime, false, dir); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		img := decodeSize(t, filepath.Join(dir, "thumb.jpg"))
		if img.Bounds().Dx() == 0 {
			t.Fatalf("%s: empty thumb", name)
		}
	}
}

func TestThumbnailsVideo(t *testing.T) {
	tl := toolsOrSkip(t)
	dir := t.TempDir()
	if err := MakeThumbnails(context.Background(), tl, fixture("clip_h264.mp4"), "video/mp4", true, dir); err != nil {
		t.Fatal(err)
	}
	wantDims(t, filepath.Join(dir, "thumb.jpg"), 64, 48)
	wantDims(t, filepath.Join(dir, "preview.jpg"), 64, 48)
	noTempFiles(t, dir)
}

func TestThumbnailsFFmpegImage(t *testing.T) {
	tl := toolsOrSkip(t)
	dir := t.TempDir()
	if err := MakeThumbnails(context.Background(), tl, fixture("still.avif"), "image/avif", false, dir); err != nil {
		t.Fatal(err)
	}
	wantDims(t, filepath.Join(dir, "thumb.jpg"), 64, 48)
	noTempFiles(t, dir)
}

func TestThumbnailsHEIC(t *testing.T) {
	if _, err := os.Stat(fixture("still.heic")); err != nil {
		t.Skip("no still.heic fixture: this ffmpeg build has no HEIF muxer")
	}
	tl := toolsOrSkip(t)
	if err := MakeThumbnails(context.Background(), tl, fixture("still.heic"), "image/heic", false, t.TempDir()); err != nil {
		t.Fatal(err)
	}
}

func TestThumbnailsNoTools(t *testing.T) {
	dir := t.TempDir()
	err := MakeThumbnails(context.Background(), Tools{}, fixture("still.avif"), "image/heic", false, dir)
	if !errors.Is(err, ErrToolMissing) {
		t.Fatalf("heic: err = %v, want ErrToolMissing", err)
	}
	err = MakeThumbnails(context.Background(), Tools{}, fixture("clip_h264.mp4"), "video/mp4", true, dir)
	if !errors.Is(err, ErrToolMissing) {
		t.Fatalf("video: err = %v, want ErrToolMissing", err)
	}
	if _, err := FFprobe(context.Background(), Tools{}, fixture("clip_h264.mp4")); !errors.Is(err, ErrToolMissing) {
		t.Fatalf("ffprobe: err = %v, want ErrToolMissing", err)
	}
	if err := Transcode(context.Background(), Tools{}, fixture("clip_hevc.mov"), filepath.Join(dir, "web.mp4")); !errors.Is(err, ErrToolMissing) {
		t.Fatalf("transcode: err = %v, want ErrToolMissing", err)
	}
}

func TestThumbnailsCorrupt(t *testing.T) {
	dir := t.TempDir()
	err := MakeThumbnails(context.Background(), Tools{}, fixture("corrupt.jpg"), "image/jpeg", false, dir)
	if err == nil || errors.Is(err, ErrToolMissing) {
		t.Fatalf("err = %v, want a decode error", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "thumb.jpg")); !os.IsNotExist(err) {
		t.Fatalf("thumb.jpg exists after failure: %v", err)
	}
	noTempFiles(t, dir)
}

func TestPlayable(t *testing.T) {
	cases := []struct {
		container, video, audio string
		want                    bool
	}{
		{"mp4", "h264", "aac", true},
		{"mp4", "h264", "", true},
		{"mov", "h264", "aac", true},
		{"mov", "h264", "mp3", true},
		{"mp4", "h264", "opus", true},
		{"mov", "hevc", "aac", false},
		{"mp4", "hevc", "", false},
		{"mp4", "h264", "pcm_s16le", false},
		{"mp4", "h264", "ac3", false},
		{"webm", "vp8", "opus", true},
		{"webm", "vp9", "", true},
		{"webm", "av1", "opus", true},
		{"webm", "h264", "opus", false},
		{"webm", "vp9", "vorbis", false},
		{"mkv", "h264", "aac", false},
		{"avi", "h264", "mp3", false},
		{"mp4", "", "aac", false},
		{"", "h264", "aac", false},
	}
	for _, c := range cases {
		p := Probe{Container: c.container, VideoCodec: c.video, AudioCodec: c.audio}
		if got := Playable(p); got != c.want {
			t.Errorf("Playable(%s/%s/%s) = %v, want %v", c.container, c.video, c.audio, got, c.want)
		}
	}
}

func TestFFprobe(t *testing.T) {
	tl := toolsOrSkip(t)
	p, err := FFprobe(context.Background(), tl, fixture("clip_h264.mp4"))
	if err != nil {
		t.Fatal(err)
	}
	if p.Width != 64 || p.Height != 48 || p.VideoCodec != "h264" || p.AudioCodec != "aac" || p.Container != "mp4" {
		t.Fatalf("h264 probe %+v", p)
	}
	if p.DurationMS == nil || *p.DurationMS < 950 || *p.DurationMS > 1100 {
		t.Fatalf("duration %v", p.DurationMS)
	}
	want := time.Date(2023, 1, 2, 3, 4, 5, 0, time.UTC)
	if p.CreationTime == nil || !p.CreationTime.Equal(want) {
		t.Fatalf("creation %v", p.CreationTime)
	}
	if !Playable(p) {
		t.Fatal("h264 mp4 should be playable")
	}
	p, err = FFprobe(context.Background(), tl, fixture("clip_hevc.mov"))
	if err != nil {
		t.Fatal(err)
	}
	if p.VideoCodec != "hevc" || p.Container != "mov" || Playable(p) {
		t.Fatalf("hevc probe %+v playable=%v", p, Playable(p))
	}
}

func TestDisplaySize(t *testing.T) {
	p := Probe{Width: 64, Height: 48, Rotation: -90}
	if w, h := p.DisplaySize(); w != 48 || h != 64 {
		t.Fatalf("rotated display %dx%d", w, h)
	}
	p.Rotation = 180
	if w, h := p.DisplaySize(); w != 64 || h != 48 {
		t.Fatalf("180 display %dx%d", w, h)
	}
}

func TestTranscodeHEVCProducesPlayable(t *testing.T) {
	tl := toolsOrSkip(t)
	dir := t.TempDir()
	dst := filepath.Join(dir, "web.mp4")
	if err := Transcode(context.Background(), tl, fixture("clip_hevc.mov"), dst); err != nil {
		t.Fatal(err)
	}
	p, err := FFprobe(context.Background(), tl, dst)
	if err != nil {
		t.Fatal(err)
	}
	if !Playable(p) || p.VideoCodec != "h264" || p.Container != "mp4" {
		t.Fatalf("web.mp4 probe %+v", p)
	}
	noTempFiles(t, dir)
}

func TestTranscodeCancelled(t *testing.T) {
	tl := toolsOrSkip(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	dir := t.TempDir()
	if err := Transcode(ctx, tl, fixture("clip_hevc.mov"), filepath.Join(dir, "web.mp4")); err == nil {
		t.Fatal("cancelled transcode succeeded")
	}
	noTempFiles(t, dir)
}
