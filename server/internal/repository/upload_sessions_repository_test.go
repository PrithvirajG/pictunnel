package repository_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func newSession(id, owner, sha string) repository.UploadSession {
	return repository.UploadSession{
		ID: id, OwnerID: owner, DeviceID: "d1", SHA256: sha, Length: 1000, State: "receiving",
		MetaJSON: "{}", StagingPath: "staging/" + id, DestPath: "",
		CreatedAt: ts, UpdatedAt: ts, ExpiresAt: ts.Add(24 * time.Hour),
	}
}

func TestUploadSessionsLifecycle(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	repotest.SeedUser(t, s, "o1")
	repotest.SeedDevice(t, s, "o1", "d1")
	ar := repository.AssetsRepository{}
	if err := ar.Insert(ctx, s.W, newAsset("a1", "o1", "x")); err != nil {
		t.Fatal(err)
	}
	r := repository.UploadSessionsRepository{}

	role, pair := "still", "pairsha"
	u1 := newSession("u1", "o1", "sha1")
	u1.PairRole, u1.PairSHA256 = &role, &pair
	for _, u := range []repository.UploadSession{u1, newSession("u2", "o1", "sha2"), newSession("u3", "o1", "sha3"), newSession("u4", "o1", "sha4")} {
		if err := r.Insert(ctx, s.W, u); err != nil {
			t.Fatal(err)
		}
	}
	if err := r.Insert(ctx, s.W, newSession("u5", "o1", "sha1")); !errors.Is(err, repository.ErrUniqueViolation) {
		t.Fatalf("second active session for same sha: want ErrUniqueViolation, got %v", err)
	}
	got, err := r.Get(ctx, s.R, "u1")
	if err != nil || *got.PairRole != "still" || got.Length != 1000 || !got.ExpiresAt.Equal(ts.Add(24*time.Hour)) || got.AssetCreated {
		t.Fatalf("%+v %v", got, err)
	}
	if _, err := r.Get(ctx, s.R, "zzz"); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}

	later := ts.Add(time.Minute)
	if err := r.UpdateOffset(ctx, s.W, "u1", 500, later, later.Add(24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	got, _ = r.Get(ctx, s.R, "u1")
	if got.Offset != 500 || !got.UpdatedAt.Equal(later) || !got.ExpiresAt.Equal(later.Add(24*time.Hour)) {
		t.Fatalf("%+v", got)
	}

	if err := r.SetFinalizing(ctx, s.W, "u2", "lib/dest.jpg", later); err != nil {
		t.Fatal(err)
	}
	g, err := r.GetActive(ctx, s.R, "o1", "sha2")
	if err != nil || g.State != "finalizing" || g.DestPath != "lib/dest.jpg" {
		t.Fatalf("finalizing is active: %+v %v", g, err)
	}
	if err := r.SetDone(ctx, s.W, "u2", "a1", true, later); err != nil {
		t.Fatal(err)
	}
	if _, err := r.GetActive(ctx, s.R, "o1", "sha2"); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("done must not be active, got %v", err)
	}
	d, _ := r.Get(ctx, s.R, "u2")
	if d.State != "done" || d.AssetID == nil || *d.AssetID != "a1" || !d.AssetCreated {
		t.Fatalf("%+v", d)
	}
	if err := r.SetFailed(ctx, s.W, "u3", "checksum_mismatch", later); err != nil {
		t.Fatal(err)
	}
	if _, err := r.GetActive(ctx, s.R, "o1", "sha3"); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("failed must not be active, got %v", err)
	}
	f, _ := r.Get(ctx, s.R, "u3")
	if f.State != "failed" || f.FailureCode == nil || *f.FailureCode != "checksum_mismatch" {
		t.Fatalf("%+v", f)
	}
	// A new session for a failed sha is allowed again.
	if err := r.Insert(ctx, s.W, newSession("u6", "o1", "sha3")); err != nil {
		t.Fatalf("re-open after failure: %v", err)
	}

	act, err := r.ListActiveBySHAs(ctx, s.R, "o1", []string{"sha1", "sha2", "sha3", "sha4"})
	if err != nil || len(act) != 3 {
		t.Fatalf("ListActiveBySHAs: %+v %v", act, err)
	}
	sum, err := r.SumActiveLengths(ctx, s.R, "o1")
	if err != nil || sum != 3000 {
		t.Fatalf("SumActiveLengths: %d %v", sum, err)
	}
	byState, err := r.ListByState(ctx, s.R, "receiving")
	if err != nil || len(byState) != 3 {
		t.Fatalf("ListByState: %+v %v", byState, err)
	}

	exp, err := r.ListExpired(ctx, s.R, ts.Add(25*time.Hour))
	if err != nil || len(exp) != 3 { // u1 expiry is later+24h = ts+24h1m, still < ts+25h
		t.Fatalf("ListExpired: %+v %v", exp, err)
	}
	if exp, _ := r.ListExpired(ctx, s.R, ts); len(exp) != 0 {
		t.Fatalf("nothing expired yet: %+v", exp)
	}

	if err := r.SetFinalizing(ctx, s.W, "u4", "d", ts); err != nil {
		t.Fatal(err)
	}
	stuck, err := r.ListStuckFinalizing(ctx, s.R, ts.Add(time.Second))
	if err != nil || len(stuck) != 1 || stuck[0].ID != "u4" {
		t.Fatalf("ListStuckFinalizing: %+v %v", stuck, err)
	}

	// A cutoff at or before their updated_at keeps them (the cutoff must not
	// bind to a slice element).
	if n, err := r.DeleteOlderThan(ctx, s.W, []string{"done", "failed"}, later); err != nil || n != 0 {
		t.Fatalf("DeleteOlderThan before cutoff n=%d err=%v", n, err)
	}
	n, err := r.DeleteOlderThan(ctx, s.W, []string{"done", "failed"}, later.Add(time.Second))
	if err != nil || n != 2 {
		t.Fatalf("DeleteOlderThan n=%d err=%v", n, err)
	}
	if err := r.Delete(ctx, s.W, "u1"); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Get(ctx, s.R, "u1"); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("after Delete: %v", err)
	}
}

func TestUploadSessionsSetMetaJSON(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	repotest.SeedUser(t, s, "o1")
	repotest.SeedDevice(t, s, "o1", "d1")
	r := repository.UploadSessionsRepository{}
	if err := r.Insert(ctx, s.W, newSession("u1", "o1", "sha1")); err != nil {
		t.Fatal(err)
	}
	const meta = `{"filename":"a.jpg","joined_sources":[{"device_id":"d2"}]}`
	if err := r.SetMetaJSON(ctx, s.W, "u1", meta); err != nil {
		t.Fatal(err)
	}
	if got, err := r.Get(ctx, s.R, "u1"); err != nil || got.MetaJSON != meta {
		t.Fatalf("meta after SetMetaJSON: %q %v", got.MetaJSON, err)
	}
	if err := r.SetMetaJSON(ctx, s.W, "missing", meta); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("SetMetaJSON on a missing session: %v", err)
	}
}
