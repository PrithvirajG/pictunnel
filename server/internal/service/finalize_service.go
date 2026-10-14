package service

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/clock"
	"github.com/PrithvirajG/pictunnel/server/internal/contenthash"
	"github.com/PrithvirajG/pictunnel/server/internal/ids"
	"github.com/PrithvirajG/pictunnel/server/internal/media/probe"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// Job kinds enqueued by finalize.
const (
	JobExtractMetadata    = "extract_metadata"
	JobGenerateThumbnails = "generate_thumbnails"
)

// Upload session states and roles.
const (
	sessionReceiving  = "receiving"
	sessionFinalizing = "finalizing"
	sessionDone       = "done"
	sessionFailed     = "failed"
	pairRoleLiveVideo = "live_video"
	changeAssetUpsert = "asset.upsert"
	stagingDirName    = "uploads"
)

// JobEnqueuer enqueues a durable job inside a transaction (jobs.Runner).
type JobEnqueuer interface {
	Enqueue(ctx context.Context, db queries.DBTX, kind, dedupeKey string, payload []byte, runAfter time.Time) error
}

// FinalizeServiceDeps are the FinalizeService dependencies. Users is read
// for the owner's slug (library path). Failpoints is nil in production.
type FinalizeServiceDeps struct {
	Store          *store.Store
	Users          repository.UsersRepository
	Assets         repository.AssetsRepository
	LiveVideos     repository.LiveVideosRepository
	LibraryPaths   repository.LibraryPathsRepository
	AssetSources   repository.AssetSourcesRepository
	UploadSessions repository.UploadSessionsRepository
	Tombstones     repository.TombstonesRepository
	ChangeLog      repository.ChangeLogRepository
	Jobs           JobEnqueuer
	Library        *LibraryService
	FS             storage.FS
	Clock          clock.Clock
	Probe          DateProbe
	Failpoints     Failpoints
	// DataDir holds the staging dir (<data>/uploads); relative staging paths
	// resolve against it.
	DataDir string
	// LibraryDir is the root that dest_path and original_path are relative to.
	LibraryDir string
	Log        *slog.Logger
}

// FinalizeService runs the finalize journal (S§6.2, P§7.4) and its recovery.
type FinalizeService struct {
	d   FinalizeServiceDeps
	fp  Failpoints
	log *slog.Logger

	mu       sync.Mutex
	inflight map[string]struct{} // session ids being finalized or recovered
}

// NewFinalizeService returns a FinalizeService.
func NewFinalizeService(d FinalizeServiceDeps) *FinalizeService {
	log := d.Log
	if log == nil {
		log = slog.Default()
	}
	return &FinalizeService{d: d, fp: d.Failpoints, log: log, inflight: map[string]struct{}{}}
}

// FinalizeResult is the asset an upload resolved to. For a live video
// AssetID is the primary still; Created is false when the content (or the
// attached component) already existed.
type FinalizeResult struct {
	AssetID string
	Created bool
}

// sessionMeta is the JSON in upload_sessions.meta_json: the parsed tus
// Upload-Metadata (P§7.3), keyed by the protocol's key names.
type sessionMeta struct {
	SHA256            string     `json:"sha256"`
	Filename          string     `json:"filename"`
	Mime              string     `json:"mime"`
	LocalID           string     `json:"local_id,omitempty"`
	CreatedAt         *time.Time `json:"created_at,omitempty"`
	ModifiedAt        *time.Time `json:"modified_at,omitempty"`
	PairRole          string     `json:"pair_role,omitempty"`
	PairSHA256        string     `json:"pair_sha256,omitempty"`
	StackKey          string     `json:"stack_key,omitempty"`
	OverrideTombstone bool       `json:"override_tombstone,omitempty"`
}

func parseSessionMeta(sess repository.UploadSession) (sessionMeta, error) {
	var m sessionMeta
	if strings.TrimSpace(sess.MetaJSON) != "" {
		if err := json.Unmarshal([]byte(sess.MetaJSON), &m); err != nil {
			return m, fmt.Errorf("finalize: session %s meta_json: %w", sess.ID, err)
		}
	}
	// The session columns are authoritative for pairing.
	if sess.PairRole != nil {
		m.PairRole = *sess.PairRole
	}
	if sess.PairSHA256 != nil {
		m.PairSHA256 = *sess.PairSHA256
	}
	return m, nil
}

