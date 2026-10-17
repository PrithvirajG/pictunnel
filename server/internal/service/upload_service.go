package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"path"
	"path/filepath"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/clock"
	"github.com/PrithvirajG/pictunnel/server/internal/ids"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

// Upload defaults (globals; P§7.3, S§10.2).
const (
	DefaultMaxFileBytes  int64 = 53687091200
	DefaultReserveBytes  int64 = 1 << 30
	uploadSessionTTL           = 24 * time.Hour
	uploadRetention            = 7 * 24 * time.Hour
	stuckFinalizingAfter       = 10 * time.Minute
	defaultHeadLockWait        = 5 * time.Second
	failureExpired             = "expired"
	failureStagingLost         = "staging_lost"
	copyBufferSize             = 256 << 10
)

// UploadConfig holds the upload limits.
type UploadConfig struct {
	MaxFileBytes int64 // upload.max_file_bytes; <= 0 means DefaultMaxFileBytes
	ReserveBytes int64 // storage.reserve_bytes; taken as given (0 disables the reserve)
	// LockWait bounds how long HEAD waits for an in-flight request on the
	// same session (real time); <= 0 means 5 s.
	LockWait time.Duration
}

// UploadServiceDeps are the UploadService dependencies. AssetSources links
// the caller's local_id when a create resolves to existing content (outcome
// #3), as finalize does. Failpoints is nil in production.
type UploadServiceDeps struct {
	Store        *store.Store
	Sessions     repository.UploadSessionsRepository
	Assets       repository.AssetsRepository
	LiveVideos   repository.LiveVideosRepository
	Tombstones   repository.TombstonesRepository
	Users        repository.UsersRepository
	AssetSources repository.AssetSourcesRepository
	Finalize     *FinalizeService
	FS           storage.FS
	FreeSpace    storage.FreeSpaceFunc
	Clock        clock.Clock
	Failpoints   Failpoints
	Cfg          UploadConfig
	// DataDir holds the staging dir <DataDir>/uploads; staging_path is
	// stored relative to it.
	DataDir string
	// LibraryDir is probed for free space alongside the staging dir.
	LibraryDir string
	Log        *slog.Logger
}

// UploadService is the tus state machine (S§6.1, P§7.3): create with its
// precedence order, append with resumable hashing, head, terminate and
// expiry.
type UploadService struct {
	d     UploadServiceDeps
	cfg   UploadConfig
	log   *slog.Logger
	locks *uploadLocks
}

// NewUploadService returns an UploadService.
func NewUploadService(d UploadServiceDeps) *UploadService {
	cfg := d.Cfg
	if cfg.MaxFileBytes <= 0 {
		cfg.MaxFileBytes = DefaultMaxFileBytes
	}
	if cfg.ReserveBytes < 0 {
		cfg.ReserveBytes = 0
	}
	if cfg.LockWait <= 0 {
		cfg.LockWait = defaultHeadLockWait
	}
	log := d.Log
	if log == nil {
		log = slog.Default()
	}
	return &UploadService{d: d, cfg: cfg, log: log, locks: newUploadLocks()}
}

// CreateInput is a tus creation request. Body is nil without a body
// (creation-with-upload otherwise); BodyChecksum is the raw sha256 of the
// body from Upload-Checksum, or nil.
type CreateInput struct {
	Length       int64
	Meta         UploadMeta
	Body         io.Reader
	BodyChecksum []byte
}

// UploadView is what the tus handler reports for a session. AssetID and
// AssetCreated are set once Done.
type UploadView struct {
	ID           string
	Offset       int64
	Length       int64
	ExpiresAt    time.Time
	AssetID      string
	AssetCreated bool
	Done         bool
}

func viewOf(s repository.UploadSession) UploadView {
	v := UploadView{ID: s.ID, Offset: s.Offset, Length: s.Length, ExpiresAt: s.ExpiresAt}
	if s.State == sessionDone {
		v.Done, v.Offset, v.AssetID, v.AssetCreated = true, s.Length, deref(s.AssetID), s.AssetCreated
	}
	return v
}

func stagingRel(id string) string { return path.Join(stagingDirName, id+".part") }

func (s *UploadService) stagingDir() string { return filepath.Join(s.d.DataDir, stagingDirName) }

