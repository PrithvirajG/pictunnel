package service

// Fuzz targets of S§11.1 for the feed cursor, the opaque page token and
// the pairing-code parser. Seed corpora live in testdata/fuzz/<target>.

import (
	"regexp"
	"strings"
	"testing"
)

// FuzzDecodeCursor: DecodeCursor never panics, accepts exactly the strings
// EncodeCursor produces for a non-negative seq, and round-trips every such
// seq.
func FuzzDecodeCursor(f *testing.F) {
	for _, s := range []string{"c_0000000000000000", "c_000000000000002a", "c_7fffffffffffffff",
		"c_8000000000000000", "c_ffffffffffffffff", "c_000000000000002A", "c_00000000000002a", "C_000000000000002a",
		"", "c_", "c_-000000000000001", "c_+00000000000002a"} {
		f.Add(s, int64(len(s)))
	}
	f.Add("c_0000000000000001", int64(-1))
	f.Fuzz(func(t *testing.T, s string, n int64) {
		v, err := DecodeCursor(s)
		if err == nil {
			if v < 0 {
				t.Fatalf("DecodeCursor(%q) = %d", s, v)
			}
			if enc := EncodeCursor(v); enc != s {
				t.Fatalf("DecodeCursor(%q) = %d, which encodes as %q", s, v, enc)
			}
		}
		if n < 0 {
			return
		}
		enc := EncodeCursor(n)
		if got, err := DecodeCursor(enc); err != nil || got != n {
			t.Fatalf("round trip of %d via %q: %d, %v", n, enc, got, err)
		}
	})
}

// FuzzPageToken: decodeToken never panics; an accepted token has exactly
// n non-empty parts free of the separator, and those parts survive
// re-encoding. A snapshot page token is a token of two parts whose first is
// a cursor; the Snapshot parse path is exercised the same way.
func FuzzPageToken(f *testing.F) {
	f.Add(encodeToken(EncodeCursor(42), "01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f"), 2)
	f.Add(encodeToken("2026-10-03T12:00:00.000Z", strings.Repeat("ab", 32)), 2)
	f.Add(encodeToken("one"), 1)
	f.Add(encodeToken("a", "b", "c"), 3)
	f.Add("YXxi", 2)   // "a|b"
	f.Add("YXxiHQ", 2) // non-canonical trailing bits
	f.Add("fA", 2)     // "|"
	f.Add("YXw", 2)    // "a|"
	f.Add("!!!", 2)
	f.Add("", 0)
	f.Fuzz(func(t *testing.T, tok string, n int) {
		parts, ok := decodeToken(tok, n)
		if !ok {
			return
		}
		if len(parts) != n {
			t.Fatalf("decodeToken(%q, %d) = %d parts", tok, n, len(parts))
		}
		for _, p := range parts {
			if p == "" || strings.Contains(p, "|") {
				t.Fatalf("decodeToken(%q, %d): bad part %q", tok, n, p)
			}
		}
		again, ok := decodeToken(encodeToken(parts...), n)
		if !ok || strings.Join(again, "|") != strings.Join(parts, "|") {
			t.Fatalf("re-encoding %q: %q %v", parts, again, ok)
		}
		if n == 2 {
			if c, err := DecodeCursor(parts[0]); err == nil && EncodeCursor(c) != parts[0] {
				t.Fatalf("page token cursor %q decodes to %d", parts[0], c)
			}
		}
	})
}

var canonicalPairingCode = regexp.MustCompile(`^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{2}$`)

// FuzzPairingCode: normalizePairingCode never panics; an accepted code is
// canonical (the OpenAPI PairingCode pattern) and a fixed point; for ASCII
// input, case, separators and the Crockford aliases do not matter.
func FuzzPairingCode(f *testing.F) {
	for _, s := range []string{"ABCD-EFGH-JK", "abcd efgh jk", "0123456789", "OIL0-1234-ZZ", "olio-ilol-io",
		"ABCD-EFGH-J", "ABCD-EFGH-JKM", "ABCD-EFGH-JU", "ABCD\tEFGH\tJK", "ÄBCD-EFGH-JK", "ıııı-ıııı-ıı", ""} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, in string) {
		out, ok := normalizePairingCode(in)
		if !ok {
			if out != "" {
				t.Fatalf("rejected %q with output %q", in, out)
			}
			return
		}
		if !canonicalPairingCode.MatchString(out) {
			t.Fatalf("normalizePairingCode(%q) = %q, not canonical", in, out)
		}
		if again, ok := normalizePairingCode(out); !ok || again != out {
			t.Fatalf("not a fixed point: %q → %q → %q %v", in, out, again, ok)
		}
		for _, variant := range []string{strings.ToLower(out), strings.ReplaceAll(out, "-", ""),
			strings.ReplaceAll(out, "-", " "), strings.NewReplacer("0", "o", "1", "l").Replace(out)} {
			if v, ok := normalizePairingCode(variant); !ok || v != out {
				t.Fatalf("variant %q of %q: %q %v", variant, out, v, ok)
			}
		}
		if isASCII(in) {
			if v, ok := normalizePairingCode(strings.ToLower(in)); !ok || v != out {
				t.Fatalf("lower-case %q: %q %v, want %q", in, v, ok, out)
			}
		}
	})
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] > 127 {
			return false
		}
	}
	return true
}
