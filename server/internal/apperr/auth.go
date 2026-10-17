package apperr

// Unauthorized means credentials are missing or invalid.
func Unauthorized() *Error { return newErr("unauthorized", "Unauthorized", "") }

// TokenExpired means the access token has expired.
func TokenExpired() *Error { return newErr("token_expired", "Token expired", "") }

// RefreshTokenReused means a rotated refresh token was replayed.
func RefreshTokenReused() *Error {
	return newErr("refresh_token_reused", "Refresh token reused", "Re-pairing is required.")
}

// Forbidden means the caller lacks permission.
func Forbidden(detail string) *Error { return newErr("forbidden", "Forbidden", detail) }

// SetupAlreadyDone means first-run setup has completed.
func SetupAlreadyDone() *Error {
	return newErr("setup_already_done", "Setup already done", "Initial setup has already been completed.")
}