func (s *UploadService) stagingAbs(sess repository.UploadSession) string {
	if filepath.IsAbs(sess.StagingPath) {
		return sess.StagingPath
	}
	return filepath.Join(s.d.DataDir, filepath.FromSlash(sess.StagingPath))
}

func (s *UploadService) removeQuiet(p string) {
	if err := s.d.FS.Remove(p); err != nil && !errors.Is(err, fs.ErrNotExist) {
		s.log.Warn("upload: remove failed", "path", p, "err", err)
	}
}

func uploadInternal(op string, err error) error {
	return fmt.Errorf("upload: %s: %w (%w)", op, apperr.Internal(), err)
}

// expired reports whether a receiving session is past its expiry.
func (s *UploadService) expired(sess repository.UploadSession) bool {
	// Strictly after, like ListExpiredUploadSessions (expires_at < now).
	return sess.State == sessionReceiving && s.d.Clock.Now().After(sess.ExpiresAt)
}

// load reads the caller's session; other owners' and failed sessions are
// not_found (no existence leak).
func (s *UploadService) load(ctx context.Context, p Principal, id string) (repository.UploadSession, error) {
	sess, err := s.d.Sessions.Get(ctx, s.d.Store.R, id)
	if errors.Is(err, repository.ErrNotFound) {
		return sess, apperr.NotFound()
	}
	if err != nil {
		return sess, err
	}
	if sess.OwnerID != p.UserID || sess.State == sessionFailed {
		return sess, apperr.NotFound()
	}
	return sess, nil
}

// --- create ---

// freeSpace is the outcome #6 probe, taken before the create transaction so
// the transaction holds no I/O; it is only consulted if #2–#5 pass.
type freeSpace struct {
	ok  bool
	err error
}

// probeFree checks that both the staging volume and the library volume have
// need bytes free (S§6.5). When both dirs are on one volume the two probes
// report the same number, so probing both is always correct.
func (s *UploadService) probeFree(need int64) freeSpace {
	if s.d.FreeSpace == nil {
		return freeSpace{ok: true}
	}
	dirs := []string{s.stagingDir()}
	if s.d.LibraryDir != "" && filepath.Clean(s.d.LibraryDir) != filepath.Clean(s.stagingDir()) {
		dirs = append(dirs, s.d.LibraryDir)
	}
	res := freeSpace{ok: need >= 0}
	for _, dir := range dirs {
		free, err := s.d.FreeSpace(dir)
		if err != nil {
			return freeSpace{err: uploadInternal("free space of "+dir, err)}
		}
		if need < 0 || free < uint64(need) {
			res.ok = false
		}
	}
	return res
}

// createResult is what the create transaction decided.
type createResult struct {
	sess    repository.UploadSession
	outcome int // 3, 4 or 7
}

