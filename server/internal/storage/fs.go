// Package storage is the filesystem port used by uploads and the library:
// an FS abstraction, filename sanitising, durable commit and free-space probe.
// It imports no domain package.
package storage

import (
	"io"
	"os"
)

// File is the subset of *os.File the server needs.
type File interface {
	io.Reader
	io.Writer
	io.Seeker
	io.Closer
	Sync() error
	Truncate(size int64) error
	Stat() (os.FileInfo, error)
}

// FS is the filesystem port.
type FS interface {
	Create(name string) (File, error)
	OpenFile(name string, flag int, perm os.FileMode) (File, error)
	Open(name string) (File, error)
	Rename(from, to string) error
	Remove(name string) error
	RemoveAll(path string) error
	MkdirAll(path string, perm os.FileMode) error
	Stat(name string) (os.FileInfo, error)
	// SyncDir flushes directory metadata (best effort on Windows).
	SyncDir(dir string) error
	ReadDir(dir string) ([]os.DirEntry, error)
}

// FreeSpaceFunc reports free bytes available to the caller on the volume of path.
type FreeSpaceFunc func(path string) (uint64, error)
