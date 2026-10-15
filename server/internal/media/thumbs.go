package media

import (
	"context"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"golang.org/x/image/draw"
)

// Derived thumbnail names and sizes (2B).
const (
	ThumbName       = "thumb.jpg"
	PreviewName     = "preview.jpg"
	ThumbLongSide   = 320
	PreviewLongSide = 1600
	thumbQuality    = 80
	previewQuality  = 85
	// videoSeekMS is the latest point (ms) a video frame is taken from.
	videoSeekMS = 1000
)

// pureGoMimes are decoded in-process (2B decoder choice).
var pureGoMimes = map[string]bool{
	"image/jpeg": true, "image/jpg": true, "image/pjpeg": true,
	"image/png": true, "image/gif": true, "image/webp": true,
}

// MakeThumbnails writes thumb.jpg (long side 320, q80) and preview.jpg (long
// side 1600, q85) for src into outDir. JPEG, PNG, GIF and WebP stills are
// decoded in Go with EXIF orientation applied; everything else (HEIC, AVIF,
// TIFF, RAW, video) goes through ffmpeg, which needs t.FFmpeg
// (ErrToolMissing otherwise). Images never upscale. Each file is written to
// a temp name in outDir and renamed into place.
func MakeThumbnails(ctx context.Context, t Tools, src, mime string, isVideo bool, outDir string) error {
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}
	mime = strings.ToLower(strings.TrimSpace(mime))
	if !isVideo && pureGoMimes[mime] {
		img, err := decodeOriented(src)
		if err == nil {
			return writeBoth(img, outDir)
		}
		// A mislabelled file (e.g. HEIC named .jpg) may still be readable
		// by ffmpeg; a corrupt one of the declared type fails here.
		if !errors.Is(err, image.ErrFormat) || t.FFmpeg == "" {
			return fmt.Errorf("thumbnails: decode: %w", err)
		}
	}
	if t.FFmpeg == "" {
		return ErrToolMissing
	}
	return ffmpegThumbs(ctx, t, src, isVideo, outDir)
}

// decodeOriented decodes a still and applies its EXIF orientation.
func decodeOriented(src string) (image.Image, error) {
	f, err := os.Open(src)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	img, _, err := image.Decode(f)
	if err != nil {
		return nil, err
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	o := orientation(f)
	// Scale before rotating: the long side is the same either way and the
	// rotation then runs on at most a 1600 px image.
	return orient(fit(img, PreviewLongSide), o), nil
}

// writeBoth encodes preview from img (already at most 1600 px) and the thumb
// from the preview, then renames both into place.
func writeBoth(preview image.Image, outDir string) error {
	thumb := fit(preview, ThumbLongSide)
	if err := writeJPEG(filepath.Join(outDir, ThumbName), thumb, thumbQuality); err != nil {
		return err
	}
	return writeJPEG(filepath.Join(outDir, PreviewName), preview, previewQuality)
}

// fitSize returns w×h scaled down so the long side is at most long.
func fitSize(w, h, long int) (int, int) {
	m := max(w, h)
	if m <= long {
		return w, h
	}
	s := float64(long) / float64(m)
	return max(1, int(math.Round(float64(w)*s))), max(1, int(math.Round(float64(h)*s)))
}

// fit downscales img so its long side is at most long; it never upscales.
func fit(img image.Image, long int) image.Image {
	b := img.Bounds()
	w, h := fitSize(b.Dx(), b.Dy(), long)
	if w == b.Dx() && h == b.Dy() {
		return img
	}
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.CatmullRom.Scale(dst, dst.Bounds(), img, b, draw.Src, nil)
	return dst
}

// orient applies EXIF orientation o (1–8) to img.
func orient(img image.Image, o int) image.Image {
	if o <= 1 || o > 8 {
		return img
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	dw, dh := w, h
	if o >= 5 {
		dw, dh = h, w
	}
	dst := image.NewRGBA(image.Rect(0, 0, dw, dh))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			var dx, dy int
			switch o {
			case 2: // mirror horizontal
				dx, dy = w-1-x, y
			case 3: // rotate 180
				dx, dy = w-1-x, h-1-y
			case 4: // mirror vertical
				dx, dy = x, h-1-y
			case 5: // transpose
				dx, dy = y, x
			case 6: // rotate 90 CW
				dx, dy = h-1-y, x
			case 7: // transverse
				dx, dy = h-1-y, w-1-x
			case 8: // rotate 90 CCW
				dx, dy = y, w-1-x
			}
			dst.Set(dx, dy, img.At(b.Min.X+x, b.Min.Y+y))
		}
	}
	return dst
}

// writeJPEG encodes img to a temp file in dst's directory and renames it.
func writeJPEG(dst string, img image.Image, quality int) error {
	f, err := os.CreateTemp(filepath.Dir(dst), "."+strings.TrimSuffix(filepath.Base(dst), ".jpg")+"-*.jpg")
	if err != nil {
		return err
	}
	tmp := f.Name()
	err = jpeg.Encode(f, img, &jpeg.Options{Quality: quality})
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, dst)
	}
	if err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("thumbnails: write %s: %w", filepath.Base(dst), err)
	}
	return nil
}

// ffmpegThumbs extracts one frame at preview size with ffmpeg, then derives
// the thumb from it in Go. Video seeks to min(1 s, duration/2).
func ffmpegThumbs(ctx context.Context, t Tools, src string, isVideo bool, outDir string) error {
	seekMS := int64(0)
	if isVideo {
		seekMS = videoSeekMS
		if p, err := FFprobe(ctx, t, src); err == nil && p.DurationMS != nil {
			seekMS = min(seekMS, *p.DurationMS/2)
		}
	}
	tmp, err := tempName(outDir, "frame-*.jpg")
	if err != nil {
		return err
	}
	defer os.Remove(tmp)
	extract := func(seekMS int64) error {
		args := []string{"-nostdin", "-v", "error", "-y"}
		if seekMS > 0 {
			args = append(args, "-ss", strconv.FormatFloat(float64(seekMS)/1000, 'f', 3, 64))
		}
		args = append(args, "-i", src, "-frames:v", "1",
			"-vf", fmt.Sprintf("scale='min(%d,iw)':'min(%d,ih)':force_original_aspect_ratio=decrease", PreviewLongSide, PreviewLongSide),
			"-q:v", "3", "-update", "1", "-f", "image2", tmp)
		if _, err := run(ctx, ThumbTimeout, t.FFmpeg, args...); err != nil {
			return err
		}
		if fi, err := os.Stat(tmp); err != nil || fi.Size() == 0 {
			return errors.New("ffmpeg: no frame decoded")
		}
		return nil
	}
	err = extract(seekMS)
	if err != nil && seekMS > 0 && ctx.Err() == nil {
		err = extract(0) // the seek may land past the last frame
	}
	if err != nil {
		return fmt.Errorf("thumbnails: %w", err)
	}
	f, err := os.Open(tmp)
	if err != nil {
		return err
	}
	frame, err := jpeg.Decode(f)
	_ = f.Close()
	if err != nil {
		return fmt.Errorf("thumbnails: decode ffmpeg frame: %w", err)
	}
	return writeBoth(fit(frame, PreviewLongSide), outDir)
}
