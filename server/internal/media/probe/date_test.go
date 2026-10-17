package probe

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func load(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestFastDateJPEG(t *testing.T) {
	b := load(t, "exif.jpg")
	r, ok := FastDate(bytes.NewReader(b), int64(len(b)), "image/jpeg")
	if !ok {
		t.Fatal("ok = false")
	}
	if want := time.Date(2024, 5, 6, 8, 0, 0, 0, time.UTC); !r.Time.Equal(want) || r.Time.Location() != time.UTC {
		t.Fatalf("time = %v, want %v (UTC)", r.Time, want)
	}
	if r.OffsetMinutes == nil || *r.OffsetMinutes != 120 {
		t.Fatalf("offset = %v, want 120", r.OffsetMinutes)
	}
	if r.Source != "exif" {
		t.Fatalf("source = %q", r.Source)
	}
}

func TestFastDateJPEGWithoutOffset(t *testing.T) {
	b := load(t, "exif.jpg")
	// Turn tag 0x9011 into an unknown tag so only DateTimeOriginal remains.
	i := bytes.Index(b, []byte{0x90, 0x11, 0x00, 0x02})
	if i < 0 {
		t.Fatal("offset tag not found")
	}
	c := bytes.Clone(b)
	c[i], c[i+1] = 0xC0, 0x00
	r, ok := FastDate(bytes.NewReader(c), int64(len(c)), "image/jpeg")
	if !ok {
		t.Fatal("ok = false")
	}
	if want := time.Date(2024, 5, 6, 10, 0, 0, 0, time.UTC); !r.Time.Equal(want) {
		t.Fatalf("time = %v, want naive wall time %v", r.Time, want)
	}
	if r.OffsetMinutes != nil {
		t.Fatalf("offset = %d, want nil", *r.OffsetMinutes)
	}
}

func TestFastDateMP4(t *testing.T) {
	b := load(t, "clip.mp4")
	r, ok := FastDate(bytes.NewReader(b), int64(len(b)), "video/mp4")
	if !ok {
		t.Fatal("ok = false")
	}
	if want := time.Date(2023, 1, 2, 3, 4, 5, 0, time.UTC); !r.Time.Equal(want) {
		t.Fatalf("time = %v, want %v", r.Time, want)
	}
	if r.Source != "container" || r.OffsetMinutes != nil {
		t.Fatalf("source = %q offset = %v", r.Source, r.OffsetMinutes)
	}
}

// box builds an ISO-BMFF box.
func box(typ string, body []byte) []byte {
	out := make([]byte, 8, 8+len(body))
	binary.BigEndian.PutUint32(out, uint32(8+len(body)))
	copy(out[4:], typ)
	return append(out, body...)
}

func TestFastDateMvhdVersion1AndLargeSize(t *testing.T) {
	// mvhd v1: 4 bytes version/flags, 8 bytes creation, 8 modification.
	body := make([]byte, 4+8+8+4+8)
	body[0] = 1
	secs := uint64(time.Date(2020, 2, 3, 4, 5, 6, 0, time.UTC).Sub(mp4Epoch) / time.Second)
	binary.BigEndian.PutUint64(body[4:], secs)
	moov := box("moov", box("mvhd", body))
	// A free box with a 64-bit largesize precedes moov.
	free := make([]byte, 16+10)
	binary.BigEndian.PutUint32(free, 1)
	copy(free[4:], "free")
	binary.BigEndian.PutUint64(free[8:], uint64(len(free)))
	file := append(append(box("ftyp", []byte("isom\x00\x00\x02\x00")), free...), moov...)
	r, ok := FastDate(bytes.NewReader(file), int64(len(file)), "video/quicktime")
	if !ok || !r.Time.Equal(time.Date(2020, 2, 3, 4, 5, 6, 0, time.UTC)) {
		t.Fatalf("got %v %v", r, ok)
	}
}

func TestFastDateMoovBeyondLimit(t *testing.T) {
	body := make([]byte, 4+4+4+4+4)
	binary.BigEndian.PutUint32(body[4:], 3600)
	mdat := box("mdat", make([]byte, MaxProbeBytes))
	file := append(append(box("ftyp", []byte("isom")), mdat...), box("moov", box("mvhd", body))...)
	if r, ok := FastDate(bytes.NewReader(file), int64(len(file)), "video/mp4"); ok {
		t.Fatalf("ok with moov past %d bytes: %v", MaxProbeBytes, r)
	}
}

func TestFastDateZeroCreationIsUnknown(t *testing.T) {
	body := make([]byte, 4+4+4+4+4)
	file := box("moov", box("mvhd", body))
	if _, ok := FastDate(bytes.NewReader(file), int64(len(file)), "video/mp4"); ok {
		t.Fatal("zero creation_time reported as known")
	}
}

func TestFastDateGarbage(t *testing.T) {
	cases := map[string][]byte{
		"empty":     nil,
		"text":      []byte("hello, this is not media"),
		"soi only":  {0xFF, 0xD8},
		"bad app1":  {0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF, 'E', 'x', 'i', 'f', 0, 0, 'M', 'M'},
		"huge box":  {0xFF, 0xFF, 0xFF, 0xFF, 'm', 'o', 'o', 'v'},
		"small box": {0, 0, 0, 3, 'm', 'o', 'o', 'v'},
	}
	for name, b := range cases {
		for _, mime := range []string{"image/jpeg", "image/heic", "video/mp4", "application/octet-stream"} {
			if r, ok := FastDate(bytes.NewReader(b), int64(len(b)), mime); ok {
				t.Errorf("%s/%s: ok = true (%v)", name, mime, r)
			}
		}
	}
}

func TestFastDateUnsupportedMime(t *testing.T) {
	b := load(t, "exif.jpg")
	if _, ok := FastDate(bytes.NewReader(b), int64(len(b)), "application/pdf"); ok {
		t.Fatal("non-media mime probed")
	}
}

func FuzzFastDate(f *testing.F) {
	jpg, _ := os.ReadFile(filepath.Join("testdata", "exif.jpg"))
	mp4, _ := os.ReadFile(filepath.Join("testdata", "clip.mp4"))
	f.Add(jpg, true)
	f.Add(mp4, false)
	f.Add([]byte{0xFF, 0xD8, 0xFF, 0xE1, 0, 8, 'E', 'x', 'i', 'f'}, true)
	f.Fuzz(func(t *testing.T, b []byte, image bool) {
		mime := "video/mp4"
		if image {
			mime = "image/jpeg"
		}
		r, ok := FastDate(bytes.NewReader(b), int64(len(b)), mime)
		if ok && (r.Time.IsZero() || (r.Source != "exif" && r.Source != "container")) {
			t.Fatalf("ok with invalid result %+v", r)
		}
	})
}
