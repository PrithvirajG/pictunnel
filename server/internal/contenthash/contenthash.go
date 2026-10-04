// Package contenthash computes PicTunnel content identities: SHA-256 as lowercase hex.
package contenthash

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
)

// bufferSize matches the 1 MiB read size used by the native engines.
const bufferSize = 1 << 20

// HashReader streams r through SHA-256 and returns the lowercase hex digest.
func HashReader(r io.Reader) (string, error) {
	h := sha256.New()
	if _, err := io.CopyBuffer(h, r, make([]byte, bufferSize)); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
