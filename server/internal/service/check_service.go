package service

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/clock"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

// Check verdicts (P§7.2).
const (
	VerdictExists     = "exists"
	VerdictPartial    = "partial"
	VerdictTombstoned = "tombstoned"
	VerdictMissing    = "missing"
)

const maxCheckItems = 1000

// CheckItem is one entry of a sync/check request.
type CheckItem struct {
	SHA256        string
	SizeBytes     int64
	LocalID       string
	ConfirmOnDisk bool
}

// CheckOutcome answers one CheckItem. Asset and HasLiveVideo are set for
// exists, OnDisk only when ConfirmOnDisk was asked on an exists verdict,
// Upload for partial and DeletedAt for tombstoned.
type CheckOutcome struct {
	SHA256, Verdict string
	Asset           *repository.Asset
	HasLiveVideo    bool
	OnDisk          *bool
	Upload          *UploadView
	DeletedAt       *time.Time
}

// CheckServiceDeps are the CheckService dependencies.
type CheckServiceDeps struct {
	Store          *store.Store
	Assets         repository.AssetsRepository
	LiveVideos     repository.LiveVideosRepository
	UploadSessions repository.UploadSessionsRepository
	Tombstones     repository.TombstonesRepository
	AssetSources   repository.AssetSourcesRepository
	FS             storage.FS
	Clock          clock.Clock
	// LibraryDir is the root original_path is relative to.
	LibraryDir string
}

// CheckService implements sync/check (S§7, P§7.2).
type CheckService struct{ d CheckServiceDeps }

// NewCheckService returns a CheckService.
func NewCheckService(d CheckServiceDeps) *CheckService { return &CheckService{d: d} }

// Check answers items in input order (duplicates answered each time) for
// the caller only. Precedence: exists → partial → tombstoned → missing. An
// exists verdict with a local_id links (device, local_id) to the asset.
func (s *CheckService) Check(ctx context.Context, p Principal, items []CheckItem) ([]CheckOutcome, error) {
	if len(items) == 0 || len(items) > maxCheckItems {
		return nil, apperr.InvalidRequest("items must hold 1 to 1000 entries")
	}
	shas := make([]string, 0, len(items))
	seen := map[string]bool{}
	for i, it := range items {
		if !sha256Re.MatchString(it.SHA256) {
			return nil, apperr.InvalidRequest(fmt.Sprintf("items[%d].sha256 must be 64 lowercase hex digits", i))
		}
		if it.SizeBytes < 0 {
			return nil, apperr.InvalidRequest(fmt.Sprintf("items[%d].size_bytes must not be negative", i))
		}
		if !seen[it.SHA256] {
			seen[it.SHA256] = true
			shas = append(shas, it.SHA256)
		}
	}

	assets := map[string]repository.Asset{}
	lives := map[string]repository.LiveVideo{}
	sessions := map[string]repository.UploadSession{}
	tombs := map[string]repository.Tombstone{}
	err := readTx(ctx, s.d.Store, func(tx *sql.Tx) error {
		al, err := s.d.Assets.ListBySHAs(ctx, tx, p.UserID, shas)
		if err != nil {
			return err
		}
		ids := make([]string, 0, len(al))
		for _, a := range al {
			assets[a.SHA256] = a
			ids = append(ids, a.ID)
		}
		if len(ids) > 0 {
			lv, err := s.d.LiveVideos.ListByAssets(ctx, tx, ids)
			if err != nil {
				return err
			}
			for _, v := range lv {
				lives[v.AssetID] = v
			}
		}
		sl, err := s.d.UploadSessions.ListActiveBySHAs(ctx, tx, p.UserID, shas)
		if err != nil {
			return err
		}
		now := s.d.Clock.Now()
		for _, u := range sl {
			// An expired receiving session (strictly past expires_at, S§6.4)
			// awaiting the sweep is already gone for HEAD and create, so it
			// is not offered for resumption.
			if u.State == sessionReceiving && now.After(u.ExpiresAt) {
				continue
			}
			sessions[u.SHA256] = u
		}
		tl, err := s.d.Tombstones.ListBySHAs(ctx, tx, p.UserID, shas)
		if err != nil {
			return err
		}
		for _, t := range tl {
			tombs[t.SHA256] = t
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("check: %w", err)
	}

	type link struct{ localID, assetID string }
	var links []link
	out := make([]CheckOutcome, len(items))
	for i, it := range items {
		o := CheckOutcome{SHA256: it.SHA256, Verdict: VerdictMissing}
		if a, ok := assets[it.SHA256]; ok {
			a := a
			lv, hasLive := lives[a.ID]
			o.Verdict, o.Asset, o.HasLiveVideo = VerdictExists, &a, hasLive
			if it.ConfirmOnDisk {
				on := s.onDisk(a.OriginalPath, a.SizeBytes) && (!hasLive || s.onDisk(lv.OriginalPath, lv.SizeBytes))
				o.OnDisk = &on
			}
			if it.LocalID != "" && p.DeviceID != "" {
				links = append(links, link{it.LocalID, a.ID})
			}
		} else if u, ok := sessions[it.SHA256]; ok {
			v := viewOf(u)
			o.Verdict, o.Upload = VerdictPartial, &v
		} else if t, ok := tombs[it.SHA256]; ok {
			d := t.DeletedAt
			o.Verdict, o.DeletedAt = VerdictTombstoned, &d
		}
		out[i] = o
	}

	if len(links) > 0 {
		now := s.d.Clock.Now()
		err := s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
			live := map[string]bool{}
			for _, l := range links {
				// The asset may have been purged since the read; skip it
				// rather than trip the foreign key.
				ok, checked := live[l.assetID]
				if !checked {
					_, err := s.d.Assets.Get(ctx, tx, p.UserID, l.assetID)
					if err != nil && !errors.Is(err, repository.ErrNotFound) {
						return err
					}
					ok = err == nil
					live[l.assetID] = ok
				}
				if !ok {
					continue
				}
				if err := s.d.AssetSources.Upsert(ctx, tx, p.DeviceID, l.localID, l.assetID, now); err != nil {
					return err
				}
			}
			return nil
		})
		if err != nil {
			return nil, fmt.Errorf("check: link sources: %w", err)
		}
	}
	return out, nil
}

// onDisk stats the library file and compares its size.
func (s *CheckService) onDisk(rel string, size int64) bool {
	fi, err := s.d.FS.Stat(libraryAbs(s.d.LibraryDir, rel))
	return err == nil && fi.Mode().IsRegular() && fi.Size() == size
}