// Create runs a tus POST through the P§7.3 precedence order 1–7. Outcome 3
// inserts a done session row so HEAD on its Location works. With a body,
// bytes are appended for a new session (and for an existing one at offset
// 0); a body that completes the upload finalizes before returning. A body
// read error after a partial write returns the committed view and the read
// error.
func (s *UploadService) Create(ctx context.Context, p Principal, in CreateInput) (UploadView, error) {
	// #1.
	if in.Length > s.cfg.MaxFileBytes {
		return UploadView{}, apperr.FileTooLarge(s.cfg.MaxFileBytes)
	}
	if in.Length < 0 {
		return UploadView{}, apperr.InvalidRequest("Upload-Length must not be negative")
	}
	meta := in.Meta
	if meta.PairRole == "" {
		meta.PairRole = pairRolePrimary
	}
	if err := meta.validate(); err != nil {
		return UploadView{}, err
	}
	// An expired session that the sweep has not reached yet must not be
	// resumed (HEAD already reports it gone); retire it so a new one fits.
	if cur, err := s.d.Sessions.GetActive(ctx, s.d.Store.R, p.UserID, meta.SHA256); err == nil && s.expired(cur) {
		if err := s.expireOne(ctx, cur.ID); err != nil {
			return UploadView{}, err
		}
	}
	// The free-space probe queries the staging dir, which a fresh data dir
	// does not have until the first upload.
	if err := s.d.FS.MkdirAll(s.stagingDir(), 0o755); err != nil {
		return UploadView{}, uploadInternal("staging dir", err)
	}
	free := s.probeFree(in.Length + s.cfg.ReserveBytes)

	var res createResult
	var err error
	for attempt := 0; ; attempt++ {
		res, err = s.createTx(ctx, p, in.Length, meta, free)
		// A concurrent create inserted the same (owner, sha256) session:
		// the retry finds it as outcome #4.
		if errors.Is(err, repository.ErrUniqueViolation) && attempt < 3 {
			continue
		}
		break
	}
	if err != nil {
		return UploadView{}, err
	}

	switch res.outcome {
	case 3:
		return viewOf(res.sess), nil
	case 4:
		sess := res.sess
		switch {
		case sess.State != sessionReceiving:
			return viewOf(sess), nil
		case sess.Offset == sess.Length:
			// Fully received but never finalized (a crash between the last
			// offset commit and finalize): finish it now.
			return s.appendSession(ctx, p, sess.ID, sess.Offset, nil, nil)
		case in.Body != nil && sess.Offset == 0:
			v, err := s.appendSession(ctx, p, sess.ID, 0, in.Body, in.BodyChecksum)
			if isCode(err, "upload_locked") || isCode(err, "offset_mismatch") {
				// Another device is writing it: the body is discarded and the
				// client resumes from the committed offset (201, P§7.3 #4).
				cur, lerr := s.load(ctx, p, sess.ID)
				if lerr != nil {
					return UploadView{}, lerr
				}
				return viewOf(cur), nil
			}
			return v, err
		}
		return viewOf(sess), nil
	}

	// #7: the staging file exists from the start, so a restart can tell a
	// lost file from an empty one.
	if err := s.d.FS.MkdirAll(s.stagingDir(), 0o755); err != nil {
		return UploadView{}, uploadInternal("staging dir", err)
	}
	f, err := s.d.FS.OpenFile(s.stagingAbs(res.sess), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return UploadView{}, uploadInternal("create staging", err)
	}
	if err := f.Close(); err != nil {
		return UploadView{}, uploadInternal("create staging", err)
	}
	if in.Body == nil && in.Length > 0 {
		return viewOf(res.sess), nil
	}
	body := in.Body
	if body == nil {
		body = bytes.NewReader(nil) // empty file: finalize now
	}
	return s.appendSession(ctx, p, res.sess.ID, 0, body, in.BodyChecksum)
}

func isCode(err error, code string) bool {
	ae, ok := apperr.As(err)
	return ok && ae.Code == code
}

