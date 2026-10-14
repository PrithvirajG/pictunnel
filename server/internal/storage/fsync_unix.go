//go:build !windows

package storage

import (
	"errors"
	"os"
	"syscall"
)

// syncDir flushes directory metadata. Filesystems that cannot fsync a
// directory (some NAS/FUSE/SMB mounts report EINVAL, ENOTSUP or ENOSYS) are
// treated as success: the rename itself already happened.
func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return ignoreUnsupportedSync(d.Sync())
}

func ignoreUnsupportedSync(err error) error {
	if err == nil {
		return nil
	}
	for _, e := range []error{syscall.EINVAL, syscall.ENOTSUP, syscall.EOPNOTSUPP, syscall.ENOSYS} {
		if errors.Is(err, e) {
			return nil
		}
	}
	return err
}
