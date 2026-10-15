package repository

import (
	"context"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// UploadSession is a row of the upload_sessions table.
type UploadSession struct {
	ID           string
	OwnerID      string
	DeviceID     string
	SHA256       string
	Length       int64
	Offset       int64
	State        string // receiving | finalizing | done | failed
	PairRole     *string
	PairSHA256   *string
	MetaJSON     string
	StagingPath  string
	DestPath     string
	AssetID      *string
	AssetCreated bool
	FailureCode  *string
	CreatedAt    time.Time
	UpdatedAt    time.Time
	ExpiresAt    time.Time
}

// UploadSessionsRepository accesses the upload_sessions table.
type UploadSessionsRepository struct{}

func uploadSessionFromRow(r queries.UploadSession) (UploadSession, error) {
	ts, err := parseTimes(r.CreatedAt, r.UpdatedAt, r.ExpiresAt)
	if err != nil {
		return UploadSession{}, err
	}
	return UploadSession{
		ID: r.ID, OwnerID: r.OwnerID, DeviceID: r.DeviceID, SHA256: r.Sha256, Length: r.Length, Offset: r.Offset,
		State: r.State, PairRole: r.PairRole, PairSHA256: r.PairSha256, MetaJSON: r.MetaJson, StagingPath: r.StagingPath,
		DestPath: r.DestPath, AssetID: r.AssetID, AssetCreated: r.AssetCreated != 0, FailureCode: r.FailureCode,
		CreatedAt: ts[0], UpdatedAt: ts[1], ExpiresAt: ts[2],
	}, nil
}

func uploadSessionsFromRows(rows []queries.UploadSession) ([]UploadSession, error) {
	out := make([]UploadSession, 0, len(rows))
	for _, r := range rows {
		u, err := uploadSessionFromRow(r)
		if err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, nil
}

// Insert adds a session; ErrUniqueViolation when the owner already has an
// active (receiving or finalizing) session for the same sha256.
func (UploadSessionsRepository) Insert(ctx context.Context, db queries.DBTX, u UploadSession) error {
	return mapErr(queries.New(db).InsertUploadSession(ctx, queries.InsertUploadSessionParams{
		ID: u.ID, OwnerID: u.OwnerID, DeviceID: u.DeviceID, Sha256: u.SHA256, Length: u.Length, Offset: u.Offset,
		State: u.State, PairRole: u.PairRole, PairSha256: u.PairSHA256, MetaJson: u.MetaJSON, StagingPath: u.StagingPath,
		DestPath: u.DestPath, AssetID: u.AssetID, AssetCreated: boolInt(u.AssetCreated), FailureCode: u.FailureCode,
		CreatedAt: formatTime(u.CreatedAt), UpdatedAt: formatTime(u.UpdatedAt), ExpiresAt: formatTime(u.ExpiresAt),
	}))
}

// Get returns the session or ErrNotFound.
func (UploadSessionsRepository) Get(ctx context.Context, db queries.DBTX, id string) (UploadSession, error) {
	r, err := queries.New(db).GetUploadSession(ctx, id)
	if err != nil {
		return UploadSession{}, mapErr(err)
	}
	return uploadSessionFromRow(r)
}

// GetActive returns the owner's receiving or finalizing session for sha, or
// ErrNotFound. Done and failed sessions are ignored.
func (UploadSessionsRepository) GetActive(ctx context.Context, db queries.DBTX, ownerID, sha string) (UploadSession, error) {
	r, err := queries.New(db).GetActiveUploadSession(ctx, queries.GetActiveUploadSessionParams{OwnerID: ownerID, Sha256: sha})
	if err != nil {
		return UploadSession{}, mapErr(err)
	}
	return uploadSessionFromRow(r)
}

// ListActiveBySHAs returns the owner's active sessions for the given hashes.
func (UploadSessionsRepository) ListActiveBySHAs(ctx context.Context, db queries.DBTX, ownerID string, shas []string) ([]UploadSession, error) {
	rows, err := queries.New(db).ListActiveUploadSessionsBySHAs(ctx, queries.ListActiveUploadSessionsBySHAsParams{OwnerID: ownerID, Shas: shas})
	if err != nil {
		return nil, err
	}
	return uploadSessionsFromRows(rows)
}

// UpdateOffset records progress and slides the expiry.
func (UploadSessionsRepository) UpdateOffset(ctx context.Context, db queries.DBTX, id string, offset int64, updatedAt, expiresAt time.Time) error {
	return requireRow(queries.New(db).UpdateUploadSessionOffset(ctx, queries.UpdateUploadSessionOffsetParams{
		Offset: offset, UpdatedAt: formatTime(updatedAt), ExpiresAt: formatTime(expiresAt), ID: id,
	}))
}

// SetFinalizing moves the session to finalizing and records the destination.
func (UploadSessionsRepository) SetFinalizing(ctx context.Context, db queries.DBTX, id, destPath string, at time.Time) error {
	return requireRow(queries.New(db).SetUploadSessionFinalizing(ctx, queries.SetUploadSessionFinalizingParams{
		DestPath: destPath, UpdatedAt: formatTime(at), ID: id,
	}))
}

// SetDone completes the session with its asset; created reports whether a
// new asset was made (false when it deduplicated onto an existing one).
func (UploadSessionsRepository) SetDone(ctx context.Context, db queries.DBTX, id, assetID string, created bool, at time.Time) error {
	return requireRow(queries.New(db).SetUploadSessionDone(ctx, queries.SetUploadSessionDoneParams{
		AssetID: &assetID, AssetCreated: boolInt(created), UpdatedAt: formatTime(at), ID: id,
	}))
}

// SetFailed fails the session with a problem code.
func (UploadSessionsRepository) SetFailed(ctx context.Context, db queries.DBTX, id, code string, at time.Time) error {
	return requireRow(queries.New(db).SetUploadSessionFailed(ctx, queries.SetUploadSessionFailedParams{
		FailureCode: &code, UpdatedAt: formatTime(at), ID: id,
	}))
}

// ListByState returns sessions in the state, oldest first.
func (UploadSessionsRepository) ListByState(ctx context.Context, db queries.DBTX, state string) ([]UploadSession, error) {
	rows, err := queries.New(db).ListUploadSessionsByState(ctx, state)
	if err != nil {
		return nil, err
	}
	return uploadSessionsFromRows(rows)
}

// ListExpired returns receiving sessions whose expires_at is before now.
func (UploadSessionsRepository) ListExpired(ctx context.Context, db queries.DBTX, now time.Time) ([]UploadSession, error) {
	rows, err := queries.New(db).ListExpiredUploadSessions(ctx, formatTime(now))
	if err != nil {
		return nil, err
	}
	return uploadSessionsFromRows(rows)
}

// ListStuckFinalizing returns finalizing sessions not touched since before.
func (UploadSessionsRepository) ListStuckFinalizing(ctx context.Context, db queries.DBTX, before time.Time) ([]UploadSession, error) {
	rows, err := queries.New(db).ListStuckFinalizingUploadSessions(ctx, formatTime(before))
	if err != nil {
		return nil, err
	}
	return uploadSessionsFromRows(rows)
}

// DeleteOlderThan deletes sessions in any of states last updated before the
// cutoff and returns the count.
func (UploadSessionsRepository) DeleteOlderThan(ctx context.Context, db queries.DBTX, states []string, before time.Time) (int64, error) {
	return queries.New(db).DeleteUploadSessionsOlderThan(ctx, queries.DeleteUploadSessionsOlderThanParams{
		States: states, Before: formatTime(before),
	})
}

// Delete removes one session.
func (UploadSessionsRepository) Delete(ctx context.Context, db queries.DBTX, id string) error {
	return requireRow(queries.New(db).DeleteUploadSession(ctx, id))
}

// SetMetaJSON replaces meta_json (cooperative joins record their sources).
// Raw SQL like ChangeLog.Head; fold into sqlc at the next regen.
func (UploadSessionsRepository) SetMetaJSON(ctx context.Context, db queries.DBTX, id, metaJSON string) error {
	res, err := db.ExecContext(ctx, "UPDATE upload_sessions SET meta_json = ? WHERE id = ?", metaJSON, id)
	if err != nil {
		return err
	}
	return requireRow(res.RowsAffected())
}

// SumActiveLengths returns the total declared length of the owner's active
// sessions (for quota reservation).
func (UploadSessionsRepository) SumActiveLengths(ctx context.Context, db queries.DBTX, ownerID string) (int64, error) {
	return queries.New(db).SumActiveUploadLengths(ctx, ownerID)
}
