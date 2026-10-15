package service

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/clock"
	"github.com/PrithvirajG/pictunnel/server/internal/jobs"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

// JobDeleteFile removes one library file or derived directory left behind by
// a purge, once nothing references it (registered in Task 15 with
// TrashService.DeleteFile as handler).
const JobDeleteFile = "delete_file"

// Bulk failure codes (OpenAPI BulkFailure.code).
const (
	bulkNotFound   = "not_found"
	bulkNotTrashed = "not_trashed"
)

const (
	assetStateActive      = "active"
	assetStateTrashed     = "trashed"
	defaultRetentionDays  = 30
	purgeBatch            = 200
	defaultDeleteDedupeNS = "derived:"
)

var uuidRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// BulkResult is the per-id outcome of trash, restore and purge.
type BulkResult struct {
	Succeeded []string
	Failed    []BulkFailure
}

// BulkFailure is one id that could not be processed.
type BulkFailure struct{ AssetID, Code string }

// TrashServiceDeps are the TrashService dependencies.
type TrashServiceDeps struct {
	Store        *store.Store
	Assets       repository.AssetsRepository
	LiveVideos   repository.LiveVideosRepository
	Tombstones   repository.TombstonesRepository
	ChangeLog    repository.ChangeLogRepository
	LibraryPaths repository.LibraryPathsRepository
	Jobs         JobEnqueuer
	FS           storage.FS
	Clock        clock.Clock
	// LibraryDir is the root original_path is relative to; DataDir holds
	// the derived files.
	LibraryDir string
	DataDir    string
	// RetentionDays is trash.retention_days (<= 0 selects 30).
	RetentionDays int
	Log           *slog.Logger
}

// TrashService implements trash, restore, purge, empty and tombstones
// (S§7, P§7.7) plus the purge_trash and delete_file job bodies.
type TrashService struct {
	d   TrashServiceDeps
	log *slog.Logger
}

// NewTrashService returns a TrashService.
func NewTrashService(d TrashServiceDeps) *TrashService {
	log := d.Log
	if log == nil {
		log = slog.Default()
	}
	if d.RetentionDays <= 0 {
		d.RetentionDays = defaultRetentionDays
	}
	return &TrashService{d: d, log: log}
}

// fileDeletion is the delete_file job payload: exactly one field is set.
type fileDeletion struct {
	// Path is library-relative with '/' separators.
	Path string `json:"path,omitempty"`
	// DerivedAssetID names <data>/derived/../<asset_id>.
	DerivedAssetID string `json:"derived_asset_id,omitempty"`
}

func (f fileDeletion) dedupeKey() string {
	if f.Path != "" {
		return f.Path
	}
	return defaultDeleteDedupeNS + f.DerivedAssetID
}

func cleanIDs(ids []string) ([]string, error) {
	if len(ids) == 0 || len(ids) > maxBulkIDs {
		return nil, apperr.InvalidRequest("asset_ids must hold 1 to 1000 entries")
	}
	seen := make(map[string]bool, len(ids))
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out, nil
}

// bulk runs fn for each of the caller's assets in one writer transaction.
// fn returns a failure code, or "" on success. Unknown and foreign ids fail
// with not_found.
func (s *TrashService) bulk(ctx context.Context, p Principal, ids []string,
	fn func(tx *sql.Tx, a repository.Asset, now time.Time) (string, error)) (BulkResult, error) {
	ids, err := cleanIDs(ids)
	if err != nil {
		return BulkResult{}, err
	}
	var res BulkResult
	err = s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		res = BulkResult{Succeeded: []string{}, Failed: []BulkFailure{}}
		now := s.d.Clock.Now()
		for _, id := range ids {
			a, err := s.d.Assets.Get(ctx, tx, p.UserID, id)
			if errors.Is(err, repository.ErrNotFound) {
				res.Failed = append(res.Failed, BulkFailure{AssetID: id, Code: bulkNotFound})
				continue
			}
			if err != nil {
				return err
			}
			code, err := fn(tx, a, now)
			if err != nil {
				return err
			}
			if code != "" {
				res.Failed = append(res.Failed, BulkFailure{AssetID: id, Code: code})
				continue
			}
			res.Succeeded = append(res.Succeeded, id)
		}
		return nil
	})
	if err != nil {
		return BulkResult{}, fmt.Errorf("trash: %w", err)
	}
	return res, nil
}

