// Package storagetest provides fault-injecting filesystems for tests.
package storagetest

import "github.com/PrithvirajG/pictunnel/server/internal/storage"

// FaultFS wraps an FS and lets tests inject Rename failures.
type FaultFS struct {
	storage.FS
	// RenameErr, if non-nil, is called on every Rename; a non-nil result is
	// returned instead of renaming (e.g. a *os.LinkError wrapping EXDEV).
	RenameErr func(from, to string) error
}

// Rename implements storage.FS.
func (f *FaultFS) Rename(from, to string) error {
	if f.RenameErr != nil {
		if err := f.RenameErr(from, to); err != nil {
			return err
		}
	}
	return f.FS.Rename(from, to)
}
