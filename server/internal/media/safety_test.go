package media

import (
	"bytes"
	"compress/zlib"
	"context"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"os"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/image/tiff"

	"github.com/PrithvirajG/pictunnel/server/internal/config"
)

// bombPNG is a valid-looking PNG whose IHDR declares 65535x65535 RGBA
// (~17 GB decoded) followed by a tiny IDAT.
func bombPNG() []byte {
	var b bytes.Buffer
	b.WriteString("\x89PNG\r\n\x1a\n")
	chunk := func(typ string, data []byte) {
		_ = binary.Write(&b, binary.BigEndian, uint32(len(data)))
		c := crc32.NewIEEE()
		c.Write([]byte(typ))
		c.Write(data)
		b.WriteString(typ)
		b.Write(data)
		_ = binary.Write(&b, binary.BigEndian, c.Sum32())
	}
	ihdr := make([]byte, 13)
	binary.BigEndian.PutUint32(ihdr[0:], 65535)
	binary.BigEndian.PutUint32(ihdr[4:], 65535)
	ihdr[8], ihdr[9] = 8, 6 // 8-bit RGBA
	chunk("IHDR", ihdr)
	var z bytes.Buffer
	zw := zlib.NewWriter(&z)
	_, _ = zw.Write(make([]byte, 64))
	_ = zw.Close()
	chunk("IDAT", z.Bytes())
	chunk("IEND", nil)
	return b.Bytes()
}

func TestThumbnailsDecompressionBomb(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "bomb.png")
	if err := os.WriteFile(src, bombPNG(), 0o644); err != nil {
		t.Fatal(err)
	}
	// Reading the metadata only parses headers.
	m, err := ReadImageMeta(src)
	if err != nil || m.Width != 65535 || m.Height != 65535 {
		t.Fatalf("meta %+v %v", m, err)
	}
	// Without ffmpeg the oversized image is not decoded in-process: it is
	// routed to the (missing) out-of-process decoder.
	err = MakeThumbnails(context.Background(), Tools{}, src, "image/png", false, filepath.Join(dir, "out"))
	if !errors.Is(err, ErrToolMissing) {
		t.Fatalf("err = %v, want ErrToolMissing (routed to ffmpeg)", err)
	}
	// With ffmpeg it runs out of process and fails on the truncated data.
	if tl := FindTools(config.Default()); tl.FFmpeg != "" {
		if err := MakeThumbnails(context.Background(), tl, src, "image/png", false, filepath.Join(dir, "out")); err == nil {
			t.Fatal("bomb produced thumbnails")
		}
	}
}

func TestDecodeLimits(t *testing.T) {
	for _, c := range []struct {
		w, h int
		ok   bool
	}{{64, 48, true}, {10000, 10000, true}, {30000, 3000, true}, {30001, 10, false}, {12000, 9000, false}, {0, 10, false}} {
		if got := withinDecodeLimits(c.w, c.h); got != c.ok {
			t.Errorf("withinDecodeLimits(%d, %d) = %v, want %v", c.w, c.h, got, c.ok)
		}
	}
}

func TestReadImageMetaLateExif(t *testing.T) {
	src, err := os.ReadFile(fixture("exif_rot6.jpg"))
	if err != nil {
		t.Fatal(err)
	}
	// Push the EXIF APP1 past FastDate's 512 KiB window with APP15 padding.
	const padLen = 65000
	pad := make([]byte, 4+padLen)
	pad[0], pad[1] = 0xFF, 0xEF
	binary.BigEndian.PutUint16(pad[2:], uint16(padLen+2))
	out := append([]byte{}, src[:2]...)
	for i := 0; i < 9; i++ {
		out = append(out, pad...)
	}
	out = append(out, src[2:]...)
	p := filepath.Join(t.TempDir(), "late.jpg")
	if err := os.WriteFile(p, out, 0o644); err != nil {
		t.Fatal(err)
	}
	m, err := ReadImageMeta(p)
	if err != nil {
		t.Fatal(err)
	}
	want := time.Date(2024, 5, 6, 10, 0, 0, 0, time.UTC)
	if m.Taken == nil || !m.Taken.Time.Equal(want) || m.Taken.Source != "exif" || m.Width != 320 {
		t.Fatalf("late exif: %+v taken %+v", m, m.Taken)
	}
}