// setState moves the asset to state and appends asset.upsert.
func (s *TrashService) setState(ctx context.Context, tx *sql.Tx, a repository.Asset, state string, trashedAt *time.Time, now time.Time) error {
	seq, err := appendAssetChange(ctx, tx, s.d.ChangeLog, a.OwnerID, changeAssetUpsert, a.ID, now)
	if err != nil {
		return err
	}
	return s.d.Assets.SetState(ctx, tx, a.ID, state, trashedAt, seq)
}

// Trash moves the caller's assets to the trash. Already trashed assets
// succeed unchanged.
func (s *TrashService) Trash(ctx context.Context, p Principal, ids []string) (BulkResult, error) {
	return s.bulk(ctx, p, ids, func(tx *sql.Tx, a repository.Asset, now time.Time) (string, error) {
		if a.State == assetStateTrashed {
			return "", nil
		}
		return "", s.setState(ctx, tx, a, assetStateTrashed, &now, now)
	})
}

// Restore returns the caller's trashed assets to active. Active assets
// succeed unchanged.
func (s *TrashService) Restore(ctx context.Context, p Principal, ids []string) (BulkResult, error) {
	return s.bulk(ctx, p, ids, func(tx *sql.Tx, a repository.Asset, now time.Time) (string, error) {
		if a.State != assetStateTrashed {
			return "", nil
		}
		return "", s.setState(ctx, tx, a, assetStateActive, nil, now)
	})
}

// Purge permanently deletes the caller's trashed assets; others fail with
// not_trashed. Files are deleted after commit; delete_file jobs retry.
func (s *TrashService) Purge(ctx context.Context, p Principal, ids []string) (BulkResult, error) {
	var dels []fileDeletion
	res, err := s.bulk(ctx, p, ids, func(tx *sql.Tx, a repository.Asset, now time.Time) (string, error) {
		if a.State != assetStateTrashed {
			return bulkNotTrashed, nil
		}
		d, err := s.purgeTx(ctx, tx, a, now)
		dels = append(dels, d...)
		return "", err
	})
	if err != nil {
		return BulkResult{}, err
	}
	s.deleteNow(ctx, dels)
	return res, nil
}

// Empty purges every trashed asset of the caller and returns the count.
func (s *TrashService) Empty(ctx context.Context, p Principal) (int, error) {
	trashed, err := s.d.Assets.ListTrashed(ctx, s.d.Store.R, p.UserID)
	if err != nil {
		return 0, fmt.Errorf("trash: empty: %w", err)
	}
	n := 0
	for start := 0; start < len(trashed); start += purgeBatch {
		end := min(start+purgeBatch, len(trashed))
		ids := make([]string, 0, end-start)
		for _, a := range trashed[start:end] {
			ids = append(ids, a.ID)
		}
		res, err := s.Purge(ctx, p, ids)
		if err != nil {
			return n, err
		}
		n += len(res.Succeeded)
	}
	return n, nil
}

