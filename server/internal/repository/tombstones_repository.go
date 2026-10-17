package repository

import (
	"context"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// Tombstone is a row of the tombstones table: a purged asset's hash.
type Tombstone struct {
	OwnerID   string
	SHA256    string
	Filename  string
	DeletedAt time.Time
}

// TombstonesRepository accesses the tombstones table.
type TombstonesRepository struct{}

func tombstoneFromRow(r queries.Tombstone) (Tombstone, error) {
	d, err := parseTime(r.DeletedAt)
	if err != nil {
		return Tombstone{}, err
	}
	return Tombstone{OwnerID: r.OwnerID, SHA256: r.Sha256, Filename: r.Filename, DeletedAt: d}, nil
}

func tombstonesFromRows(rows []queries.Tombstone) ([]Tombstone, error) {
	out := make([]Tombstone, 0, len(rows))
	for _, r := range rows {
		t, err := tombstoneFromRow(r)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, nil
}

// Insert records a tombstone, replacing any existing one for (owner, sha).
func (TombstonesRepository) Insert(ctx context.Context, db queries.DBTX, t Tombstone) error {
	return mapErr(queries.New(db).InsertTombstone(ctx, queries.InsertTombstoneParams{
		OwnerID: t.OwnerID, Sha256: t.SHA256, Filename: t.Filename, DeletedAt: formatTime(t.DeletedAt),
	}))
}

// Get returns the tombstone or ErrNotFound.
func (TombstonesRepository) Get(ctx context.Context, db queries.DBTX, ownerID, sha string) (Tombstone, error) {
	r, err := queries.New(db).GetTombstone(ctx, queries.GetTombstoneParams{OwnerID: ownerID, Sha256: sha})
	if err != nil {
		return Tombstone{}, mapErr(err)
	}
	return tombstoneFromRow(r)
}

// ListBySHAs returns the owner's tombstones for the given hashes.
func (TombstonesRepository) ListBySHAs(ctx context.Context, db queries.DBTX, ownerID string, shas []string) ([]Tombstone, error) {
	rows, err := queries.New(db).ListTombstonesBySHAs(ctx, queries.ListTombstonesBySHAsParams{OwnerID: ownerID, Shas: shas})
	if err != nil {
		return nil, err
	}
	return tombstonesFromRows(rows)
}

// Delete removes the tombstone and reports whether one existed.
func (TombstonesRepository) Delete(ctx context.Context, db queries.DBTX, ownerID, sha string) (bool, error) {
	n, err := queries.New(db).DeleteTombstone(ctx, queries.DeleteTombstoneParams{OwnerID: ownerID, Sha256: sha})
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// Page returns up to limit tombstones ordered by deleted_at descending then
// sha256 ascending, strictly after the (afterDeletedAt, afterSHA) cursor. A
// zero afterDeletedAt starts from the first page.
func (TombstonesRepository) Page(ctx context.Context, db queries.DBTX, ownerID string, afterDeletedAt time.Time, afterSHA string, limit int) ([]Tombstone, error) {
	after := ""
	if !afterDeletedAt.IsZero() {
		after = formatTime(afterDeletedAt)
	}
	rows, err := queries.New(db).PageTombstones(ctx, queries.PageTombstonesParams{
		OwnerID: ownerID, AfterDeletedAt: after, AfterSha: afterSHA, RowLimit: int64(limit),
	})
	if err != nil {
		return nil, err
	}
	return tombstonesFromRows(rows)
}
