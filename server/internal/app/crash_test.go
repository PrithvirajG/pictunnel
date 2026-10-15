package app_test

import (
	"context"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/app"
	"github.com/PrithvirajG/pictunnel/server/internal/clock/clocktest"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
)

// crashPoints are the S§11.4 matrix rows: the finalize journal and the two
// mid-PATCH points of the tus append path.
var crashPoints = []string{
	service.FPBeforeTx1, service.FPAfterTx1, service.FPAfterCopy, service.FPAfterRename, service.FPAfterTx2,
	service.FPAppendAfterFsync, service.FPAppendBeforeCommit,
}

func crashDirs(t *testing.T) (dataDir, libDir string) {
	root := t.TempDir()
	dataDir = filepath.Join(root, "data")
	return dataDir, filepath.Join(dataDir, "library")
}

func mustNew(t *testing.T, o app.Options) *app.App {
	t.Helper()
	a, err := app.New(context.Background(), o)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = a.Close() })
	return a
}

// serveTLS serves the app's HTTPS handler on a real TLS listener.
func serveTLS(t *testing.T, a *app.App) *httptest.Server {
	t.Helper()
	srv := httptest.NewUnstartedServer(a.Handler())
	srv.TLS = a.TLSConfig()
	srv.StartTLS()
	t.Cleanup(srv.Close)
	return srv
}

// TestCrashMatrix is the in-process harness of S§11.4: for each failpoint,
// on the same volume and across volumes, the first upload over HTTPS is
// aborted at that point with no cleanup; the app is discarded and booted
// again on the same dirs (recovery, run twice: the state must not change);
// the client's convergence loop must then end with exactly one correct
// asset and nothing left over.
func TestCrashMatrix(t *testing.T) {
	content := crashPayload()
	for _, cross := range []bool{false, true} {
		for _, fp := range crashPoints {
			name := "same/" + fp
			if cross {
				name = "cross/" + fp
			}
			t.Run(name, func(t *testing.T) {
				t.Parallel()
				crashInProcess(t, fp, cross, content)
			})
		}
	}
}

func crashInProcess(t *testing.T, point string, cross bool, content []byte) {
	dataDir, libDir := crashDirs(t)
	o := crashOptions(dataDir, libDir, cross)
	o.Clock = clocktest.NewFake(t0)
	trip := &tripAt{name: point, hit: failpointHit(point)}
	o.Failpoints = trip

	// 1. The first attempt dies at the failpoint.
	a := mustNew(t, o)
	access := seedUser(t, a)
	srv := serveTLS(t, a)
	c := newSyncClient(t, srv.URL, a.CACertPEM(), access, content)
	err := c.crashUpload()
	if !trip.tripped.Load() {
		t.Fatalf("failpoint %s never hit (upload err %v)", point, err)
	}
	if err == nil {
		t.Fatal("upload succeeded through the failpoint")
	}
	// 2. Discard the app: no cleanup beyond closing the database.
	c.close()
	srv.Close()
	if err := a.Close(); err != nil {
		t.Fatal(err)
	}

	// Recovery runs at every boot; a second run changes nothing.
	o.Failpoints = nil
	b := mustNew(t, o)
	first := recoveryState(t, b)
	if err := b.Close(); err != nil {
		t.Fatal(err)
	}
	b = mustNew(t, o)
	if second := recoveryState(t, b); second != first {
		t.Fatalf("recovery is not idempotent:\nafter first boot:\n%s\nafter second boot:\n%s", first, second)
	}

	// When recovery itself completed the asset, its tx2 linked the source
	// (the client's check would add the link anyway, so look before it).
	if ids := queryStrings(t, b, `SELECT id FROM assets`); len(ids) == 1 {
		if src := queryStrings(t, b, `SELECT local_id, asset_id FROM asset_sources`); len(src) != 1 || src[0] != crashLocalID+"|"+ids[0] {
			t.Fatalf("asset_sources after recovery: %v", src)
		}
	}

	// 3–4. The client converges on exactly one correct asset.
	srv = serveTLS(t, b)
	c = newSyncClient(t, srv.URL, b.CACertPEM(), access, content)
	id := c.converge()
	assertConverged(t, b, id, content, true)
	c.close()
	srv.Close()
	if err := b.Close(); err != nil {
		t.Fatal(err)
	}

	// 5. Recovery after convergence is a no-op as well.
	b = mustNew(t, o)
	assertConverged(t, b, id, content, true)
}

// TestCrashProcessKill is the real-process harness of S§11.4: the test
// binary re-executes itself as a child server whose failpoint calls
// os.Exit(137). The parent uploads payload A over HTTPS (trusting
// <data>/tls/ca.crt), waits for the child to die, starts a fresh child on
// the same dirs and converges. Nothing in memory, no defer and no deferred
// cleanup survives, so this checks the fsync, rename and transaction
// durability claims.
func TestCrashProcessKill(t *testing.T) {
	if testing.Short() {
		t.Skip("process-kill crash test skipped with -short")
	}
	content := crashPayload()
	cases := []struct {
		fp    string
		cross bool
	}{
		{service.FPAfterTx1, false},
		{service.FPAfterRename, false},
		{service.FPAfterRename, true},
		{service.FPAppendBeforeCommit, false},
	}
	for _, tc := range cases {
		name := "same/" + tc.fp
		if tc.cross {
			name = "cross/" + tc.fp
		}
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			dataDir, libDir := crashDirs(t)
			o := crashOptions(dataDir, libDir, tc.cross)

			// Seed the user and a device token (real clock, like the child).
			a := mustNew(t, o)
			access := seedUser(t, a)
			if err := a.Close(); err != nil {
				t.Fatal(err)
			}
			ca := readFile(t, filepath.Join(dataDir, "tls", "ca.crt"))

			p := startChild(t, dataDir, libDir, tc.fp, tc.cross)
			c := newSyncClient(t, "https://"+p.addr, ca, access, content)
			err := c.crashUpload()
			if code := p.wait(t); code != crashExitCode {
				t.Fatalf("child exit code %d (upload err %v), want %d\n%s", code, err, crashExitCode, p.stderr)
			}
			if err == nil {
				t.Fatal("upload succeeded through the failpoint")
			}
			c.close()

			p = startChild(t, dataDir, libDir, "", tc.cross)
			c = newSyncClient(t, "https://"+p.addr, ca, access, content)
			id := c.converge()
			c.close()
			p.stop(t)

			b := mustNew(t, o)
			assertConverged(t, b, id, content, false)
		})
	}
}
