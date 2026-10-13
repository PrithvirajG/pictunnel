package repository_test

import (
	"context"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func TestPairingCodes(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	uid := repotest.SeedUser(t, s, "u1")
	r := repository.PairingCodesRepository{}

	now := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)
	mk := func(h string, exp time.Time) repository.PairingCode {
		return repository.PairingCode{CodeHash: h, UserID: uid, CreatedAt: now.Add(-time.Minute), ExpiresAt: exp}
	}
	for _, c := range []repository.PairingCode{
		mk("ok", now.Add(5*time.Minute)), mk("expired", now.Add(-time.Second)), mk("inv", now.Add(5*time.Minute)), mk("old", now.Add(-time.Hour)),
	} {
		if err := r.Insert(ctx, s.W, c); err != nil {
			t.Fatal(err)
		}
	}
	got, err := r.Get(ctx, s.R, "ok")
	if err != nil || got.RedeemedAt != nil || !got.ExpiresAt.Equal(now.Add(5*time.Minute)) {
		t.Fatalf("%+v %v", got, err)
	}
	ok, err := r.MarkRedeemed(ctx, s.W, "ok", now)
	if err != nil || !ok {
		t.Fatalf("first redeem %v %v", ok, err)
	}
	if ok, _ = r.MarkRedeemed(ctx, s.W, "ok", now); ok {
		t.Fatal("second redeem must fail")
	}
	if ok, _ = r.MarkRedeemed(ctx, s.W, "expired", now); ok {
		t.Fatal("expired code must not redeem")
	}
	n, err := r.InvalidateOutstanding(ctx, s.W, now)
	if err != nil || n != 1 {
		t.Fatalf("InvalidateOutstanding n=%d %v", n, err)
	}
	if ok, _ = r.MarkRedeemed(ctx, s.W, "inv", now); ok {
		t.Fatal("invalidated code must not redeem")
	}
	got, _ = r.Get(ctx, s.R, "inv")
	if got.InvalidatedAt == nil {
		t.Fatal("invalidated_at not set")
	}
	n, err = r.DeleteExpired(ctx, s.W, now)
	if err != nil || n != 2 {
		t.Fatalf("DeleteExpired n=%d %v", n, err)
	}
}
