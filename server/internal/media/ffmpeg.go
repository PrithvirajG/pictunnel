// Package media implements the 2B media pipeline primitives: image metadata,
// ffprobe, thumbnails, the browser-playable rule and transcoding. External
// tools are run without a shell, with a timeout, and killed on cancel.
package media

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/config"
)

// ErrToolMissing is returned when ffmpeg or ffprobe is needed but was not
// found. Jobs treat it as retryable (2B: "ffmpeg unavailable").
var ErrToolMissing = errors.New("ffmpeg unavailable")

// Timeouts for external tools.
const (
	ProbeTimeout     = 30 * time.Second
	ThumbTimeout     = 2 * time.Minute
	TranscodeTimeout = time.Hour
	// waitDelay bounds how long Wait blocks on the child's pipes after a kill.
	waitDelay = 5 * time.Second
	// stderrLimit caps the tool output quoted in errors.
	stderrLimit = 2048
)

// Tools holds the resolved ffmpeg and ffprobe paths; "" means unavailable.
type Tools struct{ FFmpeg, FFprobe string }

// FindTools resolves media.ffmpeg_path / media.ffprobe_path, falling back to
// PATH when unset. A configured path that does not exist resolves to "" (it
// is not silently replaced by a PATH lookup).
func FindTools(cfg config.Config) Tools {
	return Tools{
		FFmpeg:  findTool(cfg.Media.FFmpegPath, "ffmpeg"),
		FFprobe: findTool(cfg.Media.FFprobePath, "ffprobe"),
	}
}

func findTool(configured, name string) string {
	if configured != "" {
		if fi, err := os.Stat(configured); err == nil && !fi.IsDir() {
			return configured
		}
		return ""
	}
	p, err := exec.LookPath(name)
	if err != nil {
		return ""
	}
	return p
}

// run executes bin with args (no shell) under a timeout and returns stdout.
// The process is killed when ctx is cancelled or the timeout expires.
func run(ctx context.Context, timeout time.Duration, bin string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.WaitDelay = waitDelay
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	if err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return nil, fmt.Errorf("%s: %w", filepath.Base(bin), ctxErr)
		}
		msg := strings.TrimSpace(stderr.String())
		if len(msg) > stderrLimit {
			msg = msg[:stderrLimit]
		}
		return nil, fmt.Errorf("%s: %w: %s", filepath.Base(bin), err, msg)
	}
	return stdout.Bytes(), nil
}

// Probe is what ffprobe reports about a media file. Width and Height are the
// coded size; DisplaySize applies Rotation. Container is normalised to mp4,
// mov, webm, mkv or ffprobe's first format name.
type Probe struct {
	Width, Height          int
	DurationMS             *int64
	VideoCodec, AudioCodec string
	Container              string
	Rotation               int
	CreationTime           *time.Time
}

// DisplaySize returns width and height after applying Rotation.
func (p Probe) DisplaySize() (int, int) {
	if r := ((p.Rotation % 360) + 360) % 360; r == 90 || r == 270 {
		return p.Height, p.Width
	}
	return p.Width, p.Height
}

type ffprobeOut struct {
	Streams []struct {
		CodecType   string            `json:"codec_type"`
		CodecName   string            `json:"codec_name"`
		Width       int               `json:"width"`
		Height      int               `json:"height"`
		Tags        map[string]string `json:"tags"`
		Disposition map[string]int    `json:"disposition"`
		SideData    []struct {
			Type     string  `json:"side_data_type"`
			Rotation float64 `json:"rotation"`
		} `json:"side_data_list"`
	} `json:"streams"`
	Format struct {
		FormatName string            `json:"format_name"`
		Duration   string            `json:"duration"`
		Tags       map[string]string `json:"tags"`
	} `json:"format"`
}

// webmCodecs are the codecs a WebM file may carry; a Matroska file holding
// anything else is reported as mkv.
var webmCodecs = map[string]bool{"vp8": true, "vp9": true, "av1": true, "opus": true, "vorbis": true}

// FFprobe runs `ffprobe -v error -print_format json -show_format
// -show_streams` on path (2B). It uses the first non-attached-picture video
// stream and the first audio stream.
func FFprobe(ctx context.Context, t Tools, path string) (Probe, error) {
	if t.FFprobe == "" {
		return Probe{}, ErrToolMissing
	}
	in, err := inputArgs(path)
	if err != nil {
		return Probe{}, err
	}
	out, err := run(ctx, ProbeTimeout, t.FFprobe,
		append([]string{"-v", "error", "-print_format", "json", "-show_format", "-show_streams"}, in...)...)
	if err != nil {
		return Probe{}, err
	}
	var raw ffprobeOut
	if err := json.Unmarshal(out, &raw); err != nil {
		return Probe{}, fmt.Errorf("ffprobe: bad json: %w", err)
	}
	var p Probe
	var codecs []string
	haveVideo, haveAudio := false, false
	for _, s := range raw.Streams {
		switch s.CodecType {
		case "video":
			if s.Disposition["attached_pic"] == 1 {
				continue
			}
			codecs = append(codecs, s.CodecName)
			if haveVideo {
				continue
			}
			haveVideo = true
			p.VideoCodec, p.Width, p.Height = s.CodecName, s.Width, s.Height
			for _, sd := range s.SideData {
				if sd.Type == "Display Matrix" {
					p.Rotation = int(math.Round(sd.Rotation))
				}
			}
			if r, err := strconv.Atoi(s.Tags["rotate"]); err == nil && p.Rotation == 0 {
				p.Rotation = r
			}
		case "audio":
			codecs = append(codecs, s.CodecName)
			if !haveAudio {
				haveAudio = true
				p.AudioCodec = s.CodecName
			}
		}
	}
	p.Container = container(raw.Format.FormatName, raw.Format.Tags["major_brand"], codecs)
	if d, err := strconv.ParseFloat(raw.Format.Duration, 64); err == nil && d > 0 && !math.IsInf(d, 0) {
		ms := int64(math.Round(d * 1000))
		p.DurationMS = &ms
	}
	if ct := raw.Format.Tags["creation_time"]; ct != "" {
		if tm, err := time.Parse(time.RFC3339Nano, ct); err == nil && tm.Year() >= 1900 && tm.Year() <= 2200 && tm.Unix() > 0 {
			tm = tm.UTC()
			p.CreationTime = &tm
		}
	}
	return p, nil
}

