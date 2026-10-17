package repository_test

import (
	"context"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func TestRefreshTokens(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	uid := repotest.SeedUser(t, s, "u1")
	did := repotest.SeedDevice(t, s, uid, "d1")
	r := repository.RefreshTokensRepository{}

	now := time.Date(2026, 5, 1, 0, 0, 0, 123_000_000, time.UTC)
	mk := func(h, fam string, exp time.Time) repository.RefreshToken {
		return repository.RefreshToken{Hash: h, DeviceID: did, FamilyID: fam, State: "active", IssuedAt: now, ExpiresAt: exp}
	}
	for _, rt := range []repository.RefreshToken{
		mk("a", "f1", now.Add(time.Hour)), mk("b", "f1", now.Add(time.Hour)), mk("c", "f2", now.Add(-time.Hour)),
	} {
		if err := r.Insert(ctx, s.W, rt); err != nil {
			t.Fatal(err)
		}
	}
	got, err := r.Get(ctx, s.R, "a")
	if err != nil || !got.IssuedAt.Equal(now) || got.RotatedAt != nil || got.State != "active" {
		t.Fatalf("%+v %v", got, err)
	}
	ok, err := r.MarkRotated(ctx, s.W, "a", now)
	if err != nil || !ok {
		t.Fatalf("first rotate: %v %v", ok, err)
	}
	ok, err = r.MarkRotated(ctx, s.W, "a", now)
	if err != nil || ok {
		t.Fatalf("second rotate must be false: %v %v", ok, err)
	}
	got, _ = r.Get(ctx, s.R, "a")
	if got.State != "rotated" || got.RotatedAt == nil || !got.RotatedAt.Equal(now) {
		t.Fatalf("%+v", got)
	}
	if err := r.RevokeFamily(ctx, s.W, "f1"); err != nil {
		t.Fatal(err)
	}
	b, _ := r.Get(ctx, s.R, "b")
	if b.State != "revoked" {
		t.Fatalf("family not revoked: %+v", b)
	}
	if err := r.RevokeByDevice(ctx, s.W, did); err != nil {
		t.Fatal(err)
	}
	c, _ := r.Get(ctx, s.R, "c")
	if c.State != "revoked" {
		t.Fatalf("device not revoked: %+v", c)
	}
	n, err := r.DeleteExpired(ctx, s.W, now)
	if err != nil || n != 1 {
		t.Fatalf("DeleteExpired n=%d %v", n, err)
	}
}
