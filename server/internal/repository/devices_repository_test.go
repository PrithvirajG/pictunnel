package repository_test

import (
	"context"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func TestDevicesLifecycle(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	uid := repotest.SeedUser(t, s, "u1")
	r := repository.DevicesRepository{}

	created := time.Date(2026, 1, 2, 3, 4, 5, 123_000_000, time.UTC)
	for _, id := range []string{"d1", "d2"} {
		d := repository.Device{ID: id, UserID: uid, Name: "n" + id, Platform: "ios", AppVersion: "1.0", CreatedAt: created, LastSeenAt: created}
		if err := r.Insert(ctx, s.W, d); err != nil {
			t.Fatal(err)
		}
	}
	d, err := r.Get(ctx, s.R, "d1")
	if err != nil || !d.CreatedAt.Equal(created) || d.RevokedAt != nil {
		t.Fatalf("%+v %v", d, err)
	}
	if err := r.Rename(ctx, s.W, "d1", "Phone"); err != nil {
		t.Fatal(err)
	}
	seen := created.Add(time.Hour)
	if err := r.TouchLastSeen(ctx, s.W, "d1", seen); err != nil {
		t.Fatal(err)
	}
	d, _ = r.Get(ctx, s.R, "d1")
	if d.Name != "Phone" || !d.LastSeenAt.Equal(seen) {
		t.Fatalf("%+v", d)
	}
	if err := r.Revoke(ctx, s.W, "d2", seen); err != nil {
		t.Fatal(err)
	}
	list, err := r.ListByUser(ctx, s.R, uid)
	if err != nil || len(list) != 1 || list[0].ID != "d1" {
		t.Fatalf("ListByUser should exclude revoked: %+v %v", list, err)
	}
	d2, _ := r.Get(ctx, s.R, "d2")
	if d2.RevokedAt == nil || !d2.RevokedAt.Equal(seen) {
		t.Fatalf("revoked_at: %+v", d2)
	}
}
