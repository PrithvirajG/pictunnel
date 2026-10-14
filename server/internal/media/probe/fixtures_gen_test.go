package probe

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/jpeg"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// TestGenerateFixtures rewrites testdata/. It only runs with
// PT_GEN_FIXTURES=1 (and ffmpeg on PATH for clip.mp4); the outputs are
// committed so normal runs never need ffmpeg.
func TestGenerateFixtures(t *testing.T) {
	if os.Getenv("PT_GEN_FIXTURES") != "1" {
		t.Skip("set PT_GEN_FIXTURES=1 to regenerate testdata")
	}
	if err := os.WriteFile(filepath.Join("testdata", "exif.jpg"), exifJPEG(t), 0o644); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join("testdata", "clip.mp4")
	cmd := exec.Command("ffmpeg", "-nostdin", "-v", "error", "-y",
		"-f", "lavfi", "-i", "color=c=blue:s=64x48:d=1:r=10",
		"-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p",
		"-metadata", "creation_time=2023-01-02T03:04:05Z",
		"-movflags", "+faststart", out)
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("ffmpeg: %v\n%s", err, b)
	}
}

// exifJPEG encodes a 64x48 JPEG and inserts an APP1 EXIF segment holding
// DateTimeOriginal "2024:05:06 10:00:00" and OffsetTimeOriginal "+02:00".
func exifJPEG(t *testing.T) []byte {
	img := image.NewRGBA(image.Rect(0, 0, 64, 48))
	for y := 0; y < 48; y++ {
		for x := 0; x < 64; x++ {
			img.Set(x, y, color.RGBA{uint8(x * 4), uint8(y * 5), 128, 255})
		}
	}
	var enc bytes.Buffer
	if err := jpeg.Encode(&enc, img, &jpeg.Options{Quality: 50}); err != nil {
		t.Fatal(err)
	}
	be := binary.BigEndian
	var tiff bytes.Buffer
	w16 := func(v uint16) { binary.Write(&tiff, be, v) }
	w32 := func(v uint32) { binary.Write(&tiff, be, v) }
	// TIFF header.
	tiff.WriteString("MM")
	w16(42)
	w32(8)
	// IFD0 at 8: one entry, ExifIFDPointer → 26.
	w16(1)
	w16(0x8769)
	w16(4) // LONG
	w32(1)
	w32(26)
	w32(0) // next IFD
	// Exif IFD at 26: two entries, data at 56 and 76.
	w16(2)
	w16(0x9003) // DateTimeOriginal
	w16(2)      // ASCII
	w32(20)
	w32(56)
	w16(0x9011) // OffsetTimeOriginal
	w16(2)
	w32(7)
	w32(76)
	w32(0)
	tiff.WriteString("2024:05:06 10:00:00\x00")
	tiff.WriteString("+02:00\x00\x00")
	if tiff.Len() != 84 {
		t.Fatalf("tiff layout %d", tiff.Len())
	}
	payload := append([]byte("Exif\x00\x00"), tiff.Bytes()...)
	var out bytes.Buffer
	b := enc.Bytes()
	out.Write(b[:2]) // SOI
	out.Write([]byte{0xFF, 0xE1})
	binary.Write(&out, be, uint16(len(payload)+2))
	out.Write(payload)
	out.Write(b[2:])
	return out.Bytes()
}
