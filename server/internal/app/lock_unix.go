//go:build unix

package app

import (
	"os"

	"golang.org/x/sys/unix"
)

// tryLock takes an exclusive, non-blocking flock on f. The lock dies with
// the process.
func tryLock(f *os.File) error {
	return unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB)
}
