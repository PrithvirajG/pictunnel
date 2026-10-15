package service

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"path/filepath"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/clock"
	"github.com/PrithvirajG/pictunnel/server/internal/jobs"
	"github.com/PrithvirajG/pictunnel/server/internal/media"
	"github.com/PrithvirajG/pictunnel/server/internal/media/probe"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

// JobTranscodeVideo is enqueued by extract_metadata for a video that is not
// browser-playable (2B).
const JobTranscodeVideo = "transcode_video"

// MediaJobMaxAttempts bounds retries of extract_metadata,
// generate_thumbnails and transcode_video (a corrupt input goes dead after
// three failures).
const MediaJobMaxAttempts = 3

// Date sources that came from the file itself; extract_metadata never
// replaces them.
const (
	takenSourceExif      = probe.SourceExif
	takenSourceContainer = probe.SourceContainer
)

// MediaServiceDeps are the MediaService dependencies. Failpoints is nil in
// production.
type MediaServiceDeps struct {
	Store      *store.Store
	Assets     repository.AssetsRepository
	LiveVideos repository.LiveVideosRepository
	ChangeLog  repository.ChangeLogRepository
	Jobs       JobEnqueuer
	FS         storage.FS
	Tools      media.Tools
	Clock      clock.Clock
	Failpoints Failpoints
	// DataDir holds derived/; LibraryDir is the root original_path is
	// relative to.
	DataDir    string
	LibraryDir string
}

// MediaService implements the 2B media jobs: extract_metadata,
// generate_thumbnails and transcode_video.
//
// Every handler treats an asset that no longer exists as success. Jobs that
// write into derived/ re-check the asset in the transaction that records
// the result; if it was purged meanwhile they delete the derived directory
// they wrote and succeed. A missing ffmpeg/ffprobe returns
// media.ErrToolMissing, which is retryable. A corrupt input returns an
// ordinary error, so MediaJobMaxAttempts bounds the retries.
type MediaService struct{ d MediaServiceDeps }

// NewMediaService returns a MediaService.
func NewMediaService(d MediaServiceDeps) *MediaService { return &MediaService{d: d} }

// mediaPayload is the media job payload written by finalize.
type mediaPayload struct {
	AssetID string `json:"asset_id"`
}

func parseMediaPayload(kind string, payload []byte) (string, error) {
	var p mediaPayload
	if err := json.Unmarshal(payload, &p); err != nil {
		return "", &jobs.Permanent{Err: fmt.Errorf("%s: bad payload: %w", kind, err)}
	}
	if !uuidRe.MatchString(p.AssetID) {
		return "", &jobs.Permanent{Err: fmt.Errorf("%s: bad asset id %q", kind, p.AssetID)}
	}
	return p.AssetID, nil
}

// load returns the asset, or ok=false when it no longer exists.
func (s *MediaService) load(ctx context.Context, id string) (repository.Asset, bool, error) {
	a, err := s.d.Assets.GetByID(ctx, s.d.Store.R, id)
	if errors.Is(err, repository.ErrNotFound) {
		return repository.Asset{}, false, nil
	}
	if err != nil {
		return repository.Asset{}, false, err
	}
	return a, true, nil
}

func metadataOf(a repository.Asset) repository.MetadataUpdate {
	return repository.MetadataUpdate{
		TakenAt: a.TakenAt, TakenAtOffsetMinutes: a.TakenAtOffsetMinutes, TakenAtSource: a.TakenAtSource,
		Width: a.Width, Height: a.Height, DurationMs: a.DurationMs, Lat: a.Lat, Lon: a.Lon,
		StackKey: a.StackKey, StackID: a.StackID, VideoCodec: a.VideoCodec, AudioCodec: a.AudioCodec,
		Container: a.Container, Playable: a.Playable,
	}
}

// setDate records an embedded capture date unless the asset already has one
// read from the file (2B fallback order: probe beats client and file dates).
// The library path never changes.
func setDate(m *repository.MetadataUpdate, d probe.DateResult) {
	if m.TakenAt != nil && (m.TakenAtSource == takenSourceExif || m.TakenAtSource == takenSourceContainer) {
		return
	}
	t := d.Time.UTC()
	m.TakenAt, m.TakenAtSource, m.TakenAtOffsetMinutes = &t, d.Source, nil
	if d.OffsetMinutes != nil {
		off := int64(*d.OffsetMinutes)
		m.TakenAtOffsetMinutes = &off
	}
}

func ptr[T any](v T) *T { return &v }

func nonEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// ExtractMetadata is the extract_metadata job (2B). Stills: size
// (orientation-corrected), GPS and the date if missing, via imagemeta, with
// ffprobe as the size fallback for formats Go cannot read. Videos: ffprobe
// for size, duration, codecs, container, rotation, creation_time and the
// playable flag; a non-playable video gets a transcode_video job. A Live
// Photo also probes its video component for duration_ms, so the order of
// the primary's and the component's jobs does not matter. It updates the
// row and appends asset.upsert.
//
// Without ffprobe a video fails retryably with media.ErrToolMissing and
// playable stays NULL (playback is not_ready). A Live Photo's still
// metadata is written first and the job then fails retryably for the
// duration.
func (s *MediaService) ExtractMetadata(ctx context.Context, payload []byte) error {
	id, err := parseMediaPayload(JobExtractMetadata, payload)
	if err != nil {
		return err
	}
	a, ok, err := s.load(ctx, id)
	if err != nil || !ok {
		return err
	}
	src := libraryAbs(s.d.LibraryDir, a.OriginalPath)
	var apply []func(*repository.MetadataUpdate)
	var deferred error
	transcode := false
	switch a.Kind {
	case assetKindVideo:
		p, err := media.FFprobe(ctx, s.d.Tools, src)
		if err != nil {
			return fmt.Errorf("extract_metadata: %w", err)
		}
		playable := media.Playable(p)
		transcode = !playable
		apply = append(apply, func(m *repository.MetadataUpdate) {
			if w, h := p.DisplaySize(); w > 0 && h > 0 {
				m.Width, m.Height = ptr(int64(w)), ptr(int64(h))
			}
			m.DurationMs = p.DurationMS
			m.VideoCodec, m.AudioCodec, m.Container = nonEmpty(p.VideoCodec), nonEmpty(p.AudioCodec), nonEmpty(p.Container)
			m.Playable = &playable
			if p.CreationTime != nil {
				setDate(m, probe.DateResult{Time: *p.CreationTime, Source: takenSourceContainer})
			}
		})
	default: // photo, live_photo
		f, err := s.stillMeta(ctx, src)
		if err != nil {
			return fmt.Errorf("extract_metadata: %w", err)
		}
		apply = append(apply, f)
		if a.Kind == assetKindLive {
			f, err := s.liveDuration(ctx, a.ID)
			if err != nil {
				deferred = fmt.Errorf("extract_metadata: live video: %w", err)
			} else if f != nil {
				apply = append(apply, f)
			}
		}
	}
	err = s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		cur, err := s.d.Assets.GetByID(ctx, tx, id)
		if errors.Is(err, repository.ErrNotFound) {
			return nil // purged meanwhile
		}
		if err != nil {
			return err
		}
		m := metadataOf(cur)
		for _, f := range apply {
			f(&m)
		}
		seq, err := appendAssetChange(ctx, tx, s.d.ChangeLog, cur.OwnerID, changeAssetUpsert, id, s.d.Clock.Now())
		if err != nil {
			return err
		}
		if err := s.d.Assets.UpdateMetadata(ctx, tx, id, m, seq); err != nil {
			return err
		}
		if transcode {
			return s.d.Jobs.Enqueue(ctx, tx, JobTranscodeVideo, id, payload, time.Time{})
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("extract_metadata: %w", err)
	}
	return deferred
}

// stillMeta reads a still image's metadata, falling back to ffprobe for the
// size when the Go readers and EXIF do not yield one (HEIC, AVIF, RAW).
func (s *MediaService) stillMeta(ctx context.Context, src string) (func(*repository.MetadataUpdate), error) {
	im, err := media.ReadImageMeta(src)
	if err == nil {
		return func(m *repository.MetadataUpdate) {
			m.Width, m.Height = ptr(int64(im.Width)), ptr(int64(im.Height))
			m.Lat, m.Lon = im.Lat, im.Lon
			if im.Taken != nil {
				setDate(m, *im.Taken)
			}
		}, nil
	}
	p, perr := media.FFprobe(ctx, s.d.Tools, src)
	if perr != nil {
		if errors.Is(perr, media.ErrToolMissing) {
			return nil, perr
		}
		return nil, fmt.Errorf("image metadata: %w; ffprobe: %w", err, perr)
	}
	w, h := p.DisplaySize()
	if w <= 0 || h <= 0 {
		return nil, fmt.Errorf("image metadata: %w; ffprobe found no image size", err)
	}
	return func(m *repository.MetadataUpdate) {
		m.Width, m.Height = ptr(int64(w)), ptr(int64(h))
	}, nil
}

