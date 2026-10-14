package storage

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
)

const ptpartSuffix = ".ptpart"

// PtpartSuffix is appended to a destination while a cross-volume copy is in
// flight; recovery sweeps stray files with this suffix.
const PtpartSuffix = ptpartSuffix

// errNotSameDevice is Windows ERROR_NOT_SAME_DEVICE.
const errNotSameDevice = syscall.Errno(17)

func isCrossDevice(err error) bool {
	var le *os.LinkError
	if !errors.As(err, &le) {
		return false
	}
	if errors.Is(le.Err, syscall.EXDEV) {
		return true
	}
	var en syscall.Errno
	return runtime.GOOS == "windows" && errors.As(le.Err, &en) && en == errNotSameDevice
}

// CommitHooks are crash-test failpoints inside Commit. A non-nil error from a
// hook aborts Commit immediately with that error and no cleanup, like a crash.
type CommitHooks struct {
	// AfterCopy runs exactly once, when the bytes are durable at the
	// destination volume: across volumes after the fsynced copy to
	// dest+".ptpart" (before its rename); on the same volume the rename is
	// the copy, so it runs right after the rename (dest already exists).
	AfterCopy func() error
	// AfterRename runs once dest exists and its directory is synced, before
	// staging is removed (cross volume).
	AfterRename func() error
}

func (h *CommitHooks) afterCopy() error {
	if h == nil || h.AfterCopy == nil {
		return nil
	}
	return h.AfterCopy()
}

func (h *CommitHooks) afterRename() error {
	if h == nil || h.AfterRename == nil {
		return nil
	}
	return h.AfterRename()
}

// Commit durably moves staging to dest (S§6.2 step 3). Same volume:
// fsync(staging), rename, fsync(dir). Cross volume: copy to dest+".ptpart",
// fsync, rename, fsync(dir), remove staging.
//
// Commit can fail after dest is already durable (directory sync or staging
// removal failing); callers must check dest before treating an error as a
// failed move.
func Commit(fs FS, staging, dest string) error { return CommitWithHooks(fs, staging, dest, nil) }

// CommitWithHooks is Commit with crash-test hooks; h may be nil.
func CommitWithHooks(fs FS, staging, dest string, h *CommitHooks) error {
	dir := filepath.Dir(dest)
	if err := fs.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	f, err := fs.OpenFile(staging, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	err = fs.Rename(staging, dest)
	if err == nil {
		if err := fs.SyncDir(dir); err != nil {
			return err
		}
		if err := h.afterCopy(); err != nil {
			return err
		}
		return h.afterRename()
	}
	if !isCrossDevice(err) {
		return err
	}
	return copyCommit(fs, staging, dest, dir, h)
}

// hookError marks an error returned by a hook so deferred cleanup is skipped.
type hookError struct{ err error }

func (e *hookError) Error() string { return e.err.Error() }
func (e *hookError) Unwrap() error { return e.err }

func copyCommit(fs FS, staging, dest, dir string, h *CommitHooks) (err error) {
	part := dest + ptpartSuffix
	src, err := fs.Open(staging)
	if err != nil {
		return err
	}
	defer src.Close()
	dst, err := fs.Create(part)
	if err != nil {
		return err
	}
	closed := false
	defer func() {
		var he *hookError
		if errors.As(err, &he) {
			if !closed {
				dst.Close()
			}
			err = he.err
			return
		}
		if err != nil {
			if !closed {
				dst.Close()
			}
			_ = fs.Remove(part)
		}
	}()
	if _, err = io.Copy(dst, src); err != nil {
		return err
	}
	if err = dst.Sync(); err != nil {
		return err
	}
	closed = true
	if err = dst.Close(); err != nil {
		return err
	}
	if err = fs.SyncDir(dir); err != nil {
		return err
	}
	if herr := h.afterCopy(); herr != nil {
		return &hookError{herr}
	}
	if err = fs.Rename(part, dest); err != nil {
		return err
	}
	if err = fs.SyncDir(dir); err != nil {
		return err
	}
	if herr := h.afterRename(); herr != nil {
		return &hookError{herr}
	}
	src.Close() // release the handle so Windows can delete it
	return fs.Remove(staging)
}