func (m sessionMeta) live() bool { return m.PairRole == pairRoleLiveVideo }

// dateInfo is the asset's taken_at triple plus the date that picks the
// library directory.
type dateInfo struct {
	takenAt  *time.Time
	offset   *int64
	source   string
	pathDate time.Time
}

// resolveDate applies the 2B order: probe → client created_at (client) →
// client modified_at (file) → none (unknown; the path uses receive time).
func resolveDate(m sessionMeta, pr probe.DateResult, ok bool, now time.Time) dateInfo {
	switch {
	case ok:
		t := pr.Time.UTC()
		di := dateInfo{takenAt: &t, source: pr.Source, pathDate: t}
		if pr.OffsetMinutes != nil {
			o := int64(*pr.OffsetMinutes)
			di.offset = &o
			di.pathDate = t.In(time.FixedZone("", *pr.OffsetMinutes*60))
		}
		return di
	case m.CreatedAt != nil && !m.CreatedAt.IsZero():
		t := *m.CreatedAt
		return dateInfo{takenAt: &t, source: "client", pathDate: t}
	case m.ModifiedAt != nil && !m.ModifiedAt.IsZero():
		t := *m.ModifiedAt
		return dateInfo{takenAt: &t, source: "file", pathDate: t}
	}
	return dateInfo{source: "unknown", pathDate: now}
}

func assetKind(mime string) string {
	m := strings.ToLower(mime)
	if strings.HasPrefix(m, "video/") {
		return "video"
	}
	return "photo"
}

func (s *FinalizeService) begin(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, busy := s.inflight[id]; busy {
		return false
	}
	s.inflight[id] = struct{}{}
	return true
}

func (s *FinalizeService) end(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.inflight, id)
}

func (s *FinalizeService) stagingAbs(sess repository.UploadSession) string {
	if filepath.IsAbs(sess.StagingPath) {
		return sess.StagingPath
	}
	return filepath.Join(s.d.DataDir, sess.StagingPath)
}

func (s *FinalizeService) libAbs(rel string) string {
	return filepath.Join(s.d.LibraryDir, filepath.FromSlash(rel))
}

// internalErr is a 500 internal that keeps the cause for logs.
func internalErr(op string, err error) error {
	return fmt.Errorf("finalize: %s: %w (%w)", op, apperr.Internal(), err)
}

// removeQuiet deletes a file, ignoring "does not exist" and logging others.
func (s *FinalizeService) removeQuiet(p string) {
	if p == "" {
		return
	}
	if err := s.d.FS.Remove(p); err != nil && !errors.Is(err, fs.ErrNotExist) {
		s.log.Warn("finalize: remove failed", "path", p, "err", err)
	}
}

