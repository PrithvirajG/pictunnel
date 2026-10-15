package media

import (
	"errors"
	"fmt"
	"image"
	_ "image/gif" // register decoders for DecodeConfig
	_ "image/jpeg"
	_ "image/png"
	"io"
	"math"
	"os"
	"time"

	"github.com/evanoberholster/imagemeta"
	"github.com/evanoberholster/imagemeta/meta/exif"
	_ "golang.org/x/image/webp" // register the WebP decoder

	"github.com/PrithvirajG/pictunnel/server/internal/media/probe"
)

// ImageMeta is the metadata extract_metadata reads from a still image.
// Width and Height are the displayed size (EXIF orientation applied).
type ImageMeta struct {
	Width, Height int
	Lat, Lon      *float64
	Taken         *probe.DateResult
	Orientation   int // EXIF orientation 1–8; 0 when absent
}

// ReadImageMeta reads an image's size, EXIF orientation, GPS position and
// capture date. The size comes from the pure-Go decoders (jpeg, png, gif,
// webp) or, for other formats, from EXIF dimensions. It fails when neither
// yields a size; callers may then fall back to ffprobe. It only parses
// headers and metadata (image.DecodeConfig, imagemeta), never the pixel
// data, so a header declaring a huge size allocates nothing.
func ReadImageMeta(path string) (ImageMeta, error) {
	f, err := os.Open(path)
	if err != nil {
		return ImageMeta{}, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return ImageMeta{}, err
	}
	var m ImageMeta
	cfg, _, cfgErr := image.DecodeConfig(f)
	if cfgErr == nil {
		m.Width, m.Height = cfg.Width, cfg.Height
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return ImageMeta{}, err
	}
	ex, exErr := decodeExif(f)
	if exErr == nil {
		m.Orientation = int(ex.IFD0.Orientation)
		if m.Orientation < 1 || m.Orientation > 8 {
			m.Orientation = 0
		}
		if m.Width == 0 || m.Height == 0 {
			m.Width, m.Height = int(ex.ExifIFD.PixelXDimension), int(ex.ExifIFD.PixelYDimension)
			if m.Width == 0 || m.Height == 0 {
				m.Width, m.Height = int(ex.IFD0.ImageWidth), int(ex.IFD0.ImageHeight)
			}
		}
		lat, lon := ex.GPS.Latitude(), ex.GPS.Longitude()
		if validCoord(lat, 90) && validCoord(lon, 180) && (lat != 0 || lon != 0) {
			m.Lat, m.Lon = &lat, &lon
		}
	}
	if m.Width <= 0 || m.Height <= 0 {
		return ImageMeta{}, fmt.Errorf("image meta: no dimensions: %w", errors.Join(cfgErr, exErr))
	}
	if m.Orientation >= 5 {
		m.Width, m.Height = m.Height, m.Width
	}
	if d, ok := probe.FastDate(f, fi.Size(), "image/*"); ok {
		m.Taken = &d
	} else if exErr == nil {
		// FastDate only reads the first 512 KiB; the full EXIF decode above
		// may have found the date further in.
		if d, ok := exifDate(ex); ok {
			m.Taken = &d
		}
	}
	return m, nil
}

// exifDate is DateTimeOriginal (+ OffsetTimeOriginal) from decoded EXIF,
// with the same rules as probe.FastDate: the wall clock is taken as UTC
// unless an offset is recorded, and implausible years are ignored.
func exifDate(ex exifData) (probe.DateResult, bool) {
	d := ex.ExifIFD.DateTimeOriginal
	if d.IsZero() {
		return probe.DateResult{}, false
	}
	wall := time.Date(d.Year(), d.Month(), d.Day(), d.Hour(), d.Minute(), d.Second(), d.Nanosecond(), time.UTC)
	if y := wall.Year(); y < 1900 || y > 2200 {
		return probe.DateResult{}, false
	}
	res := probe.DateResult{Time: wall, Source: probe.SourceExif}
	if loc := ex.ExifIFD.OffsetTimeOriginal; loc != nil {
		_, off := time.Date(2000, 1, 1, 0, 0, 0, 0, loc).Zone()
		if off%60 == 0 && off >= -16*3600 && off <= 16*3600 {
			mins := off / 60
			res.OffsetMinutes = &mins
			res.Time = wall.Add(-time.Duration(off) * time.Second)
		}
	}
	return res, true
}

type exifData = exif.Exif

func validCoord(v, limit float64) bool {
	return !math.IsNaN(v) && !math.IsInf(v, 0) && v >= -limit && v <= limit
}

// orientation reads only the EXIF orientation (0 when unknown).
func orientation(r io.ReadSeeker) int {
	ex, err := decodeExif(r)
	if err != nil {
		return 0
	}
	if o := int(ex.IFD0.Orientation); o >= 1 && o <= 8 {
		return o
	}
	return 0
}

// decodeExif wraps imagemeta.Decode, turning panics on crafted input into
// errors.
func decodeExif(r io.ReadSeeker) (ex exifData, err error) {
	defer func() {
		if p := recover(); p != nil {
			ex, err = exifData{}, fmt.Errorf("exif: panic: %v", p)
		}
	}()
	return imagemeta.Decode(r)
}
