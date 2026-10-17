// Package probe reads capture dates from the head of media files during
// finalize (2B design: fast date probe). It imports no domain package.
package probe

import (
	"io"
	"strings"
	"time"

	"github.com/evanoberholster/imagemeta"
)

// MaxProbeBytes is how much of a file FastDate reads (512 KiB).
const MaxProbeBytes = 512 << 10

// Sources reported in DateResult.Source.
const (
	SourceExif      = "exif"
	SourceContainer = "container"
)

// DateResult is an embedded capture date. Time is UTC. OffsetMinutes is the
// capture's UTC offset when the file records one; when it is nil an EXIF
// time is the naive wall-clock time expressed as UTC.
type DateResult struct {
	Time          time.Time
	OffsetMinutes *int
	Source        string // "exif" | "container"
}

// FastDate reads at most MaxProbeBytes from r and returns the embedded capture
// date: EXIF DateTimeOriginal (+ OffsetTimeOriginal) for image/*, the
// ISO-BMFF mvhd creation time for video/*. It never panics and reports
// ok=false for anything it cannot read.
func FastDate(r io.ReaderAt, size int64, mime string) (res DateResult, ok bool) {
	defer func() {
		if p := recover(); p != nil {
			res, ok = DateResult{}, false
		}
	}()
	if r == nil || size <= 0 {
		return DateResult{}, false
	}
	n := min(size, MaxProbeBytes)
	sec := io.NewSectionReader(r, 0, n)
	mime = strings.ToLower(strings.TrimSpace(mime))
	switch {
	case strings.HasPrefix(mime, "image/"):
		return exifDate(sec)
	case strings.HasPrefix(mime, "video/"):
		return mvhdDate(sec, n)
	}
	return DateResult{}, false
}

// minYear and maxYear bound plausible capture dates; anything outside is
// treated as corrupt.
const (
	minYear = 1900
	maxYear = 2200
)

func plausible(t time.Time) bool {
	y := t.Year()
	return !t.IsZero() && y >= minYear && y <= maxYear
}

func exifDate(rs io.ReadSeeker) (DateResult, bool) {
	e, err := imagemeta.Decode(rs)
	if err != nil {
		return DateResult{}, false
	}
	d := e.ExifIFD.DateTimeOriginal
	if d.IsZero() {
		return DateResult{}, false
	}
	// Re-read the wall clock so the result does not depend on the
	// location imagemeta attached.
	wall := time.Date(d.Year(), d.Month(), d.Day(), d.Hour(), d.Minute(), d.Second(), d.Nanosecond(), time.UTC)
	if !plausible(wall) {
		return DateResult{}, false
	}
	res := DateResult{Time: wall, Source: SourceExif}
	if loc := e.ExifIFD.OffsetTimeOriginal; loc != nil {
		_, off := time.Date(2000, 1, 1, 0, 0, 0, 0, loc).Zone()
		if off%60 == 0 && off >= -16*3600 && off <= 16*3600 {
			m := off / 60
			res.OffsetMinutes = &m
			res.Time = wall.Add(-time.Duration(off) * time.Second)
		}
	}
	return res, true
}