func container(formatName, majorBrand string, codecs []string) string {
	names := strings.Split(formatName, ",")
	has := func(n string) bool {
		for _, x := range names {
			if x == n {
				return true
			}
		}
		return false
	}
	switch {
	case has("mov") && has("mp4"):
		if strings.TrimSpace(majorBrand) == "qt" {
			return "mov"
		}
		return "mp4"
	case has("webm") && has("matroska"):
		for _, c := range codecs {
			if !webmCodecs[c] {
				return "mkv"
			}
		}
		return "webm"
	}
	return names[0]
}

// Transcode converts src to a browser-playable H.264/AAC MP4 at dst (2B).
// It writes a temp file beside dst and renames it into place; a failed or
// cancelled run leaves no file behind.
func Transcode(ctx context.Context, t Tools, src, dst string) error {
	if t.FFmpeg == "" {
		return ErrToolMissing
	}
	tmp, err := tempName(filepath.Dir(dst), "web-*.mp4")
	if err != nil {
		return err
	}
	defer os.Remove(tmp)
	in, err := inputArgs(src)
	if err != nil {
		return err
	}
	out, err := fileURL(tmp)
	if err != nil {
		return err
	}
	args := append([]string{"-nostdin", "-v", "error", "-y"}, in...)
	args = append(args,
		"-map", "0:v:0", "-map", "0:a:0?",
		"-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
		// libx264 with yuv420p needs even dimensions.
		"-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
		"-c:a", "aac", "-b:a", "128k",
		"-movflags", "+faststart", "-pix_fmt", "yuv420p", "-f", "mp4", out)
	if _, err := run(ctx, TranscodeTimeout, t.FFmpeg, args...); err != nil {
		return err
	}
	return os.Rename(tmp, dst)
}

// image2Exts are extensions ffmpeg's image2 demuxer claims by name. For
// those it reads "%d" and glob characters in a file name as a sequence
// pattern.
var image2Exts = map[string]bool{
	"jpg": true, "jpeg": true, "jps": true, "mpo": true, "png": true, "bmp": true, "tga": true,
	"tif": true, "tiff": true, "dng": true, "webp": true, "gif": true, "jxl": true, "jp2": true,
	"j2k": true, "jpc": true, "j2c": true, "dpx": true, "exr": true, "pgm": true, "ppm": true,
	"pbm": true, "pnm": true, "pam": true, "pfm": true, "hdr": true, "qoi": true, "sgi": true,
	"pcx": true, "xbm": true, "xpm": true, "xwd": true, "sun": true, "ras": true, "pix": true,
}

// fileURL returns path as an absolute "file:" URL, so a name starting with
// "-" is never parsed as an option and one containing ":" never selects
// another protocol.
func fileURL(path string) (string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	return "file:" + abs, nil
}

// inputArgs returns the arguments that open path as an ffmpeg/ffprobe
// input. When the image2 demuxer would treat the name as a sequence pattern
// it is selected explicitly with pattern matching disabled. Other inputs
// keep content probing, so a mislabelled file still opens.
func inputArgs(path string) ([]string, error) {
	u, err := fileURL(path)
	if err != nil {
		return nil, err
	}
	// Uploaded files are untrusted: only real media demuxers may open them,
	// so a playlist or concat script cannot pull in another user's file.
	safe := []string{"-protocol_whitelist", "file", "-format_whitelist", inputFormats}
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(path), "."))
	if image2Exts[ext] && strings.ContainsAny(filepath.Base(path), "%*?[{") {
		return append(safe, "-f", "image2", "-pattern_type", "none", "-i", u), nil
	}
	return append(safe, "-i", u), nil
}

// inputFormats lists the demuxers allowed to open uploaded media.
const inputFormats = "mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,avi,mpegts,mpeg,asf,flv," +
	"image2,gif,png_pipe,jpeg_pipe,webp_pipe,tiff_pipe,bmp_pipe,heif"

// tempName reserves a unique file name in dir matching pattern and returns
// its path; the empty file exists until the caller removes or replaces it.
func tempName(dir, pattern string) (string, error) {
	f, err := os.CreateTemp(dir, "."+pattern)
	if err != nil {
		return "", err
	}
	name := f.Name()
	if err := f.Close(); err != nil {
		_ = os.Remove(name)
		return "", err
	}
	return name, nil
}
