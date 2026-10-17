package service

import (
	"os"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/storage"
)

// TestCreateOnFreshDataDirProbesRealFreeSpace: the first upload on a fresh
// data dir (no staging dir yet) succeeds with the real free-space query,
// which needs an existing path (found by the tus-js-client interop test).
func TestCreateOnFreshDataDirProbesRealFreeSpace(t *testing.T) {
	e := newUenv(t)
	if err := os.RemoveAll(e.up.stagingDir()); err != nil {
		t.Fatal(err)
	}
	e.up.d.FreeSpace = storage.FreeSpace
	content := payload(2048, 1)
	v := e.create(t, content, false)
	if v.ID == "" || v.Offset != 0 || v.Length != int64(len(content)) {
		t.Fatalf("create on a fresh data dir: %+v", v)
	}
}