// Finalize runs S§6.2 steps 1–5 for a fully received session whose content
// hashed to digest.
func (s *FinalizeService) Finalize(ctx context.Context, sess repository.UploadSession, digest string) (FinalizeResult, error) {
	if !s.begin(sess.ID) {
		return FinalizeResult{}, apperr.UploadLocked()
	}
	defer s.end(sess.ID)
	meta, err := parseSessionMeta(sess)
	if err != nil {
		return FinalizeResult{}, err
	}
	staging := s.stagingAbs(sess)

	// Step 1: digest.
	if !strings.EqualFold(digest, sess.SHA256) {
		if err := s.fail(ctx, sess.ID, "checksum_mismatch", false); err != nil {
			return FinalizeResult{}, err
		}
		s.removeQuiet(staging)
		return FinalizeResult{}, apperr.ChecksumMismatch()
	}
	if err := hitFailpoint(s.fp, FPBeforeTx1); err != nil {
		return FinalizeResult{}, err
	}

	// Step 2: tx1.
	var date dateInfo
	if !meta.live() {
		date = s.probeDate(staging, meta)
	}
	var (
		rel     string
		settled *FinalizeResult // resolved without a move
		failure error           // domain failure committed in tx1
		recover bool            // found finalizing: hand to recovery
	)
	err = s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		rel, settled, failure, recover = "", nil, nil, false
		cur, err := s.d.UploadSessions.Get(ctx, tx, sess.ID)
		if err != nil {
			return err
		}
		switch cur.State {
		case sessionDone:
			settled = &FinalizeResult{AssetID: deref(cur.AssetID), Created: cur.AssetCreated}
			return nil
		case sessionFinalizing:
			recover = true
			return nil
		case sessionFailed:
			failure = apperr.NotFound()
			return nil
		}
		now := s.d.Clock.Now()
		if meta.live() {
			primary, err := s.d.Assets.GetBySHA(ctx, tx, sess.OwnerID, meta.PairSHA256)
			if errors.Is(err, repository.ErrNotFound) {
				failure = apperr.PairPrimaryMissing()
				return s.d.UploadSessions.SetFailed(ctx, tx, sess.ID, "pair_primary_missing", now)
			}
			if err != nil {
				return err
			}
			if _, err := s.d.LiveVideos.GetByAsset(ctx, tx, primary.ID); err == nil {
				settled = &FinalizeResult{AssetID: primary.ID}
				return s.d.UploadSessions.SetDone(ctx, tx, sess.ID, primary.ID, false, now)
			} else if !errors.Is(err, repository.ErrNotFound) {
				return err
			}
			user, err := s.d.Users.GetByID(ctx, tx, sess.OwnerID)
			if err != nil {
				return err
			}
			rel, err = s.d.Library.Assign(ctx, tx, AssignInput{
				UserID: sess.OwnerID, UserSlug: user.Slug, Filename: meta.Filename,
				UploadID: sess.ID, SiblingOf: primary.OriginalPath,
			})
			if err != nil {
				return err
			}
			return s.d.UploadSessions.SetFinalizing(ctx, tx, sess.ID, rel, now)
		}
		if !meta.OverrideTombstone {
			ts, err := s.d.Tombstones.Get(ctx, tx, sess.OwnerID, sess.SHA256)
			if err == nil {
				failure = apperr.Tombstoned(ts.DeletedAt)
				return s.d.UploadSessions.SetFailed(ctx, tx, sess.ID, "tombstoned", now)
			}
			if !errors.Is(err, repository.ErrNotFound) {
				return err
			}
		}
		existing, err := s.d.Assets.GetBySHA(ctx, tx, sess.OwnerID, sess.SHA256)
		if err == nil {
			settled = &FinalizeResult{AssetID: existing.ID}
			if err := s.linkSource(ctx, tx, sess, meta, existing.ID, now); err != nil {
				return err
			}
			return s.d.UploadSessions.SetDone(ctx, tx, sess.ID, existing.ID, false, now)
		}
		if !errors.Is(err, repository.ErrNotFound) {
			return err
		}
		user, err := s.d.Users.GetByID(ctx, tx, sess.OwnerID)
		if err != nil {
			return err
		}
		rel, err = s.d.Library.Assign(ctx, tx, AssignInput{
			UserID: sess.OwnerID, UserSlug: user.Slug, Filename: meta.Filename,
			Date: date.pathDate, UploadID: sess.ID,
		})
		if err != nil {
			return err
		}
		return s.d.UploadSessions.SetFinalizing(ctx, tx, sess.ID, rel, now)
	})
	if err != nil {
		return FinalizeResult{}, err
	}
	switch {
	case recover:
		cur, err := s.d.UploadSessions.Get(ctx, s.d.Store.R, sess.ID)
		if err != nil {
			return FinalizeResult{}, err
		}
		return s.recoverSession(ctx, cur)
	case failure != nil:
		s.removeQuiet(staging)
		return FinalizeResult{}, failure
	case settled != nil:
		s.removeQuiet(staging)
		return *settled, nil
	}
	if err := hitFailpoint(s.fp, FPAfterTx1); err != nil {
		return FinalizeResult{}, err
	}
	sess.State, sess.DestPath = sessionFinalizing, rel

	// Steps 3–4: move, then tx2.
	hooks := &storage.CommitHooks{
		AfterCopy:   func() error { return hitFailpoint(s.fp, FPAfterCopy) },
		AfterRename: func() error { return hitFailpoint(s.fp, FPAfterRename) },
	}
	return s.moveAndCommit(ctx, sess, meta, date, hooks)
}

func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

