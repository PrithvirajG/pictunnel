package storage_test

import (
	"errors"
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
	if err := storage.Commit(storage.OS(), src, dest, tmpPath(d)); err != nil {
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
	if err := storage.Commit(ffs, src, dest, tmpPath(d)); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(dest)
	if string(b) != strings.Repeat("xyz", 1000) {
		t.Fatal("content mismatch")
	}
	if _, err := os.Stat(src); !os.IsNotExist(err) {
		t.Fatal("staging remains")
	}
	if _, err := os.Stat(tmpPath(d)); !os.IsNotExist(err) {
		t.Fatal(".ptpart remains")
	}
}

func TestFreeSpace(t *testing.T) {
	n, err := storage.FreeSpace(t.TempDir())
	if err != nil || n == 0 {
		t.Fatalf("%d %v", n, err)
	}
}

func TestCommitCrossVolumePtpartCleanupOnRenameFailure(t *testing.T) {
	d := t.TempDir()
	src := filepath.Join(d, "a.part")
	writeFile(t, src, "payload")
	dest := filepath.Join(d, "lib", "a.jpg")
	n := 0
	ffs := &storagetest.FaultFS{FS: storage.OS(), RenameErr: func(from, to string) error {
		n++
		if n == 1 {
			return &os.LinkError{Op: "rename", Old: from, New: to, Err: syscall.EXDEV}
		}
		return &os.LinkError{Op: "rename", Old: from, New: to, Err: syscall.EIO}
	}}
	if err := storage.Commit(ffs, src, dest, tmpPath(d)); err == nil {
		t.Fatal("Commit succeeded")
	}
	if _, err := os.Stat(tmpPath(d)); !os.IsNotExist(err) {
		t.Fatal(".ptpart left behind")
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatal("dest created")
	}
	if b, err := os.ReadFile(src); err != nil || string(b) != "payload" {
		t.Fatalf("staging damaged: %q %v", b, err)
	}
}

func TestCommitCrossVolumePtpartCleanupOnWriteFailure(t *testing.T) {
	d := t.TempDir()
	src := filepath.Join(d, "a.part")
	writeFile(t, src, strings.Repeat("z", 4096))
	dest := filepath.Join(d, "lib", "a.jpg")
	ffs := &storagetest.FaultFS{FS: storage.OS(),
		RenameErr: func(from, to string) error {
			return &os.LinkError{Op: "rename", Old: from, New: to, Err: syscall.EXDEV}
		},
		WriteErr: func(name string) error {
			if strings.HasSuffix(name, ".ptpart") {
				return syscall.ENOSPC
			}
			return nil
		},
	}
	if err := storage.Commit(ffs, src, dest, tmpPath(d)); err == nil {
		t.Fatal("Commit succeeded")
	}
	if _, err := os.Stat(tmpPath(d)); !os.IsNotExist(err) {
		t.Fatal(".ptpart left behind")
	}
	if _, err := os.Stat(src); err != nil {
		t.Fatal("staging removed")
	}
}

func TestCommitHooks(t *testing.T) {
	for _, cross := range []bool{false, true} {
		d := t.TempDir()
		src := filepath.Join(d, "a.part")
		writeFile(t, src, "x")
		dest := filepath.Join(d, "lib", "a.jpg")
		var fsys storage.FS = storage.OS()
		if cross {
			fsys = &storagetest.FaultFS{FS: storage.OS(), RenameErr: func(from, to string) error {
				if from == src {
					return &os.LinkError{Op: "rename", Old: from, New: to, Err: syscall.EXDEV}
				}
				return nil
			}}
		}
		var order []string
		boom := errors.New("boom")
		h := &storage.CommitHooks{
			AfterCopy: func() error {
				order = append(order, "copy")
				if _, err := os.Stat(dest); cross && !os.IsNotExist(err) {
					t.Error("dest exists at after_copy")
				}
				return nil
			},
			AfterRename: func() error {
				order = append(order, "rename")
				if _, err := os.Stat(dest); err != nil {
					t.Error("dest missing at after_rename")
				}
				return boom
			},
		}
		err := storage.CommitWithHooks(fsys, src, dest, tmpPath(d), h)
		if !errors.Is(err, boom) {
			t.Fatalf("cross=%v err = %v, want hook error", cross, err)
		}
		if strings.Join(order, ",") != "copy,rename" {
			t.Fatalf("cross=%v order %v", cross, order)
		}
		if cross {
			// A hook failure simulates a crash: staging is not removed.
			if _, err := os.Stat(src); err != nil {
				t.Fatal("staging removed after failing hook")
			}
		}
	}
}

func TestCommitAfterCopyHookLeavesPtpart(t *testing.T) {
	d := t.TempDir()
	src := filepath.Join(d, "a.part")
	writeFile(t, src, "x")
	dest := filepath.Join(d, "lib", "a.jpg")
	ffs := &storagetest.FaultFS{FS: storage.OS(), RenameErr: func(from, to string) error {
		if from == src {
			return &os.LinkError{Op: "rename", Old: from, New: to, Err: syscall.EXDEV}
		}
		return nil
	}}
	boom := errors.New("crash")
	err := storage.CommitWithHooks(ffs, src, dest, tmpPath(d), &storage.CommitHooks{AfterCopy: func() error { return boom }})
	if !errors.Is(err, boom) {
		t.Fatal(err)
	}
	// Like a crash, the copied .ptpart stays for recovery to sweep.
	if _, err := os.Stat(tmpPath(d)); err != nil {
		t.Fatal(".ptpart missing after simulated crash")
	}
}

// tmpPath is where cross-volume copies are staged in these tests: a
// dedicated directory beside the library, never next to dest.
func tmpPath(d string) string { return filepath.Join(d, "lib", ".pictunnel-tmp", "s1.ptpart") }

func TestCommitCrossVolumeUsesTmpPathOnly(t *testing.T) {
	d := t.TempDir()
	src := filepath.Join(d, "a.part")
	writeFile(t, src, "new")
	dest := filepath.Join(d, "lib", "a")
	// A library file that sits at dest+".ptpart" must never be touched.
	neighbour := dest + ".ptpart"
	os.MkdirAll(filepath.Dir(neighbour), 0o755)
	writeFile(t, neighbour, "precious")
	var renames []string
	ffs := &storagetest.FaultFS{FS: storage.OS(), RenameErr: func(from, to string) error {
		renames = append(renames, from+" -> "+to)
		if from == src {
			return &os.LinkError{Op: "rename", Old: from, New: to, Err: syscall.EXDEV}
		}
		return nil
	}}
	if err := storage.Commit(ffs, src, dest, tmpPath(d)); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(neighbour); string(b) != "precious" {
		t.Fatalf("neighbour = %q", b)
	}
	if b, _ := os.ReadFile(dest); string(b) != "new" {
		t.Fatalf("dest = %q", b)
	}
	if len(renames) != 2 || renames[1] != tmpPath(d)+" -> "+dest {
		t.Fatalf("renames %v", renames)
	}
	if _, err := os.Stat(tmpPath(d)); !os.IsNotExist(err) {
		t.Fatal("tmp copy remains")
	}
}