// createTx is outcomes #2–#7 in one write transaction.
func (s *UploadService) createTx(ctx context.Context, p Principal, length int64, meta UploadMeta, free freeSpace) (createResult, error) {
	var res createResult
	err := s.d.Store.WithTx(ctx, func(tx *sql.Tx) error {
		res = createResult{}
		now := s.d.Clock.Now()
		owner := p.UserID

		// #2 tombstone. A live component is covered by its primary's
		// existence (a purged primary leaves only the primary's tombstone).
		if !meta.live() && !meta.OverrideTombstone {
			ts, err := s.d.Tombstones.Get(ctx, tx, owner, meta.SHA256)
			if err == nil {
				return apperr.Tombstoned(ts.DeletedAt)
			}
			if !errors.Is(err, repository.ErrNotFound) {
				return err
			}
		}

		// #3 existing asset (or, for a live component, the attached video;
		// a missing primary is pair_primary_missing, P§5 H4).
		var existing string
		if meta.live() {
			primary, err := s.d.Assets.GetBySHA(ctx, tx, owner, meta.PairSHA256)
			if errors.Is(err, repository.ErrNotFound) {
				return apperr.PairPrimaryMissing()
			}
			if err != nil {
				return err
			}
			if _, err := s.d.LiveVideos.GetByAsset(ctx, tx, primary.ID); err == nil {
				existing = primary.ID
			} else if !errors.Is(err, repository.ErrNotFound) {
				return err
			}
		} else {
			a, err := s.d.Assets.GetBySHA(ctx, tx, owner, meta.SHA256)
			switch {
			case err == nil:
				if a.SizeBytes != length {
					return apperr.LengthMismatch()
				}
				existing = a.ID
				if meta.LocalID != "" {
					if err := s.d.AssetSources.Upsert(ctx, tx, p.DeviceID, meta.LocalID, a.ID, now); err != nil {
						return err
					}
				}
			case !errors.Is(err, repository.ErrNotFound):
				return err
			}
		}
		if existing != "" {
			sess, err := s.newSession(p, length, meta, now)
			if err != nil {
				return err
			}
			sess.State, sess.Offset, sess.StagingPath = sessionDone, length, ""
			sess.AssetID = &existing
			if err := s.d.Sessions.Insert(ctx, tx, sess); err != nil {
				return err
			}
			res = createResult{sess: sess, outcome: 3}
			return nil
		}

		// #4 active session.
		cur, err := s.d.Sessions.GetActive(ctx, tx, owner, meta.SHA256)
		if err == nil {
			if cur.Length != length {
				return apperr.LengthMismatch()
			}
			// Record the joining device's local_id so finalize links it too.
			sm, err := parseSessionMeta(cur)
			if err != nil {
				return err
			}
			if sm.addJoined(cur.DeviceID, p.DeviceID, meta.LocalID) {
				mj, err := json.Marshal(sm)
				if err != nil {
					return err
				}
				if err := s.d.Sessions.SetMetaJSON(ctx, tx, cur.ID, string(mj)); err != nil {
					return err
				}
				cur.MetaJSON = string(mj)
			}
			res = createResult{sess: cur, outcome: 4}
			return nil
		}
		if !errors.Is(err, repository.ErrNotFound) {
			return err
		}

		// #5 quota: assets + live videos + active sessions + this upload.
		user, err := s.d.Users.GetByID(ctx, tx, owner)
		if err != nil {
			return err
		}
		if user.QuotaBytes != nil {
			used := length
			for _, sum := range []func() (int64, error){
				func() (int64, error) { return s.d.Assets.SumSizes(ctx, tx, owner) },
				func() (int64, error) { return s.d.LiveVideos.SumSizes(ctx, tx, owner) },
				func() (int64, error) { return s.d.Sessions.SumActiveLengths(ctx, tx, owner) },
			} {
				n, err := sum()
				if err != nil {
					return err
				}
				used += n
			}
			if used > *user.QuotaBytes {
				return apperr.QuotaExceeded()
			}
		}

		// #6 free space.
		if free.err != nil {
			return free.err
		}
		if !free.ok {
			return apperr.InsufficientStorage()
		}

		// #7 new session.
		sess, err := s.newSession(p, length, meta, now)
		if err != nil {
			return err
		}
		if err := s.d.Sessions.Insert(ctx, tx, sess); err != nil {
			return err
		}
		res = createResult{sess: sess, outcome: 7}
		return nil
	})
	return res, err
}

func (s *UploadService) newSession(p Principal, length int64, meta UploadMeta, now time.Time) (repository.UploadSession, error) {
	mj, err := json.Marshal(meta)
	if err != nil {
		return repository.UploadSession{}, err
	}
	id := ids.New()
	role := meta.PairRole
	sess := repository.UploadSession{
		ID: id, OwnerID: p.UserID, DeviceID: p.DeviceID, SHA256: meta.SHA256, Length: length,
		State: sessionReceiving, PairRole: &role, MetaJSON: string(mj), StagingPath: stagingRel(id),
		CreatedAt: now, UpdatedAt: now, ExpiresAt: now.Add(uploadSessionTTL),
	}
	if meta.live() {
		ps := meta.PairSHA256
		sess.PairSHA256 = &ps
	}
	return sess, nil
}

// --- head ---

// Head reports a session. Other owners', failed and expired sessions are
// not_found. It waits briefly for an in-flight request on the session so
// the offset it reports is settled, and finalizes a session that was fully
// received but never finalized.
func (s *UploadService) Head(ctx context.Context, p Principal, id string) (UploadView, error) {
	sess, err := s.load(ctx, p, id)
	if err != nil {
		return UploadView{}, err
	}
	if sess.State != sessionReceiving {
		return viewOf(sess), nil
	}
	lk := s.locks.acquire(ctx, id, s.cfg.LockWait)
	if lk == nil {
		return UploadView{}, apperr.UploadLocked()
	}
	return s.underLock(ctx, p, lk, true, func(sess repository.UploadSession) (UploadView, bool, error) {
		return viewOf(sess), false, nil
	})
}

// Peek reports the caller's session without taking its lock, so its offset
// may be stale while a request is writing. The tus handler uses it only to
// bound a PATCH body by the (immutable) Upload-Length before reading it.
func (s *UploadService) Peek(ctx context.Context, p Principal, id string) (UploadView, error) {
	sess, err := s.load(ctx, p, id)
	if err != nil {
		return UploadView{}, err
	}
	return viewOf(sess), nil
}

