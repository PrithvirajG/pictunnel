package service

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"path/filepath"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

// Thumbnail sizes (OpenAPI getAssetThumbnail) and derived file names (2B).
const (
	ThumbSize        = "thumb"
	PreviewSize      = "preview"
	derivedDirName   = "derived"
	derivedThumb     = "thumb.jpg"
	derivedPreview   = "preview.jpg"
	derivedWebVideo  = "web.mp4"
	webVideoMime     = "video/mp4"
	assetKindVideo   = "video"
	assetKindLive    = "live_photo"
	minDerivedIDSize = 4
)

// libraryAbs resolves a library-relative, slash-separated path.
func libraryAbs(libraryDir, rel string) string {
	return filepath.Join(libraryDir, filepath.FromSlash(rel))
}

// derivedDir is <data>/derived/<id[0:2]>/<id[2:4]>/<asset_id> (2B).
func derivedDir(dataDir, assetID string) string {
	return filepath.Join(dataDir, derivedDirName, assetID[0:2], assetID[2:4], assetID)
}

// AssetServiceDeps are the AssetService dependencies.
type AssetServiceDeps struct {
	Store      *store.Store
	Assets     repository.AssetsRepository
	LiveVideos repository.LiveVideosRepository
	FS         storage.FS
	// LibraryDir is the root original_path is relative to; DataDir holds
	// the derived files.
	LibraryDir string
	DataDir    string
}

// AssetService reads assets and opens their files, owner-scoped (S§7).
type AssetService struct{ d AssetServiceDeps }

// NewAssetService returns an AssetService.
func NewAssetService(d AssetServiceDeps) *AssetService { return &AssetService{d: d} }

func (s *AssetService) load(ctx context.Context, p Principal, id string) (repository.Asset, error) {
	a, err := s.d.Assets.Get(ctx, s.d.Store.R, p.UserID, id)
	if errors.Is(err, repository.ErrNotFound) {
		return repository.Asset{}, apperr.NotFound()
	}
	if err != nil {
		return repository.Asset{}, fmt.Errorf("asset: get: %w", err)
	}
	return a, nil
}

func (s *AssetService) live(ctx context.Context, assetID string) (*repository.LiveVideo, error) {
	lv, err := s.d.LiveVideos.GetByAsset(ctx, s.d.Store.R, assetID)
	if errors.Is(err, repository.ErrNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("asset: live video: %w", err)
	}
	return &lv, nil
}

// open opens a file; a missing file is mapped to missing (not_found or
// not_ready), anything else is an internal error.
func (s *AssetService) open(p string, missing func() *apperr.Error) (storage.File, error) {
	f, err := s.d.FS.Open(p)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, missing()
	}
	if err != nil {
		return nil, fmt.Errorf("asset: open: %w", err)
	}
	return f, nil
}

// Get returns the caller's asset (active or trashed); another user's asset is
// not_found.
func (s *AssetService) Get(ctx context.Context, p Principal, id string) (AssetView, error) {
	a, err := s.load(ctx, p, id)
	if err != nil {
		return AssetView{}, err
	}
	lv, err := s.live(ctx, a.ID)
	if err != nil {
		return AssetView{}, err
	}
	return AssetView{Asset: a, Live: lv}, nil
}

// OpenOriginal opens the caller's original file. The caller closes f.
func (s *AssetService) OpenOriginal(ctx context.Context, p Principal, id string) (storage.File, repository.Asset, error) {
	a, err := s.load(ctx, p, id)
	if err != nil {
		return nil, repository.Asset{}, err
	}
	f, err := s.open(libraryAbs(s.d.LibraryDir, a.OriginalPath), apperr.NotFound)
	if err != nil {
		return nil, repository.Asset{}, err
	}
	return f, a, nil
}

// OpenThumbnail opens the derived JPEG for size ("thumb", the default, or
// "preview"). It is not_ready until generate_thumbnails has run and the
// file exists (2B).
func (s *AssetService) OpenThumbnail(ctx context.Context, p Principal, id, size string) (storage.File, repository.Asset, error) {
	var name string
	switch size {
	case "", ThumbSize:
		name = derivedThumb
	case PreviewSize:
		name = derivedPreview
	default:
		return nil, repository.Asset{}, apperr.InvalidRequest("size must be thumb or preview")
	}
	a, err := s.load(ctx, p, id)
	if err != nil {
		return nil, repository.Asset{}, err
	}
	if !a.ThumbnailsReady || len(a.ID) < minDerivedIDSize {
		return nil, repository.Asset{}, apperr.NotReady()
	}
	f, err := s.open(filepath.Join(derivedDir(s.d.DataDir, a.ID), name), apperr.NotReady)
	if err != nil {
		return nil, repository.Asset{}, err
	}
	return f, a, nil
}

// OpenPlayback opens a browser-playable video for the asset and returns its
// MIME type (2B): a Live Photo plays its video component; a video plays its
// original when playable, else derived web.mp4, else not_ready (also while
// playability is unknown); a photo is not_found.
func (s *AssetService) OpenPlayback(ctx context.Context, p Principal, id string) (storage.File, string, error) {
	a, err := s.load(ctx, p, id)
	if err != nil {
		return nil, "", err
	}
	switch a.Kind {
	case assetKindLive:
		lv, err := s.live(ctx, a.ID)
		if err != nil {
			return nil, "", err
		}
		if lv == nil {
			return nil, "", apperr.NotFound()
		}
		f, err := s.open(libraryAbs(s.d.LibraryDir, lv.OriginalPath), apperr.NotFound)
		if err != nil {
			return nil, "", err
		}
		return f, lv.Mime, nil
	case assetKindVideo:
		if a.Playable != nil && *a.Playable {
			f, err := s.open(libraryAbs(s.d.LibraryDir, a.OriginalPath), apperr.NotFound)
			if err != nil {
				return nil, "", err
			}
			return f, a.Mime, nil
		}
		if len(a.ID) < minDerivedIDSize {
			return nil, "", apperr.NotReady()
		}
		f, err := s.open(filepath.Join(derivedDir(s.d.DataDir, a.ID), derivedWebVideo), apperr.NotReady)
		if err != nil {
			return nil, "", err
		}
		return f, webVideoMime, nil
	default:
		return nil, "", apperr.NotFound()
	}
}
