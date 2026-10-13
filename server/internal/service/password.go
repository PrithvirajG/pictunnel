package service

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"strings"

	"golang.org/x/crypto/argon2"
)

type argon2Params struct {
	memory  uint32 // KiB
	time    uint32
	threads uint8
	keyLen  uint32
}

// defaultArgonParams are the S§4.1 production parameters: m=64 MiB, t=3, p=2.
var defaultArgonParams = argon2Params{memory: 64 * 1024, time: 3, threads: 2, keyLen: 32}

// argonParams is used for new hashes. Tests lower it to stay fast;
// verification always uses the parameters encoded in the stored hash.
var argonParams = defaultArgonParams

const argonSaltLen = 16

// Upper bounds accepted when verifying a stored hash, so a corrupt row cannot
// make a login allocate unbounded memory.
const (
	maxArgonMemory  = 1 << 20 // 1 GiB in KiB
	maxArgonTime    = 16
	maxArgonThreads = 16
)

var b64 = base64.RawStdEncoding

// hashPassword returns an argon2id PHC string:
// $argon2id$v=19$m=<m>,t=<t>,p=<p>$<b64 salt>$<b64 hash>.
func hashPassword(password string) (string, error) {
	p := argonParams
	salt := make([]byte, argonSaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("password salt: %w", err)
	}
	key := argon2.IDKey([]byte(password), salt, p.time, p.memory, p.threads, p.keyLen)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, p.memory, p.time, p.threads, b64.EncodeToString(salt), b64.EncodeToString(key)), nil
}

// verifyPassword reports whether password matches the PHC hash, comparing
// the derived keys in constant time. Malformed hashes never match.
func verifyPassword(phc, password string) bool {
	parts := strings.Split(phc, "$")
	if len(parts) != 6 || parts[0] != "" || parts[1] != "argon2id" || parts[2] != fmt.Sprintf("v=%d", argon2.Version) {
		return false
	}
	var m, t uint32
	var th uint8
	if n, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &m, &t, &th); err != nil || n != 3 ||
		fmt.Sprintf("m=%d,t=%d,p=%d", m, t, th) != parts[3] {
		return false
	}
	if m == 0 || m > maxArgonMemory || t == 0 || t > maxArgonTime || th == 0 || th > maxArgonThreads || m < 8*uint32(th) {
		return false
	}
	salt, err := b64.DecodeString(parts[4])
	if err != nil || len(salt) == 0 {
		return false
	}
	want, err := b64.DecodeString(parts[5])
	if err != nil || len(want) < 16 || len(want) > 64 {
		return false
	}
	got := argon2.IDKey([]byte(password), salt, t, m, th, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1
}
