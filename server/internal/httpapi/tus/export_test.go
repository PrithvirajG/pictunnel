package tus

import "time"

// SetIdleTimeout replaces the per-read body idle timeout for handlers built
// after the call; the returned func restores it.
func SetIdleTimeout(d time.Duration) (restore func()) {
	old := idleTimeout
	idleTimeout = d
	return func() { idleTimeout = old }
}
