//go:build windows

package storage

import (
	"errors"

	"golang.org/x/sys/windows"
)

// syncDir is best effort on Windows: it opens the directory with
// FILE_FLAG_BACKUP_SEMANTICS and flushes it, ignoring access-denied.
func syncDir(dir string) error {
	p, err := windows.UTF16PtrFromString(dir)
	if err != nil {
		return err
	}
	h, err := windows.CreateFile(p, windows.GENERIC_WRITE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS, 0)
	if err != nil {
		if errors.Is(err, windows.ERROR_ACCESS_DENIED) {
			return nil
		}
		return err
	}
	defer windows.CloseHandle(h)
	if err := windows.FlushFileBuffers(h); err != nil && !errors.Is(err, windows.ERROR_ACCESS_DENIED) {
		return err
	}
	return nil
}
