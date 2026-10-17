package repository

import (
	"database/sql"
	"errors"

	"modernc.org/sqlite"
)

var (
	// ErrNotFound is returned by Get-style methods when no row matches.
	ErrNotFound = errors.New("repository: not found")
	// ErrUniqueViolation is returned when an insert violates a unique or
	// primary key constraint.
	ErrUniqueViolation = errors.New("repository: unique violation")
)

const (
	sqliteConstraintUnique     = 2067 // SQLITE_CONSTRAINT_UNIQUE
	sqliteConstraintPrimaryKey = 1555 // SQLITE_CONSTRAINT_PRIMARYKEY
)

// mapErr translates driver errors into the package sentinels.
func mapErr(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	var se *sqlite.Error
	if errors.As(err, &se) {
		if c := se.Code(); c == sqliteConstraintUnique || c == sqliteConstraintPrimaryKey {
			return ErrUniqueViolation
		}
	}
	return err
}

// requireRow maps a zero-rows-affected result to ErrNotFound.
func requireRow(n int64, err error) error {
	if err != nil {
		return mapErr(err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}