// moveAndCommit is steps 3–5 for a finalizing session.
func (s *FinalizeService) moveAndCommit(ctx context.Context, sess repository.UploadSession, meta sessionMeta, date dateInfo, hooks *storage.CommitHooks) (FinalizeResult, error) {
	staging, dest := s.stagingAbs(sess), s.libAbs(sess.DestPath)
	if err := storage.CommitWithHooks(s.d.FS, staging, dest, hooks); err != nil {
		var fpe *failpointError
		if errors.As(err, &fpe) {
			return FinalizeResult{}, err
		}
		// Commit can fail after dest is durable (directory fsync unsupported
		// on some mounts, staging removal failing). Only a missing or short
		// dest is a failed move; it stays finalizing for recovery.
		if !s.sizeMatches(dest, sess.Length) {
			s.log.Error("finalize: move failed; left for recovery", "upload_id", sess.ID, "err", err)
			return FinalizeResult{}, internalErr("move", err)
		}
		s.log.Warn("finalize: move reported an error after dest was written", "upload_id", sess.ID, "err", err)
	}
	res, err := s.commitAsset(ctx, sess, meta, date)
	if err != nil {
		return FinalizeResult{}, err
	}
	if err := hitFailpoint(s.fp, FPAfterTx2); err != nil {
		return FinalizeResult{}, err
	}
	s.removeQuiet(staging)
	return res, nil
}

func (s *FinalizeService) sizeMatches(p string, size int64) bool {
	fi, err := s.d.FS.Stat(p)
	return err == nil && fi.Mode().IsRegular() && fi.Size() == size
}

// fileMatches reports whether p is a regular file of the given size and hash.
func (s *FinalizeService) fileMatches(p string, size int64, sha string) bool {
	if !s.sizeMatches(p, size) {
		return false
	}
	f, err := s.d.FS.Open(p)
	if err != nil {
		return false
	}
	defer f.Close()
	got, err := contenthash.HashReader(f)
	return err == nil && strings.EqualFold(got, sha)
}

// probeDate runs the fast date probe over the head of p and applies the date
// order. Any read problem just yields no probe result.
func (s *FinalizeService) probeDate(p string, meta sessionMeta) dateInfo {
	now := s.d.Clock.Now()
	if s.d.Probe == nil {
		return resolveDate(meta, probe.DateResult{}, false, now)
	}
	f, err := s.d.FS.Open(p)
	if err != nil {
		return resolveDate(meta, probe.DateResult{}, false, now)
	}
	defer f.Close()
	buf := make([]byte, probe.MaxProbeBytes)
	n, err := io.ReadFull(f, buf)
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
		return resolveDate(meta, probe.DateResult{}, false, now)
	}
	pr, ok := s.d.Probe(bytes.NewReader(buf[:n]), int64(n), meta.Mime)
	return resolveDate(meta, pr, ok, now)
}

func (s *FinalizeService) linkSource(ctx context.Context, tx *sql.Tx, sess repository.UploadSession, meta sessionMeta, assetID string, now time.Time) error {
	if meta.LocalID == "" {
		return nil
	}
	return s.d.AssetSources.Upsert(ctx, tx, sess.DeviceID, meta.LocalID, assetID, now)
}

// appendUpsert appends asset.upsert, compacts the asset's earlier entries and
// stamps updated_seq.
func (s *FinalizeService) appendUpsert(ctx context.Context, tx *sql.Tx, ownerID, assetID string, now time.Time) error {
	seq, err := s.d.ChangeLog.Append(ctx, tx, ownerID, changeAssetUpsert, assetID, now)
	if err != nil {
		return err
	}
	if _, err := s.d.ChangeLog.DeleteForAsset(ctx, tx, assetID, seq); err != nil {
		return err
	}
	return s.d.Assets.SetUpdatedSeq(ctx, tx, assetID, seq)
}

func (s *FinalizeService) enqueue(ctx context.Context, tx *sql.Tx, kind, assetID string) error {
	payload, err := json.Marshal(map[string]string{"asset_id": assetID})
	if err != nil {
		return err
	}
	return s.d.Jobs.Enqueue(ctx, tx, kind, assetID, payload, time.Time{})
}

