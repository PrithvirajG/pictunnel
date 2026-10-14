//go:build !windows

package storage

import (
	"errors"
	"os"
	"syscall"
	"testing"
)

func TestIgnoreUnsupportedSync(t *testing.T) {
	for _, e := range []error{syscall.EINVAL, syscall.ENOTSUP, syscall.EOPNOTSUPP, syscall.ENOSYS} {
		if err := ignoreUnsupportedSync(&os.PathError{Op: "sync", Path: "/x", Err: e}); err != nil {
			t.Errorf("%v not ignored", e)
		}
	}
	if err := ignoreUnsupportedSync(&os.PathError{Op: "sync", Path: "/x", Err: syscall.EIO}); !errors.Is(err, syscall.EIO) {
		t.Errorf("EIO swallowed: %v", err)
	}
}