// purgeTx deletes the asset row (cascading to live_videos and
// asset_sources), records the tombstone, appends asset.removed, releases the
// path reservations and enqueues delete_file jobs for the files.
func (s *TrashService) purgeTx(ctx context.Context, tx *sql.Tx, a repository.Asset, now time.Time) ([]fileDeletion, error) {
	dels := []fileDeletion{{Path: a.OriginalPath}}
	lv, err := s.d.LiveVideos.GetByAsset(ctx, tx, a.ID)
	switch {
	case err == nil:
		dels = append(dels, fileDeletion{Path: lv.OriginalPath})
	case !errors.Is(err, repository.ErrNotFound):
		return nil, err
	}
	dels = append(dels, fileDeletion{DerivedAssetID: a.ID})
	if err := s.d.Assets.Delete(ctx, tx, a.ID); err != nil {
		return nil, err
	}
	if err := s.d.Tombstones.Insert(ctx, tx, repository.Tombstone{
		OwnerID: a.OwnerID, SHA256: a.SHA256, Filename: a.Filename, DeletedAt: now,
	}); err != nil {
		return nil, err
	}
	if _, err := appendAssetChange(ctx, tx, s.d.ChangeLog, a.OwnerID, changeAssetRemoved, a.ID, now); err != nil {
		return nil, err
	}
	if err := s.d.LibraryPaths.ReleaseByAsset(ctx, tx, a.ID); err != nil {
		return nil, err
	}
	for _, d := range dels {
		payload, err := json.Marshal(d)
		if err != nil {
			return nil, err
		}
		if err := s.d.Jobs.Enqueue(ctx, tx, JobDeleteFile, d.dedupeKey(), payload, time.Time{}); err != nil {
			return nil, err
		}
	}
	return dels, nil
}

// deleteNow attempts the committed deletions right away. Failures are
// logged; the delete_file jobs retry them.
func (s *TrashService) deleteNow(ctx context.Context, dels []fileDeletion) {
	for _, d := range dels {
		if err := s.deleteOne(ctx, d); err != nil {
			s.log.Warn("purge: file delete failed; delete_file job will retry", "path", d.Path,
				"derived_asset_id", d.DerivedAssetID, "err", err)
		}
	}
}

// PurgeExpired is the purge_trash job body: it purges every asset trashed
// more than RetentionDays ago, for all users. Failed file deletes of earlier
// purges are retried by their delete_file jobs, so the library is never
// walked.
func (s *TrashService) PurgeExpired(ctx context.Context) error {
	cutoff := s.d.Clock.Now().Add(-time.Duration(s.d.RetentionDays) * 24 * time.Hour)
	for {
		batch, err := s.d.Assets.ListTrashedBefore(ctx, s.d.Store.R, "", cutoff, purgeBatch)
		if err != nil {
			return fmt.Errorf("purge_trash: list: %w", err)
		}
		if len(batch) == 0 {
			return nil
		}
		var dels []fileDeletion
		err = s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
			now := s.d.Clock.Now()
			for _, stale := range batch {
				// Re-read inside the transaction: it may have been restored
				// or purged since the list.
				a, err := s.d.Assets.GetByID(ctx, tx, stale.ID)
				if errors.Is(err, repository.ErrNotFound) {
					continue
				}
				if err != nil {
					return err
				}
				if a.State != assetStateTrashed || a.TrashedAt == nil || !a.TrashedAt.Before(cutoff) {
					continue
				}
				d, err := s.purgeTx(ctx, tx, a, now)
				if err != nil {
					return err
				}
				dels = append(dels, d...)
			}
			return nil
		})
		if err != nil {
			return fmt.Errorf("purge_trash: %w", err)
		}
		s.deleteNow(ctx, dels)
		if len(batch) < purgeBatch {
			return nil
		}
	}
}

// DeleteFile is the delete_file job body. It removes a library file only if
// no library_paths reservation, asset or live video references the path, and
// a derived directory only if its asset no longer exists. Malformed or
// unsafe payloads fail permanently.
func (s *TrashService) DeleteFile(ctx context.Context, payload []byte) error {
	var d fileDeletion
	dec := json.NewDecoder(bytes.NewReader(payload))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&d); err != nil {
		return &jobs.Permanent{Err: fmt.Errorf("delete_file: bad payload: %w", err)}
	}
	if (d.Path == "") == (d.DerivedAssetID == "") {
		return &jobs.Permanent{Err: errors.New("delete_file: payload needs exactly one of path, derived_asset_id")}
	}
	if d.Path != "" && !safeLibraryRel(d.Path) {
		return &jobs.Permanent{Err: fmt.Errorf("delete_file: unsafe path %q", d.Path)}
	}
	if d.DerivedAssetID != "" && !uuidRe.MatchString(d.DerivedAssetID) {
		return &jobs.Permanent{Err: fmt.Errorf("delete_file: bad asset id %q", d.DerivedAssetID)}
	}
	return s.deleteOne(ctx, d)
}