// commitAsset is tx2 (S§6.2 step 4). It is idempotent: a session that is no
// longer finalizing reports its recorded outcome.
func (s *FinalizeService) commitAsset(ctx context.Context, sess repository.UploadSession, meta sessionMeta, date dateInfo) (FinalizeResult, error) {
	var (
		res     FinalizeResult
		failure error
	)
	err := s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		res, failure = FinalizeResult{}, nil
		cur, err := s.d.UploadSessions.Get(ctx, tx, sess.ID)
		if err != nil {
			return err
		}
		switch cur.State {
		case sessionDone:
			res = FinalizeResult{AssetID: deref(cur.AssetID), Created: cur.AssetCreated}
			return nil
		case sessionFinalizing:
		default:
			failure = apperr.NotFound()
			return nil
		}
		now := s.d.Clock.Now()
		if meta.live() {
			res, failure, err = s.commitLive(ctx, tx, sess, meta, now)
			return err
		}
		res, err = s.commitPrimary(ctx, tx, sess, meta, date, now)
		return err
	})
	if err != nil {
		return FinalizeResult{}, err
	}
	return res, failure
}

func (s *FinalizeService) commitPrimary(ctx context.Context, tx *sql.Tx, sess repository.UploadSession, meta sessionMeta, date dateInfo, now time.Time) (FinalizeResult, error) {
	a := repository.Asset{
		ID: ids.New(), OwnerID: sess.OwnerID, SHA256: sess.SHA256, SizeBytes: sess.Length, Mime: meta.Mime,
		Kind: assetKind(meta.Mime), Filename: meta.Filename, OriginalPath: sess.DestPath,
		TakenAt: date.takenAt, TakenAtOffsetMinutes: date.offset, TakenAtSource: date.source,
		State: "active", CreatedAt: now,
	}
	if meta.StackKey != "" {
		k := meta.StackKey
		a.StackKey = &k
		id, ok, err := s.d.Assets.StackIDForKey(ctx, tx, sess.OwnerID, k)
		if err != nil {
			return FinalizeResult{}, err
		}
		if ok {
			a.StackID = &id
		}
	}
	err := s.d.Assets.Insert(ctx, tx, a)
	if errors.Is(err, repository.ErrUniqueViolation) {
		existing, gerr := s.d.Assets.GetBySHA(ctx, tx, sess.OwnerID, sess.SHA256)
		if gerr != nil {
			return FinalizeResult{}, gerr
		}
		if err := s.resolveToExisting(ctx, tx, sess, existing.ID, now); err != nil {
			return FinalizeResult{}, err
		}
		return FinalizeResult{AssetID: existing.ID}, s.linkSource(ctx, tx, sess, meta, existing.ID, now)
	}
	if err != nil {
		return FinalizeResult{}, err
	}
	if err := s.linkSource(ctx, tx, sess, meta, a.ID, now); err != nil {
		return FinalizeResult{}, err
	}
	if err := s.appendUpsert(ctx, tx, sess.OwnerID, a.ID, now); err != nil {
		return FinalizeResult{}, err
	}
	for _, kind := range []string{JobExtractMetadata, JobGenerateThumbnails} {
		if err := s.enqueue(ctx, tx, kind, a.ID); err != nil {
			return FinalizeResult{}, err
		}
	}
	if meta.OverrideTombstone {
		if _, err := s.d.Tombstones.Delete(ctx, tx, sess.OwnerID, sess.SHA256); err != nil {
			return FinalizeResult{}, err
		}
	}
	if err := s.d.LibraryPaths.PointToAsset(ctx, tx, storage.PathKey(sess.DestPath), a.ID); err != nil {
		return FinalizeResult{}, err
	}
	if err := s.d.UploadSessions.SetDone(ctx, tx, sess.ID, a.ID, true, now); err != nil {
		return FinalizeResult{}, err
	}
	return FinalizeResult{AssetID: a.ID, Created: true}, nil
}

