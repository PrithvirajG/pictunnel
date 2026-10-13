package apperr

import "time"

// CursorExpired means the change cursor is older than retention.
func CursorExpired() *Error {
	return newErr("cursor_expired", "Cursor expired", "The cursor is too old; run a snapshot.")
}

// Tombstoned means the asset was deleted at deletedAt.
func Tombstoned(deletedAt time.Time) *Error {
	return newErr("tombstoned", "Tombstoned", "The asset was deleted.").
		extra("deleted_at", deletedAt.UTC().Format("2006-01-02T15:04:05.000Z"))
}

// PairPrimaryMissing means a pair secondary arrived before its primary.
func PairPrimaryMissing() *Error {
	return newErr("pair_primary_missing", "Pair primary missing", "Upload the primary still first.")
}
