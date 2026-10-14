package service

import (
	"io"

	"github.com/PrithvirajG/pictunnel/server/internal/media/probe"
)

// Failpoints lets crash tests abort the finalize journal and the tus append
// path at named points (S§11.4). It is nil in production. A non-nil error
// from Hit aborts the operation immediately with no cleanup, like a crash.
type Failpoints interface {
	Hit(name string) error
}

// Failpoint names.
const (
	FPBeforeTx1          = "before_tx1"
	FPAfterTx1           = "after_tx1"
	FPAfterCopy          = "after_copy"
	FPAfterRename        = "after_rename"
	FPAfterTx2           = "after_tx2"
	FPAppendAfterFsync   = "append_after_fsync"
	FPAppendBeforeCommit = "append_before_commit"
)

// failpointError marks an error raised by a failpoint so callers skip every
// recovery or cleanup step and return it as is.
type failpointError struct {
	name string
	err  error
}

func (e *failpointError) Error() string { return "failpoint " + e.name + ": " + e.err.Error() }
func (e *failpointError) Unwrap() error { return e.err }

// hitFailpoint returns fp's error for name wrapped as a failpointError, or
// nil when fp is nil or does not trip.
func hitFailpoint(fp Failpoints, name string) error {
	if fp != nil {
		if err := fp.Hit(name); err != nil {
			return &failpointError{name: name, err: err}
		}
	}
	return nil
}

// DateProbe reads an embedded capture date from the head of a file
// (probe.FastDate in production).
type DateProbe func(r io.ReaderAt, size int64, mime string) (probe.DateResult, bool)