// commitLive attaches a live video to its primary (P§5 H4).
func (s *FinalizeService) commitLive(ctx context.Context, tx *sql.Tx, sess repository.UploadSession, meta sessionMeta, now time.Time) (FinalizeResult, error, error) {
	primary, err := s.d.Assets.GetBySHA(ctx, tx, sess.OwnerID, meta.PairSHA256)
	if errors.Is(err, repository.ErrNotFound) {
		// The primary was purged after tx1.
		s.removeQuiet(s.libAbs(sess.DestPath))
		if err := s.d.LibraryPaths.ReleaseByUpload(ctx, tx, sess.ID); err != nil {
			return FinalizeResult{}, nil, err
		}
		return FinalizeResult{}, apperr.PairPrimaryMissing(),
			s.d.UploadSessions.SetFailed(ctx, tx, sess.ID, "pair_primary_missing", now)
	}
	if err != nil {
		return FinalizeResult{}, nil, err
	}
	err = s.d.LiveVideos.Insert(ctx, tx, repository.LiveVideo{
		AssetID: primary.ID, OwnerID: sess.OwnerID, SHA256: sess.SHA256, SizeBytes: sess.Length,
		Mime: meta.Mime, Filename: meta.Filename, OriginalPath: sess.DestPath, CreatedAt: now,
	})
	if errors.Is(err, repository.ErrUniqueViolation) {
		return FinalizeResult{AssetID: primary.ID}, nil, s.resolveToExisting(ctx, tx, sess, primary.ID, now)
	}
	if err != nil {
		return FinalizeResult{}, nil, err
	}
	if err := s.d.Assets.SetKind(ctx, tx, primary.ID, "live_photo"); err != nil {
		return FinalizeResult{}, nil, err
	}
	if err := s.appendUpsert(ctx, tx, sess.OwnerID, primary.ID, now); err != nil {
		return FinalizeResult{}, nil, err
	}
	// The live component's duration is extracted with the primary's metadata.
	if err := s.enqueue(ctx, tx, JobExtractMetadata, primary.ID); err != nil {
		return FinalizeResult{}, nil, err
	}
	if err := s.d.LibraryPaths.PointToAsset(ctx, tx, storage.PathKey(sess.DestPath), primary.ID); err != nil {
		return FinalizeResult{}, nil, err
	}
	if err := s.d.UploadSessions.SetDone(ctx, tx, sess.ID, primary.ID, true, now); err != nil {
		return FinalizeResult{}, nil, err
	}
	return FinalizeResult{AssetID: primary.ID, Created: true}, nil, nil
}

// resolveToExisting handles a tx2 unique conflict: delete the moved file,
// release the reservation and point the session at the existing asset.
func (s *FinalizeService) resolveToExisting(ctx context.Context, tx *sql.Tx, sess repository.UploadSession, assetID string, now time.Time) error {
	s.removeQuiet(s.libAbs(sess.DestPath))
	if err := s.d.LibraryPaths.ReleaseByUpload(ctx, tx, sess.ID); err != nil {
		return err
	}
	return s.d.UploadSessions.SetDone(ctx, tx, sess.ID, assetID, false, now)
}

// fail marks the session failed with code, releasing its reservation.
func (s *FinalizeService) fail(ctx context.Context, id, code string, release bool) error {
	return s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		if release {
			if err := s.d.LibraryPaths.ReleaseByUpload(ctx, tx, id); err != nil {
				return err
			}
		}
		return s.d.UploadSessions.SetFailed(ctx, tx, id, code, s.d.Clock.Now())
	})
}

