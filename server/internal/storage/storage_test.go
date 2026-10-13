package storage_test

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/storage"
	"github.com/PrithvirajG/pictunnel/server/internal/storage/storagetest"
)

func writeFile(t *testing.T, p, s string) {
	t.Helper()
	if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestCommitSameVolume(t *testing.T) {
	d := t.TempDir()
	src := filepath.Join(d, "up", "a.part")
	os.MkdirAll(filepath.Dir(src), 0o755)
	writeFile(t, src, "hello")
	dest := filepath.Join(d, "lib", "2024", "a.jpg")
	if err := storage.Commit(storage.OS(), src, dest); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(dest)
	if err != nil || string(b) != "hello" {
		t.Fatalf("dest %q %v", b, err)
	}
	if _, err := os.Stat(src); !os.IsNotExist(err) {
		t.Fatal("staging remains")
	}
}

func TestCommitCrossVolume(t *testing.T) {
	d := t.TempDir()
	src := filepath.Join(d, "a.part")
	writeFile(t, src, strings.Repeat("xyz", 1000))
	dest := filepath.Join(d, "lib", "a.jpg")
	n := 0
	ffs := &storagetest.FaultFS{FS: storage.OS(), RenameErr: func(from, to string) error {
		n++
		if n == 1 {
			return &os.LinkError{Op: "rename", Old: from, New: to, Err: syscall.EXDEV}
		}
		return nil
	}}
	if err := storage.Commit(ffs, src, dest); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(dest)
	if string(b) != strings.Repeat("xyz", 1000) {
		t.Fatal("content mismatch")
	}
	if _, err := os.Stat(src); !os.IsNotExist(err) {
		t.Fatal("staging remains")
	}
	if _, err := os.Stat(dest + ".ptpart"); !os.IsNotExist(err) {
		t.Fatal(".ptpart remains")
	}
}

func TestFreeSpace(t *testing.T) {
	n, err := storage.FreeSpace(t.TempDir())
	if err != nil || n == 0 {
		t.Fatalf("%d %v", n, err)
	}
}
