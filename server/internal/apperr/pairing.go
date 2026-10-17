package apperr

// PairingCodeInvalid means the pairing code is unknown, expired or used.
func PairingCodeInvalid() *Error {
	return newErr("pairing_code_invalid", "Pairing code invalid", "The pairing code is invalid or expired.")
}
