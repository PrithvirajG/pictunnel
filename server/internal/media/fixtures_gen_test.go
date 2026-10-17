package media

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/color/palette"
	"image/gif"
	"image/jpeg"
	"image/png"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// TestGenerateFixtures rewrites testdata/. It only runs with
// PT_GEN_FIXTURES=1 and needs ffmpeg (with libx264, libx265, libwebp and
// libaom-av1) on PATH; the outputs are committed so normal runs never
// regenerate them. See testdata/README.md.
func TestGenerateFixtures(t *testing.T) {
	if os.Getenv("PT_GEN_FIXTURES") != "1" {
		t.Skip("set PT_GEN_FIXTURES=1 to regenerate testdata")
	}
	write := func(name string, b []byte) {
		t.Helper()
		if err := os.WriteFile(filepath.Join("testdata", name), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("exif_rot6.jpg", exifRot6JPEG(t))
	write("plain.png", plainPNG(t))
	write("anim.gif", animGIF(t))
	write("corrupt.jpg", corruptJPEG())

	ff := func(name string, args ...string) {
		t.Helper()
		full := append([]string{"-nostdin", "-v", "error", "-y"}, args...)
		full = append(full, filepath.Join("testdata", name))
		if b, err := exec.Command("ffmpeg", full...).CombinedOutput(); err != nil {
			t.Fatalf("ffmpeg %s: %v\n%s", name, err, b)
		}
	}
	ff("small.webp", "-f", "lavfi", "-i", "testsrc=s=64x48:r=1:d=1",
		"-frames:v", "1", "-c:v", "libwebp", "-quality", "60")
	ff("clip_h264.mp4",
		"-f", "lavfi", "-i", "testsrc=s=64x48:r=10:d=1",
		"-f", "lavfi", "-i", "sine=frequency=440:duration=1",
		"-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p",
		"-c:a", "aac", "-b:a", "32k", "-shortest",
		"-metadata", "creation_time=2023-01-02T03:04:05Z", "-movflags", "+faststart")
	ff("clip_hevc.mov",
		"-f", "lavfi", "-i", "testsrc=s=64x48:r=10:d=1",
		"-f", "lavfi", "-i", "sine=frequency=440:duration=1",
		"-c:v", "libx265", "-preset", "veryfast", "-x265-params", "log-level=error",
		"-pix_fmt", "yuv420p", "-tag:v", "hvc1",
		"-c:a", "aac", "-b:a", "32k", "-shortest")
	ff("still.avif", "-f", "lavfi", "-i", "testsrc=s=64x48:r=1:d=1",
		"-frames:v", "1", "-c:v", "libaom-av1", "-still-picture", "1", "-crf", "40", "-pix_fmt", "yuv420p")
}

func gradient(w, h int) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{uint8(x * 255 / w), uint8(y * 255 / h), 128, 255})
		}
	}
	return img
}

// exifRot6JPEG encodes a 480x320 JPEG and inserts an APP1 EXIF segment with
// Orientation 6, DateTimeOriginal "2024:05:06 10:00:00" and GPS
// 38°43'20.28"N 9°8'21.48"W (38.7223, -9.1393).
func exifRot6JPEG(t *testing.T) []byte {
	var enc bytes.Buffer
	if err := jpeg.Encode(&enc, gradient(480, 320), &jpeg.Options{Quality: 60}); err != nil {
		t.Fatal(err)
	}
	be := binary.BigEndian
	var b bytes.Buffer
	w16 := func(v uint16) { _ = binary.Write(&b, be, v) }
	w32 := func(v uint32) { _ = binary.Write(&b, be, v) }
	entry := func(tag, typ uint16, count, value uint32) { w16(tag); w16(typ); w32(count); w32(value) }
	const (
		ifd0At  = 8
		exifAt  = ifd0At + 2 + 3*12 + 4 // 50
		dtoAt   = exifAt + 2 + 1*12 + 4 // 68
		gpsAt   = dtoAt + 20            // 88
		latAt   = gpsAt + 2 + 4*12 + 4  // 142
		lonAt   = latAt + 24            // 166
		tiffLen = lonAt + 24            // 190
	)
	b.WriteString("MM")
	w16(42)
	w32(ifd0At)
	// IFD0: Orientation (SHORT, inline), ExifIFD and GPS IFD pointers.
	w16(3)
	entry(0x0112, 3, 1, 6<<16)
	entry(0x8769, 4, 1, exifAt)
	entry(0x8825, 4, 1, gpsAt)
	w32(0)
	// Exif IFD: DateTimeOriginal.
	w16(1)
	entry(0x9003, 2, 20, dtoAt)
	w32(0)
	b.WriteString("2024:05:06 10:00:00\x00")
	// GPS IFD: refs inline as ASCII "N\0" / "W\0", coords as 3 RATIONALs.
	w16(4)
	entry(0x0001, 2, 2, uint32('N')<<24)
	entry(0x0002, 5, 3, latAt)
	entry(0x0003, 2, 2, uint32('W')<<24)
	entry(0x0004, 5, 3, lonAt)
	w32(0)
	for _, r := range [][2]uint32{{38, 1}, {43, 1}, {2028, 100}, {9, 1}, {8, 1}, {2148, 100}} {
		w32(r[0])
		w32(r[1])
	}
	if b.Len() != tiffLen {
		t.Fatalf("tiff layout %d, want %d", b.Len(), tiffLen)
	}
	payload := append([]byte("Exif\x00\x00"), b.Bytes()...)
	seg := []byte{0xFF, 0xE1, 0, 0}
	be.PutUint16(seg[2:], uint16(len(payload)+2))
	seg = append(seg, payload...)
	src := enc.Bytes()
	out := append([]byte{}, src[:2]...) // SOI
	out = append(out, seg...)
	return append(out, src[2:]...)
}

func plainPNG(t *testing.T) []byte {
	var b bytes.Buffer
	if err := png.Encode(&b, gradient(64, 48)); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func animGIF(t *testing.T) []byte {
	g := &gif.GIF{}
	for i := 0; i < 3; i++ {
		p := image.NewPaletted(image.Rect(0, 0, 40, 30), palette.Plan9)
		for y := 0; y < 30; y++ {
			for x := 0; x < 40; x++ {
				p.Set(x, y, color.RGBA{uint8(i * 80), uint8(x * 6), uint8(y * 8), 255})
			}
		}
		g.Image = append(g.Image, p)
		g.Delay = append(g.Delay, 10)
	}
	var b bytes.Buffer
	if err := gif.EncodeAll(&b, g); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

// corruptJPEG is a JPEG SOI/APP0 marker followed by 2 KiB of seeded noise.
func corruptJPEG() []byte {
	r := rand.New(rand.NewPCG(18, 18))
	out := []byte{0xFF, 0xD8, 0xFF, 0xE0}
	for i := 0; i < 2048; i++ {
		out = append(out, byte(r.UintN(256)))
	}
	return out
}
