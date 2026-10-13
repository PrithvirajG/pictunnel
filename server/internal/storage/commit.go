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

// Commit durably moves staging to dest (S§6.2 step 3). Same volume:
// fsync(staging), rename, fsync(dir). Cross volume: copy to dest+".ptpart",
// fsync, rename, fsync(dir), remove staging.
func Commit(fs FS, staging, dest string) error {
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
		return fs.SyncDir(dir)
	}
	if !isCrossDevice(err) {
		return err
	}
	return copyCommit(fs, staging, dest, dir)
}

func copyCommit(fs FS, staging, dest, dir string) (err error) {
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
	defer func() {
		if err != nil {
			dst.Close()
			_ = fs.Remove(part)
		}
	}()
	if _, err = io.Copy(dst, src); err != nil {
		return err
	}
	if err = dst.Sync(); err != nil {
		return err
	}
	if err = dst.Close(); err != nil {
		return err
	}
	if err = fs.Rename(part, dest); err != nil {
		return err
	}
	if err = fs.SyncDir(dir); err != nil {
		return err
	}
	src.Close() // release the handle so Windows can delete it
	return fs.Remove(staging)
}