// underLock re-reads the session with lk held and applies the common
// rules: not receiving → its view (finalizing is upload_locked: a finalize
// or recovery owns it), expired → expire and not_found, fully received →
// finalize (when finalizeFull). Otherwise fn runs; its bool asks to forget
// the lock entry.
func (s *UploadService) underLock(ctx context.Context, p Principal, lk *uploadLock, finalizeFull bool,
	fn func(repository.UploadSession) (UploadView, bool, error)) (v UploadView, err error) {
	forget := false
	defer func() { s.locks.release(lk, forget) }()
	sess, err := s.load(ctx, p, lk.id)
	if err != nil {
		forget = true
		return UploadView{}, err
	}
	switch {
	case sess.State == sessionDone:
		forget = true
		return viewOf(sess), nil
	case sess.State == sessionFinalizing:
		forget = true
		return UploadView{}, apperr.UploadLocked()
	case s.expired(sess):
		forget = true
		if err := s.expireLocked(ctx, sess); err != nil {
			return UploadView{}, err
		}
		return UploadView{}, apperr.NotFound()
	case finalizeFull && sess.Offset == sess.Length:
		forget = true
		return s.finalizeLocked(ctx, lk, sess)
	}
	v, forget, err = fn(sess)
	return v, err
}

// --- append ---

// Append runs a tus PATCH (S§6.1): it writes at most length-offset bytes of
// body at offset, fsyncs, commits the new offset and refreshes the expiry,
// and finalizes when the upload is complete. checksum, when set, is the raw
// sha256 of this request's body. A body read error after a partial write
// commits the partial offset and returns the view with the read error.
func (s *UploadService) Append(ctx context.Context, p Principal, id string, offset int64, body io.Reader, checksum []byte) (UploadView, error) {
	return s.appendSession(ctx, p, id, offset, body, checksum)
}

func (s *UploadService) appendSession(ctx context.Context, p Principal, id string, offset int64, body io.Reader, checksum []byte) (UploadView, error) {
	lk := s.locks.tryAcquire(id)
	if lk == nil {
		return UploadView{}, apperr.UploadLocked()
	}
	return s.underLock(ctx, p, lk, true, func(sess repository.UploadSession) (UploadView, bool, error) {
		if offset != sess.Offset {
			return UploadView{}, false, apperr.OffsetMismatch(sess.Offset)
		}
		return s.write(ctx, lk, sess, body, checksum)
	})
}

// openStaging opens the staging file positioned at sess.Offset with lk's
// hasher covering [0, offset): a longer file is truncated; a shorter one
// fails the session (not_found).
func (s *UploadService) openStaging(ctx context.Context, lk *uploadLock, sess repository.UploadSession) (storage.File, error) {
	p := s.stagingAbs(sess)
	flag := os.O_RDWR
	if sess.Offset == 0 {
		flag |= os.O_CREATE
	}
	f, err := s.d.FS.OpenFile(p, flag, 0o600)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, s.stagingLost(ctx, sess)
	}
	if err != nil {
		return nil, uploadInternal("open staging", err)
	}
	fi, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, uploadInternal("stat staging", err)
	}
	switch {
	case fi.Size() < sess.Offset:
		f.Close()
		return nil, s.stagingLost(ctx, sess)
	case fi.Size() > sess.Offset:
		// Bytes past the committed offset never committed (a crash or a
		// rejected checksum): drop them.
		if err := f.Truncate(sess.Offset); err != nil {
			f.Close()
			return nil, uploadInternal("truncate staging", err)
		}
	}
	if lk.hasher == nil || lk.hashed != sess.Offset {
		// After a restart (or any doubt) re-hash the staged prefix (P§7.4.1).
		lk.hasher, lk.hashed = nil, 0
		h := sha256.New()
		if _, err := f.Seek(0, io.SeekStart); err != nil {
			f.Close()
			return nil, uploadInternal("seek staging", err)
		}
		if _, err := io.CopyN(h, f, sess.Offset); err != nil {
			f.Close()
			return nil, uploadInternal("rehash staging", err)
		}
		lk.hasher, lk.hashed = h, sess.Offset
	}
	if _, err := f.Seek(sess.Offset, io.SeekStart); err != nil {
		f.Close()
		return nil, uploadInternal("seek staging", err)
	}
	return f, nil
}