func copyFile(t *testing.T, src, dst string) {
	t.Helper()
	b, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dst, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestFFmpegAwkwardNames(t *testing.T) {
	tl := toolsOrSkip(t)
	ctx := context.Background()
	dir := t.TempDir()
	// A TIFF goes through ffmpeg's image2 demuxer, where "%03d" would be a
	// sequence pattern; a leading "-" would look like an option.
	var tb bytes.Buffer
	if err := tiff.Encode(&tb, gradient(64, 48), nil); err != nil {
		t.Fatal(err)
	}
	still := filepath.Join(dir, "-still%03d.tif")
	if err := os.WriteFile(still, tb.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	video := filepath.Join(dir, "-clip%03d.mp4")
	copyFile(t, fixture("clip_hevc.mov"), video)

	out := filepath.Join(dir, "-out%03d")
	if err := MakeThumbnails(ctx, tl, still, "image/tiff", false, out); err != nil {
		t.Fatalf("tiff thumbs: %v", err)
	}
	wantDims(t, filepath.Join(out, "thumb.jpg"), 64, 48)
	if err := MakeThumbnails(ctx, tl, video, "video/quicktime", true, out); err != nil {
		t.Fatalf("video thumbs: %v", err)
	}
	if p, err := FFprobe(ctx, tl, still); err != nil || p.Width != 64 {
		t.Fatalf("ffprobe tiff: %+v %v", p, err)
	}
	if p, err := FFprobe(ctx, tl, video); err != nil || p.VideoCodec != "hevc" {
		t.Fatalf("ffprobe video: %+v %v", p, err)
	}
	dst := filepath.Join(out, "-web%03d.mp4")
	if err := Transcode(ctx, tl, video, dst); err != nil {
		t.Fatalf("transcode: %v", err)
	}
	if _, err := os.Stat(dst); err != nil {
		t.Fatal(err)
	}
}

// A playlist uploaded by one user must not make ffmpeg open another user's
// file: only container demuxers for real media are allowed.
func TestFFmpegRejectsPlaylists(t *testing.T) {
	tl := toolsOrSkip(t)
	ctx := context.Background()
	dir := t.TempDir()
	victim := filepath.Join(dir, "bob", "secret.mp4")
	if err := os.MkdirAll(filepath.Dir(victim), 0o755); err != nil {
		t.Fatal(err)
	}
	copyFile(t, fixture("clip_h264.mp4"), victim)
	abs, err := filepath.Abs(victim)
	if err != nil {
		t.Fatal(err)
	}
	playlist := "#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nfile:" + abs + "\n#EXT-X-ENDLIST\n"
	for _, name := range []string{"IMG_1.m3u8", "IMG_2.mp4"} {
		src := filepath.Join(dir, "alice", name)
		if err := os.MkdirAll(filepath.Dir(src), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(src, []byte(playlist), 0o644); err != nil {
			t.Fatal(err)
		}
		if p, err := FFprobe(ctx, tl, src); err == nil {
			t.Errorf("%s: ffprobe opened a playlist: %+v", name, p)
		}
		out := filepath.Join(dir, "out-"+name)
		if err := MakeThumbnails(ctx, tl, src, "video/mp4", true, out); err == nil {
			t.Errorf("%s: thumbnails made from a playlist", name)
		}
		if err := Transcode(ctx, tl, src, filepath.Join(dir, "web-"+name+".mp4")); err == nil {
			t.Errorf("%s: transcoded a playlist", name)
		}
	}
}

// topLevelBoxes lists the ISO-BMFF top-level box types of a file.
func topLevelBoxes(t *testing.T, p string) []string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	var types []string
	for off := 0; off+8 <= len(b); {
		size := int(binary.BigEndian.Uint32(b[off:]))
		types = append(types, string(b[off+4:off+8]))
		if size == 1 && off+16 <= len(b) {
			size = int(binary.BigEndian.Uint64(b[off+8:]))
		}
		if size < 8 {
			break
		}
		off += size
	}
	return types
}

func TestTranscodeFaststart(t *testing.T) {
	tl := toolsOrSkip(t)
	dst := filepath.Join(t.TempDir(), "web.mp4")
	if err := Transcode(context.Background(), tl, fixture("clip_hevc.mov"), dst); err != nil {
		t.Fatal(err)
	}
	moov, mdat := -1, -1
	for i, typ := range topLevelBoxes(t, dst) {
		switch typ {
		case "moov":
			moov = i
		case "mdat":
			if mdat < 0 {
				mdat = i
			}
		}
	}
	if moov < 0 || mdat < 0 || moov > mdat {
		t.Fatalf("box order %v: moov must precede mdat", topLevelBoxes(t, dst))
	}
}
