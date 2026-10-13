package storage

import (
	"path/filepath"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

const forbidden = `/\:*?"<>|`

var reserved = map[string]bool{
	"CON": true, "PRN": true, "AUX": true, "NUL": true,
	"COM1": true, "COM2": true, "COM3": true, "COM4": true, "COM5": true,
	"COM6": true, "COM7": true, "COM8": true, "COM9": true,
	"LPT1": true, "LPT2": true, "LPT3": true, "LPT4": true, "LPT5": true,
	"LPT6": true, "LPT7": true, "LPT8": true, "LPT9": true,
}

func scrub(s string) string {
	return strings.Map(func(r rune) rune {
		if strings.ContainsRune(forbidden, r) || unicode.IsControl(r) {
			return '_'
		}
		return r
	}, s)
}

// SanitizeFilename makes name safe on every supported filesystem (S§6.3).
// The result is NFC, valid UTF-8, never empty ("file") and never contains
// / \ : * ? " < > | or control characters.
func SanitizeFilename(name string) string {
	s := strings.ToValidUTF8(name, "_")
	s = norm.NFC.String(s)
	s = scrub(s)
	s = norm.NFC.String(s)
	s = scrub(s)
	s = strings.TrimRight(s, ". ")
	if s == "" {
		return "file"
	}
	// Windows reserves the device name even when followed by an extension.
	stem := s
	if i := strings.IndexByte(stem, '.'); i >= 0 {
		stem = stem[:i]
	}
	if reserved[strings.ToUpper(strings.TrimRight(stem, " "))] {
		s = "_" + s
	}
	return s
}

// SplitExt splits at the last dot only; ext includes the dot. A name whose
// only dot is the leading one has no extension.
func SplitExt(name string) (stem, ext string) {
	i := strings.LastIndexByte(name, '.')
	if i <= 0 {
		return name, ""
	}
	return name[:i], name[i:]
}

// PathKey is the case- and normalisation-insensitive collision key for a relative path.
func PathKey(rel string) string {
	return strings.ToLower(norm.NFC.String(filepath.ToSlash(rel)))
}

// FitPath returns dir/stem+ext, trimming stem (on rune boundaries) so the
// result is shorter than max bytes. The extension is always kept.
func FitPath(dir, stem, ext string, max int) string {
	prefix := ""
	if dir != "" {
		prefix = dir + "/"
	}
	budget := max - 1 - len(prefix) - len(ext)
	if budget < 1 {
		budget = 1
	}
	for len(stem) > budget {
		_, size := utf8.DecodeLastRuneInString(stem)
		stem = stem[:len(stem)-size]
	}
	stem = strings.TrimRight(stem, ". ")
	if stem == "" {
		stem = "f"
	}
	return prefix + stem + ext
}