// Recover runs at boot before the listeners open: it resolves every
// finalizing session by the S§6.2 table, then deletes stray *.ptpart files
// under the library and staging files with no live session. Idempotent.
func (s *FinalizeService) Recover(ctx context.Context) error {
	sessions, err := s.d.UploadSessions.ListByState(ctx, s.d.Store.R, sessionFinalizing)
	if err != nil {
		return err
	}
	var errs []error
	for _, sess := range sessions {
		if err := s.recoverOne(ctx, sess); err != nil {
			errs = append(errs, fmt.Errorf("recover upload %s: %w", sess.ID, err))
		}
	}
	if err := s.sweep(ctx); err != nil {
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}

// RecoverStuck resolves sessions left finalizing for longer than olderThan
// (a crash without a restart). Sessions finalizing in this process are
// skipped. It does not sweep: that is only safe before uploads start.
func (s *FinalizeService) RecoverStuck(ctx context.Context, olderThan time.Duration) error {
	sessions, err := s.d.UploadSessions.ListStuckFinalizing(ctx, s.d.Store.R, s.d.Clock.Now().Add(-olderThan))
	if err != nil {
		return err
	}
	var errs []error
	for _, sess := range sessions {
		if err := s.recoverOne(ctx, sess); err != nil {
			errs = append(errs, fmt.Errorf("recover upload %s: %w", sess.ID, err))
		}
	}
	return errors.Join(errs...)
}

func (s *FinalizeService) recoverOne(ctx context.Context, sess repository.UploadSession) error {
	if !s.begin(sess.ID) {
		return nil
	}
	defer s.end(sess.ID)
	_, err := s.recoverSession(ctx, sess)
	if _, domain := apperr.As(err); domain && !isInternal(err) {
		return nil // a recorded domain outcome (e.g. primary purged) is resolved
	}
	return err
}

func isInternal(err error) bool {
	ae, ok := apperr.As(err)
	return ok && ae.Code == "internal"
}

// recoverSession applies the S§6.2 recovery table to one finalizing
// session. The caller holds the in-flight mark.
func (s *FinalizeService) recoverSession(ctx context.Context, sess repository.UploadSession) (FinalizeResult, error) {
	meta, err := parseSessionMeta(sess)
	if err != nil {
		return FinalizeResult{}, err
	}
	staging, dest := s.stagingAbs(sess), s.libAbs(sess.DestPath)
	part := dest + storage.PtpartSuffix
	date := func(p string) dateInfo {
		if meta.live() {
			return dateInfo{}
		}
		return s.probeDate(p, meta)
	}
	switch {
	case sess.DestPath != "" && s.fileMatches(dest, sess.Length, sess.SHA256):
		res, err := s.commitAsset(ctx, sess, meta, date(dest))
		if err == nil {
			s.removeQuiet(staging)
			s.removeQuiet(part)
		}
		return res, err
	case sess.DestPath != "" && s.fileMatches(staging, sess.Length, sess.SHA256):
		s.removeQuiet(dest)
		s.removeQuiet(part)
		return s.moveAndCommit(ctx, sess, meta, date(staging), nil)
	}
	s.log.Error("finalize recovery: no valid copy; failing upload", "upload_id", sess.ID)
	if sess.DestPath != "" {
		s.removeQuiet(dest)
		s.removeQuiet(part)
	}
	s.removeQuiet(staging)
	if err := s.fail(ctx, sess.ID, "internal", true); err != nil {
		return FinalizeResult{}, err
	}
	return FinalizeResult{}, apperr.NotFound()
}

// sweep deletes staging files without a receiving or finalizing session and
// *.ptpart files under the library that no finalizing session owns.
func (s *FinalizeService) sweep(ctx context.Context) error {
	keepStaging := map[string]bool{}
	keepPart := map[string]bool{}
	for _, state := range []string{sessionReceiving, sessionFinalizing} {
		sessions, err := s.d.UploadSessions.ListByState(ctx, s.d.Store.R, state)
		if err != nil {
			return err
		}
		for _, sess := range sessions {
			keepStaging[filepath.Clean(s.stagingAbs(sess))] = true
			if sess.DestPath != "" {
				keepPart[filepath.Clean(s.libAbs(sess.DestPath)+storage.PtpartSuffix)] = true
			}
		}
	}
	stagingDir := filepath.Join(s.d.DataDir, stagingDirName)
	ents, err := s.d.FS.ReadDir(stagingDir)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("sweep staging: %w", err)
	}
	for _, e := range ents {
		p := filepath.Join(stagingDir, e.Name())
		if e.Type().IsRegular() && !keepStaging[filepath.Clean(p)] {
			s.log.Info("finalize recovery: removing orphan staging file", "path", p)
			s.removeQuiet(p)
		}
	}
	return s.sweepParts(s.d.LibraryDir, keepPart)
}

func (s *FinalizeService) sweepParts(dir string, keep map[string]bool) error {
	ents, err := s.d.FS.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("sweep library: %w", err)
	}
	var errs []error
	for _, e := range ents {
		p := filepath.Join(dir, e.Name())
		switch {
		case e.IsDir():
			if err := s.sweepParts(p, keep); err != nil {
				errs = append(errs, err)
			}
		case e.Type().IsRegular() && strings.HasSuffix(e.Name(), storage.PtpartSuffix) && !keep[filepath.Clean(p)]:
			s.log.Info("finalize recovery: removing stray partial copy", "path", p)
			s.removeQuiet(p)
		}
	}
	return errors.Join(errs...)
}
