package repository

import (
	"context"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// Change is a row of the change_log table.
type Change struct {
	Seq       int64
	OwnerID   string
	Kind      string
	AssetID   string
	CreatedAt time.Time
}

// ChangeLogRepository accesses the change_log table. It does not orchestrate:
// the service appends and compacts within one transaction.
type ChangeLogRepository struct{}

// Append adds an entry and returns its seq (strictly increasing, never reused).
func (ChangeLogRepository) Append(ctx context.Context, db queries.DBTX, ownerID, kind, assetID string, at time.Time) (int64, error) {
	return queries.New(db).AppendChange(ctx, queries.AppendChangeParams{
		OwnerID: ownerID, Kind: kind, AssetID: assetID, CreatedAt: formatTime(at),
	})
}

// DeleteForAsset removes the asset's entries other than exceptSeq and
// returns how many were removed.
func (ChangeLogRepository) DeleteForAsset(ctx context.Context, db queries.DBTX, assetID string, exceptSeq int64) (int64, error) {
	return queries.New(db).DeleteChangesForAsset(ctx, queries.DeleteChangesForAssetParams{AssetID: assetID, Seq: exceptSeq})
}

// ListAfter returns the owner's entries with seq > cursor, ascending.
func (ChangeLogRepository) ListAfter(ctx context.Context, db queries.DBTX, ownerID string, cursor int64, limit int) ([]Change, error) {
	rows, err := queries.New(db).ListChangesAfter(ctx, queries.ListChangesAfterParams{OwnerID: ownerID, Seq: cursor, Limit: int64(limit)})
	if err != nil {
		return nil, err
	}
	out := make([]Change, 0, len(rows))
	for _, r := range rows {
		c, err := parseTime(r.CreatedAt)
		if err != nil {
			return nil, err
		}
		out = append(out, Change{Seq: r.Seq, OwnerID: r.OwnerID, Kind: r.Kind, AssetID: r.AssetID, CreatedAt: c})
	}
	return out, nil
}

// Head returns the highest seq ever issued (from sqlite_sequence, so it
// survives deletion of the newest rows), or 0 when none was issued.
func (ChangeLogRepository) Head(ctx context.Context, db queries.DBTX) (int64, error) {
	var head int64
	err := db.QueryRowContext(ctx,
		`SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'change_log'), 0)`).Scan(&head)
	return head, err
}

// DeleteBefore removes entries created before t. It returns the highest seq
// removed (0 when nothing was) and how many rows were removed. Call it inside
// a write transaction so the max and the delete see the same rows.
func (ChangeLogRepository) DeleteBefore(ctx context.Context, db queries.DBTX, t time.Time) (int64, int64, error) {
	q := queries.New(db)
	cutoff := formatTime(t)
	maxSeq, err := q.MaxChangeSeqBefore(ctx, cutoff)
	if err != nil {
		return 0, 0, err
	}
	n, err := q.DeleteChangesBefore(ctx, cutoff)
	if err != nil {
		return 0, 0, err
	}
	return maxSeq, n, nil
}