// liveDuration probes a Live Photo's video component; nil when it has none.
func (s *MediaService) liveDuration(ctx context.Context, assetID string) (func(*repository.MetadataUpdate), error) {
	lv, err := s.d.LiveVideos.GetByAsset(ctx, s.d.Store.R, assetID)
	if errors.Is(err, repository.ErrNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	p, err := media.FFprobe(ctx, s.d.Tools, libraryAbs(s.d.LibraryDir, lv.OriginalPath))
	if err != nil {
		return nil, err
	}
	return func(m *repository.MetadataUpdate) { m.DurationMs = p.DurationMS }, nil
}

// GenerateThumbnails is the generate_thumbnails job (2B): it writes
// derived/<id[0:2]>/<id[2:4]>/<id>/{thumb,preview}.jpg, then sets
// thumbnails_ready and appends asset.upsert. A Live Photo uses its still.
func (s *MediaService) GenerateThumbnails(ctx context.Context, payload []byte) error {
	id, err := parseMediaPayload(JobGenerateThumbnails, payload)
	if err != nil {
		return err
	}
	dir := derivedDir(s.d.DataDir, id)
	a, ok, err := s.load(ctx, id)
	if err != nil {
		return err
	}
	if !ok {
		return s.removeDerived(dir)
	}
	src := libraryAbs(s.d.LibraryDir, a.OriginalPath)
	if err := media.MakeThumbnails(ctx, s.d.Tools, src, a.Mime, a.Kind == assetKindVideo, dir); err != nil {
		return fmt.Errorf("generate_thumbnails: %w", err)
	}
	return s.commitDerived(ctx, id, dir, func(tx *sql.Tx, cur repository.Asset) error {
		seq, err := appendAssetChange(ctx, tx, s.d.ChangeLog, cur.OwnerID, changeAssetUpsert, id, s.d.Clock.Now())
		if err != nil {
			return err
		}
		return s.d.Assets.SetThumbnailsReady(ctx, tx, id, seq)
	})
}

// TranscodeVideo is the transcode_video job (2B): it writes derived web.mp4
// (H.264/AAC, faststart) for a video known not to be browser-playable and
// appends asset.upsert so clients refresh playback. Anything else is a
// no-op.
func (s *MediaService) TranscodeVideo(ctx context.Context, payload []byte) error {
	id, err := parseMediaPayload(JobTranscodeVideo, payload)
	if err != nil {
		return err
	}
	dir := derivedDir(s.d.DataDir, id)
	a, ok, err := s.load(ctx, id)
	if err != nil {
		return err
	}
	if !ok {
		return s.removeDerived(dir)
	}
	if a.Kind != assetKindVideo || a.Playable == nil || *a.Playable {
		return nil
	}
	if err := s.d.FS.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("transcode_video: %w", err)
	}
	src := libraryAbs(s.d.LibraryDir, a.OriginalPath)
	if err := media.Transcode(ctx, s.d.Tools, src, filepath.Join(dir, derivedWebVideo)); err != nil {
		return fmt.Errorf("transcode_video: %w", err)
	}
	return s.commitDerived(ctx, id, dir, func(tx *sql.Tx, cur repository.Asset) error {
		_, err := appendAssetUpsert(ctx, tx, s.d.ChangeLog, s.d.Assets, cur.OwnerID, id, s.d.Clock.Now())
		return err
	})
}

// commitDerived runs record in a transaction once the asset is re-checked.
// If the asset was purged after the derived files were written, it deletes
// dir instead and succeeds.
func (s *MediaService) commitDerived(ctx context.Context, id, dir string, record func(*sql.Tx, repository.Asset) error) error {
	if err := hitFailpoint(s.d.Failpoints, FPMediaAfterWrite); err != nil {
		return err
	}
	gone := false
	err := s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		gone = false
		cur, err := s.d.Assets.GetByID(ctx, tx, id)
		if errors.Is(err, repository.ErrNotFound) {
			gone = true
			return nil
		}
		if err != nil {
			return err
		}
		return record(tx, cur)
	})
	if err != nil {
		return err
	}
	if gone {
		return s.removeDerived(dir)
	}
	return nil
}

// removeDerived deletes an asset's derived directory; a failure is returned
// so the job retries (purge's delete_file job also covers it).
func (s *MediaService) removeDerived(dir string) error {
	if err := s.d.FS.RemoveAll(dir); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("media: remove derived: %w", err)
	}
	return nil
}