// safeLibraryRel accepts a clean, relative, slash-separated path inside the
// library and outside its temp dir (owned by finalize).
func safeLibraryRel(rel string) bool {
	if rel == "" || strings.ContainsAny(rel, "\\:\x00") || strings.HasPrefix(rel, "/") || path.Clean(rel) != rel {
		return false
	}
	for _, seg := range strings.Split(rel, "/") {
		if seg == ".." || seg == "." {
			return false
		}
	}
	first, _, _ := strings.Cut(rel, "/")
	return !strings.EqualFold(first, libraryTmpDirName) && !filepath.IsAbs(rel)
}

func (s *TrashService) deleteOne(ctx context.Context, d fileDeletion) error {
	if d.DerivedAssetID != "" {
		_, err := s.d.Assets.GetByID(ctx, s.d.Store.R, d.DerivedAssetID)
		if err == nil {
			return nil // the asset exists again; its derived files are live
		}
		if !errors.Is(err, repository.ErrNotFound) {
			return err
		}
		return s.d.FS.RemoveAll(derivedDir(s.d.DataDir, d.DerivedAssetID))
	}
	referenced, err := s.referenced(ctx, d.Path)
	if err != nil || referenced {
		return err
	}
	if err := s.d.FS.Remove(libraryAbs(s.d.LibraryDir, d.Path)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

// referenced reports whether a reservation (by case-folded NFC key), an
// asset or a live video still points at the library path. While the file
// exists, Assign never hands its name to a new upload, so a path found
// unreferenced here cannot become referenced before the remove.
func (s *TrashService) referenced(ctx context.Context, rel string) (bool, error) {
	db := s.d.Store.R
	if ok, err := s.d.LibraryPaths.Exists(ctx, db, storage.PathKey(rel)); err != nil || ok {
		return ok, err
	}
	if ok, err := s.d.Assets.PathReferenced(ctx, db, rel); err != nil || ok {
		return ok, err
	}
	return s.d.LiveVideos.PathReferenced(ctx, db, rel)
}

// ListTombstones pages the caller's tombstones newest first (deleted_at
// desc, sha256 asc). cursor is the opaque next value of the previous page.
func (s *TrashService) ListTombstones(ctx context.Context, p Principal, cursor string, limit int) ([]repository.Tombstone, string, bool, error) {
	limit, err := pageLimit(limit, defaultTombstoneLimit)
	if err != nil {
		return nil, "", false, err
	}
	var after time.Time
	afterSHA := ""
	if cursor != "" {
		parts, ok := decodeToken(cursor, 2)
		if ok {
			after, err = time.Parse(time.RFC3339Nano, parts[0])
			ok = err == nil && sha256Re.MatchString(parts[1])
		}
		if !ok {
			return nil, "", false, apperr.InvalidRequest("cursor is malformed")
		}
		afterSHA = parts[1]
	}
	rows, err := s.d.Tombstones.Page(ctx, s.d.Store.R, p.UserID, after, afterSHA, limit+1)
	if err != nil {
		return nil, "", false, fmt.Errorf("tombstones: %w", err)
	}
	if len(rows) <= limit {
		return rows, "", false, nil
	}
	rows = rows[:limit]
	last := rows[limit-1]
	return rows, encodeToken(last.DeletedAt.UTC().Format(time.RFC3339Nano), last.SHA256), true, nil
}

// DeleteTombstone removes the caller's tombstone; absent is not an error.
func (s *TrashService) DeleteTombstone(ctx context.Context, p Principal, sha string) error {
	if !sha256Re.MatchString(sha) {
		return apperr.InvalidRequest("sha256 must be 64 lowercase hex digits")
	}
	err := s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		_, err := s.d.Tombstones.Delete(ctx, tx, p.UserID, sha)
		return err
	})
	if err != nil {
		return fmt.Errorf("tombstones: delete: %w", err)
	}
	return nil
}