// stagingLost fails a session whose staging file is missing or short.
func (s *UploadService) stagingLost(ctx context.Context, sess repository.UploadSession) error {
	s.log.Error("upload: staging file missing or short; failing session", "upload_id", sess.ID, "offset", sess.Offset)
	if err := s.d.Sessions.SetFailed(ctx, s.d.Store.W, sess.ID, failureStagingLost, s.d.Clock.Now()); err != nil {
		return err
	}
	s.removeQuiet(s.stagingAbs(sess))
	return apperr.NotFound()
}

// write is append steps 4–9 with lk held. The bool asks to forget the lock
// entry (the session left receiving).
func (s *UploadService) write(ctx context.Context, lk *uploadLock, sess repository.UploadSession, body io.Reader, checksum []byte) (UploadView, bool, error) {
	f, err := s.openStaging(ctx, lk, sess)
	if err != nil {
		return UploadView{}, isCode(err, "not_found"), err
	}
	closed := false
	defer func() {
		if !closed {
			f.Close()
		}
	}()

	// Step 5: copy at most length-offset bytes into the file and hasher.
	var bodyHash = sha256.New()
	var readErr, writeErr error
	written := int64(0)
	if body != nil {
		lr := io.LimitReader(body, sess.Length-sess.Offset)
		buf := make([]byte, copyBufferSize)
		for {
			n, rerr := lr.Read(buf)
			if n > 0 {
				w, werr := f.Write(buf[:n])
				written += int64(w)
				if werr == nil && w < n {
					werr = io.ErrShortWrite
				}
				if werr != nil {
					writeErr = werr
					break
				}
				lk.hasher.Write(buf[:n])
				bodyHash.Write(buf[:n])
			}
			if rerr == io.EOF {
				break
			}
			if rerr != nil {
				readErr = rerr
				break
			}
		}
	}
	newOffset := sess.Offset + written

	// The bytes of this request cannot be kept: drop them and the hasher.
	rollback := func() error {
		lk.hasher, lk.hashed = nil, 0
		if err := f.Truncate(sess.Offset); err != nil {
			return uploadInternal("truncate staging", err)
		}
		return nil
	}
	if writeErr != nil {
		if err := rollback(); err != nil {
			return UploadView{}, false, err
		}
		return UploadView{}, false, uploadInternal("write staging", writeErr)
	}
	// Step 7: a per-request checksum covers the whole body, so a cut-short
	// body cannot be verified either.
	if checksum != nil && (readErr != nil || !bytes.Equal(bodyHash.Sum(nil), checksum)) {
		if err := rollback(); err != nil {
			return UploadView{}, false, err
		}
		if readErr != nil {
			return viewOf(sess), false, readErr
		}
		return UploadView{}, false, apperr.ChecksumMismatch()
	}

	// Step 6: fsync, then commit the offset. The commit survives a request
	// cancelled by a dropped client or a shutdown (S§10.1).
	if written > 0 {
		if err := f.Sync(); err != nil {
			lk.hasher, lk.hashed = nil, 0
			return UploadView{}, false, uploadInternal("fsync staging", err)
		}
		if err := hitFailpoint(s.d.Failpoints, FPAppendAfterFsync); err != nil {
			lk.hasher, lk.hashed = nil, 0
			return UploadView{}, false, err
		}
		now := s.d.Clock.Now()
		cctx := context.WithoutCancel(ctx)
		err := s.d.Store.WithTx(cctx, func(tx *sql.Tx) error {
			if err := s.d.Sessions.UpdateOffset(cctx, tx, sess.ID, newOffset, now, now.Add(uploadSessionTTL)); err != nil {
				return err
			}
			return hitFailpoint(s.d.Failpoints, FPAppendBeforeCommit)
		})
		if err != nil {
			lk.hasher, lk.hashed = nil, 0
			return UploadView{}, false, err
		}
		lk.hashed = newOffset
		sess.Offset, sess.UpdatedAt, sess.ExpiresAt = newOffset, now, now.Add(uploadSessionTTL)
	}
	if err := f.Close(); err != nil {
		s.log.Warn("upload: close staging", "upload_id", sess.ID, "err", err)
	}
	closed = true

	// Step 9: the client went away mid-body; the partial offset stands.
	if readErr != nil {
		return viewOf(sess), false, readErr
	}
	// Step 8.
	if sess.Offset == sess.Length {
		v, err := s.finalizeLocked(ctx, lk, sess)
		return v, true, err
	}
	return viewOf(sess), false, nil
}

