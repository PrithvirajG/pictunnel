package apperr

import "net/http"

// InvalidRequest is a malformed or invalid request.
func InvalidRequest(detail string) *Error {
	return newErr("invalid_request", "Invalid request", detail)
}

// CursorRequired signals that the client must run a snapshot first.
func CursorRequired() *Error {
	return newErr("cursor_required", "Cursor required", "A sync cursor is required; run a snapshot.")
}

// TusPrecondition is the 412 returned for an unsupported Tus-Resumable version.
func TusPrecondition() *Error {
	e := newErr("invalid_request", "Unsupported tus version", "Tus-Resumable version is not supported.")
	e.Status = http.StatusPreconditionFailed
	return e.header("Tus-Version", "1.0.0")
}

// NotFound is a missing resource.
func NotFound() *Error { return newErr("not_found", "Not found", "") }

// NotReady means the resource exists but is not generated yet.
func NotReady() *Error {
	return newErr("not_ready", "Not ready", "The resource is not ready yet; retry later.")
}

// ClientTooOld rejects clients below the minimum version.
func ClientTooOld(min string) *Error {
	return newErr("client_too_old", "Client too old", "Update the app to version "+min+" or later.").
		extra("min_version", min)
}

// RangeNotSatisfiable is the 416 returned when a Range header cannot be
// satisfied (OpenAPI RangeNotSatisfiable, code invalid_request).
func RangeNotSatisfiable() *Error {
	e := newErr("invalid_request", "Range not satisfiable", "The requested range cannot be satisfied.")
	e.Status = http.StatusRequestedRangeNotSatisfiable
	return e
}
