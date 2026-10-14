// Package storagetest provides fault-injecting filesystems for tests.
package storagetest

import (
	"os"

	"github.com/PrithvirajG/pictunnel/server/internal/storage"
)

// FaultFS wraps an FS and lets tests inject Rename and Write failures.
type FaultFS struct {
	storage.FS
	// RenameErr, if non-nil, is called on every Rename; a non-nil result is
	// returned instead of renaming (e.g. a *os.LinkError wrapping EXDEV).
	RenameErr func(from, to string) error
	// WriteErr, if non-nil, is called on every Write to a file opened through
	// Create or OpenFile; a non-nil result fails the write.
	WriteErr func(name string) error
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

// Create implements storage.FS.
func (f *FaultFS) Create(name string) (storage.File, error) {
	return f.wrap(name)(f.FS.Create(name))
}

// OpenFile implements storage.FS.
func (f *FaultFS) OpenFile(name string, flag int, perm os.FileMode) (storage.File, error) {
	return f.wrap(name)(f.FS.OpenFile(name, flag, perm))
}

func (f *FaultFS) wrap(name string) func(storage.File, error) (storage.File, error) {
	return func(file storage.File, err error) (storage.File, error) {
		if err != nil || f.WriteErr == nil {
			return file, err
		}
		return &faultFile{File: file, name: name, fn: f.WriteErr}, nil
	}
}

type faultFile struct {
	storage.File
	name string
	fn   func(string) error
}

func (f *faultFile) Write(p []byte) (int, error) {
	if err := f.fn(f.name); err != nil {
		return 0, err
	}
	return f.File.Write(p)
}
