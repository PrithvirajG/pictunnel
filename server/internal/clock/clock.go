// Package clock abstracts time so domain code never calls time.Now directly.
package clock

import "time"

// Clock returns the current time, always in UTC.
type Clock interface{ Now() time.Time }

// Real is the production clock.
type Real struct{}

// Now returns time.Now().UTC().
func (Real) Now() time.Time { return time.Now().UTC() }
