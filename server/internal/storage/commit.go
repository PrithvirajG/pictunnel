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

// PtpartSuffix is the extension of in-flight cross-volume copies. Stored
// names never end with it (SanitizeFilename), as defence in depth: the copies
// themselves live in a dedicated temp directory, never next to dest.
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
	// tmp (before its rename into dest); on the same volume the rename is
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
// fsync(staging), rename, fsync(dir). Cross volume: copy to tmp, fsync,
// fsync(tmp dir), rename into dest, fsync(dest dir), remove staging. tmp must
// be on the destination volume and in a directory that holds nothing but
// in-flight copies, so a partial copy can never share a name with a library
// file; it is only used when the plain rename reports a cross-device error.
//
// Commit can fail after dest is already durable (directory sync or staging
// removal failing); callers must check dest before treating an error as a
// failed move.
func Commit(fs FS, staging, dest, tmp string) error {
	return CommitWithHooks(fs, staging, dest, tmp, nil)
}

// CommitWithHooks is Commit with crash-test hooks; h may be nil.
func CommitWithHooks(fs FS, staging, dest, tmp string, h *CommitHooks) error {
	if tmp == "" || filepath.Clean(tmp) == filepath.Clean(dest) {
		return errors.New("storage: commit needs a distinct tmp path")
	}
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
	return copyCommit(fs, staging, dest, dir, tmp, h)
}

// hookError marks an error returned by a hook so deferred cleanup is skipped.
type hookError struct{ err error }

func (e *hookError) Error() string { return e.err.Error() }
func (e *hookError) Unwrap() error { return e.err }

func copyCommit(fs FS, staging, dest, dir, tmp string, h *CommitHooks) (err error) {
	part := tmp
	tmpDir := filepath.Dir(tmp)
	if err := fs.MkdirAll(tmpDir, 0o755); err != nil {
		return err
	}
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
	if err = fs.SyncDir(tmpDir); err != nil {
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
