package repository_test

import (
	"context"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func TestAccessTokens(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	uid := repotest.SeedUser(t, s, "u1")
	did := repotest.SeedDevice(t, s, uid, "d1")
	r := repository.AccessTokensRepository{}

	now := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	exp := now.Add(15*time.Minute + 7*time.Millisecond)
	if err := r.Insert(ctx, s.W, "old", did, now.Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := r.Insert(ctx, s.W, "new", did, exp); err != nil {
		t.Fatal(err)
	}
	got, err := r.Get(ctx, s.R, "new")
	if err != nil || got.DeviceID != did || !got.ExpiresAt.Equal(exp) {
		t.Fatalf("%+v %v", got, err)
	}
	n, err := r.DeleteExpired(ctx, s.W, now)
	if err != nil || n != 1 {
		t.Fatalf("DeleteExpired n=%d err=%v", n, err)
	}
	if err := r.DeleteByDevice(ctx, s.W, did); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Get(ctx, s.R, "new"); err != repository.ErrNotFound {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}
