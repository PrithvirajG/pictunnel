package service

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"time"
)

// Token prefixes (P§6.1, S§4.2).
const (
	prefixAccess     = "pt_at_"
	prefixRefresh    = "pt_rt_"
	prefixWebSession = "pt_ws_"
)

// Token lifetimes (globals).
const (
	AccessTTL     = 15 * time.Minute
	RefreshTTL    = 90 * 24 * time.Hour
	RefreshGrace  = 30 * time.Second
	WebSessionTTL = 30 * 24 * time.Hour
)

// randomB64 returns n random bytes from crypto/rand as unpadded base64url.
func randomB64(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b) // crypto/rand.Read never fails (Go 1.24+)
	return base64.RawURLEncoding.EncodeToString(b)
}

// newToken returns prefix + 32 random bytes in base64url.
func newToken(prefix string) string { return prefix + randomB64(32) }

// hashToken is the stored form of a token: lowercase hex SHA-256 of the full
// string, prefix included.
func hashToken(tok string) string {
	sum := sha256.Sum256([]byte(tok))
	return hex.EncodeToString(sum[:])
}

// equalHashes compares two hex hashes in constant time.
func equalHashes(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

// deriveSuccessors computes the refresh successor pair per ADR 0012:
// rt' = pt_rt_ + b64url(HMAC-SHA256(k, "rt|"+rt)),
// at' = pt_at_ + b64url(HMAC-SHA256(k, "at|"+rt)).
func deriveSuccessors(secret []byte, rt string) (access, refresh string) {
	mac := func(label string) string {
		m := hmac.New(sha256.New, secret)
		m.Write([]byte(label + "|" + rt))
		return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
	}
	return prefixAccess + mac("at"), prefixRefresh + mac("rt")
}

// msNow truncates t to the millisecond precision stored in the database, so
// values returned to callers equal the values read back later.
func msNow(t time.Time) time.Time { return t.UTC().Truncate(time.Millisecond) }
