package service

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
)

// TestPeekIgnoresTheLock: Peek reports the session while a writer holds its
// lock (it must not wait), and is owner scoped like every session read.
func TestPeekIgnoresTheLock(t *testing.T) {
	e := newUenv(t)
	content := payload(4096, 3)
	v := e.create(t, content, false)
	lk := e.up.locks.tryAcquire(v.ID)
	if lk == nil {
		t.Fatal("lock not free")
	}
	defer e.up.locks.release(lk, false)

	done := make(chan struct{})
	var got UploadView
	var err error
	go func() {
		got, err = e.up.Peek(ctx, e.p, v.ID)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Peek waited for the upload lock")
	}
	if err != nil || got.ID != v.ID || got.Length != int64(len(content)) || got.Offset != 0 {
		t.Fatalf("Peek: %+v %v", got, err)
	}
	other := e.p
	other.UserID = "someone-else"
	_, err = e.up.Peek(ctx, other, v.ID)
	wantUpCode(t, err, "not_found")
	_, err = e.up.Peek(ctx, e.p, "01928f40-0000-7000-8000-000000000000")
	wantUpCode(t, err, "not_found")
}

// TestCreateFreeSpaceProbeFailureIsInternal: a free-space query that
// fails is an internal error, not a silently passed check (S§6.5).
func TestCreateFreeSpaceProbeFailureIsInternal(t *testing.T) {
	e := newUenv(t)
	probeErr := errors.New("statfs: device gone")
	e.up.d.FreeSpace = func(string) (uint64, error) { return 0, probeErr }
	content := payload(1000, 9)
	_, err := e.up.Create(ctx, e.p, CreateInput{Length: int64(len(content)), Meta: metaFor(content, "a.jpg")})
	wantUpCode(t, err, "internal")
	if !errors.Is(err, probeErr) {
		t.Fatalf("cause lost: %v", err)
	}
	if _, gerr := e.up.d.Sessions.GetActive(ctx, e.st.R, e.owner, shaHex(content)); !errors.Is(gerr, repository.ErrNotFound) {
		t.Fatalf("a session was created despite the failed probe: %v", gerr)
	}
}

// TestCreateStagingDirUnusableIsInternal: when the staging directory cannot
// be created (a file is in its place), create fails with internal and the
// cause is kept for the log.
func TestCreateStagingDirUnusableIsInternal(t *testing.T) {
	e := newUenv(t)
	dir := e.up.stagingDir()
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dir, []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	e.up.d.FreeSpace = nil
	content := payload(1000, 5)
	_, err := e.up.Create(ctx, e.p, CreateInput{Length: int64(len(content)), Meta: metaFor(content, "a.jpg"), Body: bytes.NewReader(content)})
	wantUpCode(t, err, "internal")
}

// TestRevokeDeviceIdempotent: revoking twice keeps the first revocation
// time and writes one audit event; an unknown device is not_found.
func TestRevokeDeviceIdempotent(t *testing.T) {
	e := newEnv(t)
	bg := context.Background()
	_, d, tp := e.setupAlice(t)
	if err := e.auth.RevokeDevice(bg, e.st.W, d.ID); err != nil {
		t.Fatal(err)
	}
	first, err := repository.DevicesRepository{}.Get(bg, e.st.R, d.ID)
	if err != nil || first.RevokedAt == nil {
		t.Fatalf("not revoked: %+v %v", first, err)
	}
	e.clk.Advance(time.Hour)
	if err := e.auth.RevokeDevice(bg, e.st.W, d.ID); err != nil {
		t.Fatal(err)
	}
	again, err := repository.DevicesRepository{}.Get(bg, e.st.R, d.ID)
	if err != nil || again.RevokedAt == nil || !again.RevokedAt.Equal(*first.RevokedAt) {
		t.Fatalf("second revoke moved revoked_at: %v → %v (%v)", first.RevokedAt, again.RevokedAt, err)
	}
	evs, err := repository.AuditLogRepository{}.List(bg, e.st.R, 50)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, ev := range evs {
		if ev.Event == "device.revoked" {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("%d device.revoked events, want 1", n)
	}
	_, err = e.auth.AuthenticateBearer(bg, tp.AccessToken)
	wantCode(t, err, "unauthorized")
	_, err = e.auth.Refresh(bg, tp.RefreshToken)
	wantCode(t, err, "unauthorized")
	wantCode(t, e.auth.RevokeDevice(bg, e.st.W, "01928f40-0000-7000-8000-00000000dead"), "not_found")
}

// TestReadsSurfaceDatabaseFailures: with the database gone, the read paths
// of the sync services return an error that is not a domain code (a client
// must not be told "not found", "missing" or "cursor expired" for a server
// fault; the HTTP layer maps it to 500 internal).
func TestReadsSurfaceDatabaseFailures(t *testing.T) {
	e := newSenv(t)
	bg := context.Background()
	a := e.seed(t, e.alice, "x")
	if err := e.st.Close(); err != nil {
		t.Fatal(err)
	}
	calls := map[string]func() error{
		"assets.Get": func() error { _, err := e.assets.Get(bg, e.alice, a.ID); return err },
		"assets.OpenOriginal": func() error {
			_, _, err := e.assets.OpenOriginal(bg, e.alice, a.ID)
			return err
		},
		"check.Check": func() error {
			_, err := e.check.Check(bg, e.alice, []CheckItem{{SHA256: a.SHA256, SizeBytes: a.SizeBytes}})
			return err
		},
		"feed.Snapshot": func() error { _, _, _, _, err := e.feed.Snapshot(bg, e.alice, "", 10); return err },
		"feed.Changes": func() error {
			_, _, _, err := e.feed.Changes(bg, e.alice, EncodeCursor(a.UpdatedSeq), 10)
			return err
		},
	}
	for name, call := range calls {
		err := call()
		if err == nil {
			t.Errorf("%s: no error with the database closed", name)
			continue
		}
		if ae, ok := apperr.As(err); ok && ae.Code != "internal" {
			t.Errorf("%s: database failure reported as %s", name, ae.Code)
		}
	}
}

// TestAccountPathsFailClosed: with the database gone, setup and password
// reset fail with a non-domain error, no setup token is issued, and the
// setup-token check fails closed (a guard that cannot read its hash must
// not let anyone through).
func TestAccountPathsFailClosed(t *testing.T) {
	e := newEnv(t)
	bg := context.Background()
	tok, created, err := e.users.EnsureSetupToken(bg)
	if err != nil || !created {
		t.Fatalf("EnsureSetupToken: %v %v", created, err)
	}
	if !e.users.CheckSetupToken(bg, tok) {
		t.Fatal("fresh setup token rejected")
	}
	if err := e.st.Close(); err != nil {
		t.Fatal(err)
	}
	if e.users.CheckSetupToken(bg, tok) {
		t.Fatal("setup token accepted with the database closed")
	}
	if tok2, created, err := e.users.EnsureSetupToken(bg); err == nil || created || tok2 != "" {
		t.Fatalf("EnsureSetupToken with the database closed: %q %v %v", tok2, created, err)
	}
	for name, err := range map[string]error{
		"Setup":         func() error { _, err := e.users.Setup(bg, "alice", testPassword, "Alice"); return err }(),
		"ResetPassword": func() error { _, err := e.users.ResetPassword(bg, "alice"); return err }(),
	} {
		if err == nil {
			t.Errorf("%s: no error with the database closed", name)
		} else if ae, ok := apperr.As(err); ok && ae.Code != "internal" {
			t.Errorf("%s: database failure reported as %s", name, ae.Code)
		}
	}
}