// finalizeLocked runs Finalize for a fully received session with lk held,
// re-hashing the staging file first when the hasher does not cover it.
func (s *UploadService) finalizeLocked(ctx context.Context, lk *uploadLock, sess repository.UploadSession) (UploadView, error) {
	if lk.hasher == nil || lk.hashed != sess.Length {
		f, err := s.openStaging(ctx, lk, sess)
		if err != nil {
			return UploadView{}, err
		}
		if err := f.Close(); err != nil {
			s.log.Warn("upload: close staging", "upload_id", sess.ID, "err", err)
		}
	}
	digest := hex.EncodeToString(lk.hasher.Sum(nil))
	// The journal must not stop halfway because the client left after the
	// last byte.
	res, err := s.d.Finalize.Finalize(context.WithoutCancel(ctx), sess, digest)
	if err != nil {
		return UploadView{}, err
	}
	v := viewOf(sess)
	v.Done, v.Offset, v.AssetID, v.AssetCreated = true, sess.Length, res.AssetID, res.Created
	return v, nil
}

// --- terminate and expiry ---

// Terminate runs a tus DELETE (S§6.4): a receiving session's staging file
// and row are deleted; a done session is left as is; anything else is
// not_found. A session in use is upload_locked.
func (s *UploadService) Terminate(ctx context.Context, p Principal, id string) error {
	sess, err := s.load(ctx, p, id)
	if err != nil {
		return err
	}
	if sess.State == sessionDone {
		return nil
	}
	lk := s.locks.tryAcquire(id)
	if lk == nil {
		return apperr.UploadLocked()
	}
	_, err = s.underLock(ctx, p, lk, false, func(sess repository.UploadSession) (UploadView, bool, error) {
		// The row goes first: a crash before the file delete leaves an
		// orphan staging file, which the boot sweep removes.
		if err := s.d.Sessions.Delete(ctx, s.d.Store.W, sess.ID); err != nil {
			return UploadView{}, false, err
		}
		s.removeQuiet(s.stagingAbs(sess))
		return UploadView{}, true, nil
	})
	return err
}

// expireOne fails one expired receiving session if it is not in use.
func (s *UploadService) expireOne(ctx context.Context, id string) error {
	lk := s.locks.tryAcquire(id)
	if lk == nil {
		return nil // in use: a request is about to refresh it
	}
	forget := false
	defer func() { s.locks.release(lk, forget) }()
	sess, err := s.d.Sessions.Get(ctx, s.d.Store.R, id)
	if errors.Is(err, repository.ErrNotFound) {
		forget = true
		return nil
	}
	if err != nil {
		return err
	}
	if !s.expired(sess) {
		return nil
	}
	forget = true
	return s.expireLocked(ctx, sess)
}

func (s *UploadService) expireLocked(ctx context.Context, sess repository.UploadSession) error {
	if err := s.d.Sessions.SetFailed(ctx, s.d.Store.W, sess.ID, failureExpired, s.d.Clock.Now()); err != nil {
		return err
	}
	s.removeQuiet(s.stagingAbs(sess))
	return nil
}

// ExpireSessions is the expire_uploads job body (S§6.4): receiving sessions
// past expires_at become failed(expired) with their staging deleted, done
// and failed rows older than 7 days are deleted, and finalizing sessions
// stuck for 10 minutes are recovered.
func (s *UploadService) ExpireSessions(ctx context.Context) error {
	now := s.d.Clock.Now()
	expired, err := s.d.Sessions.ListExpired(ctx, s.d.Store.R, now)
	if err != nil {
		return err
	}
	var errs []error
	for _, sess := range expired {
		if err := s.expireOne(ctx, sess.ID); err != nil {
			errs = append(errs, fmt.Errorf("expire upload %s: %w", sess.ID, err))
		}
	}
	if _, err := s.d.Sessions.DeleteOlderThan(ctx, s.d.Store.W, []string{sessionDone, sessionFailed}, now.Add(-uploadRetention)); err != nil {
		errs = append(errs, err)
	}
	if s.d.Finalize != nil {
		if err := s.d.Finalize.RecoverStuck(ctx, stuckFinalizingAfter); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
