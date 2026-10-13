package apperr

import "strconv"

// OffsetMismatch means the client offset differs from the stored one.
func OffsetMismatch(current int64) *Error {
	return newErr("offset_mismatch", "Offset mismatch", "Upload-Offset does not match the server offset.").
		header("Upload-Offset", strconv.FormatInt(current, 10))
}

// LengthMismatch means the final size differs from the declared length.
func LengthMismatch() *Error {
	return newErr("length_mismatch", "Length mismatch", "Received length differs from the declared length.")
}

// UploadLocked means another request holds the upload.
func UploadLocked() *Error {
	return newErr("upload_locked", "Upload locked", "Another request is writing this upload.")
}

// ChecksumMismatch means the content hash differs from the declared one.
func ChecksumMismatch() *Error {
	return newErr("checksum_mismatch", "Checksum mismatch", "Content checksum does not match.")
}

// FileTooLarge means the file exceeds the configured maximum.
func FileTooLarge(max int64) *Error {
	return newErr("file_too_large", "File too large", "File exceeds the maximum size of "+strconv.FormatInt(max, 10)+" bytes.").
		extra("max_file_bytes", max)
}

// QuotaExceeded means the storage quota is exhausted.
func QuotaExceeded() *Error { return newErr("quota_exceeded", "Quota exceeded", "") }

// InsufficientStorage means the server disk is full.
func InsufficientStorage() *Error {
	return newErr("insufficient_storage", "Insufficient storage", "The server has insufficient storage.")
}
