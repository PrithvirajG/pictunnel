package apperr

import "time"

// RateLimited asks the client to wait retryAfter.
func RateLimited(retryAfter time.Duration) *Error {
	return newErr("rate_limited", "Rate limited", "Too many requests.").
		header("Retry-After", retryAfterSeconds(retryAfter))
}

// Internal is an unexpected server failure.
func Internal() *Error { return newErr("internal", "Internal error", "") }

// ServerUnavailable means the server is temporarily unable to serve.
func ServerUnavailable(retryAfter time.Duration) *Error {
	return newErr("server_unavailable", "Server unavailable", "").
		header("Retry-After", retryAfterSeconds(retryAfter))
}
