// Package ids generates entity identifiers.
package ids

import "github.com/google/uuid"

// New returns a new UUIDv7 string (time-ordered).
func New() string { return uuid.Must(uuid.NewV7()).String() }
