package repository_test

import (
	"context"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func TestWebSessions(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	uid := repotest.SeedUser(t, s, "u1")
	did := repotest.SeedDevice(t, s, uid, "d1")
	r := repository.WebSessionsRepository{}

	now := time.Date(2026, 5, 1, 0, 0, 0, 500_000_000, time.UTC)
	ws := repository.WebSession{TokenHash: "t1", DeviceID: did, CSRFHash: "c", ExpiresAt: now.Add(-time.Hour), LastUsedAt: now.Add(-2 * time.Hour)}
	if err := r.Insert(ctx, s.W, ws); err != nil {
		t.Fatal(err)
	}
	got, err := r.Get(ctx, s.R, "t1")
	if err != nil || got.CSRFHash != "c" || !got.ExpiresAt.Equal(ws.ExpiresAt) {
		t.Fatalf("%+v %v", got, err)
	}
	newExp := now.Add(30 * 24 * time.Hour)
	if err := r.Touch(ctx, s.W, "t1", now, newExp); err != nil {
		t.Fatal(err)
	}
	got, _ = r.Get(ctx, s.R, "t1")
	if !got.LastUsedAt.Equal(now) || !got.ExpiresAt.Equal(newExp) {
		t.Fatalf("%+v", got)
	}
	_ = r.Insert(ctx, s.W, repository.WebSession{TokenHash: "t2", DeviceID: did, CSRFHash: "c", ExpiresAt: now.Add(-time.Minute), LastUsedAt: now})
	n, err := r.DeleteExpired(ctx, s.W, now)
	if err != nil || n != 1 {
		t.Fatalf("DeleteExpired n=%d %v", n, err)
	}
	if err := r.DeleteByDevice(ctx, s.W, did); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Get(ctx, s.R, "t1"); err != repository.ErrNotFound {
		t.Fatalf("got %v", err)
	}
}
