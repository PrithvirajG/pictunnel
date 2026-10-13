package storage_test

import (
	"strings"
	"testing"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"

	"github.com/PrithvirajG/pictunnel/server/internal/storage"
)

func TestSanitizeFilename(t *testing.T) {
	cases := []struct{ in, want string }{
		{`a/b.jpg`, `a_b.jpg`},
		{`a\b.jpg`, `a_b.jpg`},
		{`a:b*?.jpg`, `a_b__.jpg`},
		{`CON.jpg`, `_CON.jpg`},
		{`com1.txt`, `_com1.txt`},
		{`name. `, `name`},
		{"\x00x.jpg", `_x.jpg`},
		{``, `file`},
		{"é.jpg", "é.jpg"},
		{`Photo 🙂.JPG`, `Photo 🙂.JPG`},
		{`..`, `file`},
		{`console.jpg`, `console.jpg`},
		{`NUL`, `_NUL`},
	}
	for _, c := range cases {
		if got := storage.SanitizeFilename(c.in); got != c.want {
			t.Errorf("SanitizeFilename(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSplitExt(t *testing.T) {
	for _, c := range []struct{ in, stem, ext string }{
		{"x.tar.gz", "x.tar", ".gz"}, {"a.jpg", "a", ".jpg"}, {"noext", "noext", ""}, {".hidden", ".hidden", ""},
	} {
		s, e := storage.SplitExt(c.in)
		if s != c.stem || e != c.ext {
			t.Errorf("SplitExt(%q) = %q,%q", c.in, s, e)
		}
	}
}

func TestFitPath(t *testing.T) {
	stem := strings.Repeat("é", 150) // 300 bytes
	p := storage.FitPath("2024/05", stem, ".jpg", 240)
	if len(p) >= 240 {
		t.Fatalf("len %d", len(p))
	}
	if !strings.HasSuffix(p, ".jpg") || !utf8.ValidString(p) || !strings.HasPrefix(p, "2024/05/é") {
		t.Fatalf("bad path %q", p)
	}
}

func TestPathKeyCaseAndNFC(t *testing.T) {
	a := storage.PathKey("2024\\05\\É.JPG")
	b := storage.PathKey("2024/05/é.jpg")
	if a != b {
		t.Fatalf("%q != %q", a, b)
	}
}

func FuzzSanitizeFilename(f *testing.F) {
	for _, s := range []string{"", "a/b", "CON.jpg", "é", "\xff\xfe", "x. ", ";", "a̸"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, in string) {
		out := storage.SanitizeFilename(in)
		if out == "" {
			t.Fatal("empty")
		}
		if strings.ContainsAny(out, `/\:*?"<>|`) {
			t.Fatalf("forbidden char in %q", out)
		}
		if !utf8.ValidString(out) {
			t.Fatalf("invalid utf8 %q", out)
		}
		if !norm.NFC.IsNormalString(out) {
			t.Fatalf("not NFC %q", out)
		}
		if storage.SanitizeFilename(out) != out {
			t.Fatalf("not idempotent %q -> %q", out, storage.SanitizeFilename(out))
		}
	})
}
