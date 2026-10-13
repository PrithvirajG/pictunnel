package apperr

// Catalogue maps every problem code of sync-protocol section 8 to its HTTP status.
var Catalogue = map[string]int{
	"invalid_request":      400,
	"cursor_required":      400,
	"pairing_code_invalid": 400,
	"unauthorized":         401,
	"token_expired":        401,
	"refresh_token_reused": 401,
	"forbidden":            403,
	"not_found":            404,
	"not_ready":            404,
	"offset_mismatch":      409,
	"length_mismatch":      409,
	"tombstoned":           409,
	"pair_primary_missing": 409,
	"setup_already_done":   409,
	"cursor_expired":       410,
	"file_too_large":       413,
	"quota_exceeded":       413,
	"upload_locked":        423,
	"client_too_old":       426,
	"rate_limited":         429,
	"checksum_mismatch":    460,
	"internal":             500,
	"server_unavailable":   503,
	"insufficient_storage": 507,
}
