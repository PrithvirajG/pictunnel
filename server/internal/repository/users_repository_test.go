package repository_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func TestUsersRoundTripNocaseAndPassword(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	r := repository.UsersRepository{}

	quota := int64(1 << 40)
	dis := time.Date(2026, 3, 4, 5, 6, 7, 890_000_000, time.UTC)
	u := repository.User{
		ID: "u1", Username: "Alice", Slug: "alice", DisplayName: "Alice A", Role: "admin",
		PasswordHash: "h1", QuotaBytes: &quota,
		CreatedAt: time.Date(2026, 1, 2, 3, 4, 5, 678_000_000, time.UTC), DisabledAt: &dis,
	}
	if err := r.Insert(ctx, s.W, u); err != nil {
		t.Fatal(err)
	}
	got, err := r.GetByID(ctx, s.R, "u1")
	if err != nil {
		t.Fatal(err)
	}
	if got.Username != "Alice" || *got.QuotaBytes != quota || !got.CreatedAt.Equal(u.CreatedAt) || !got.DisabledAt.Equal(dis) {
		t.Fatalf("round trip mismatch: %+v", got)
	}
	got, err = r.GetByUsername(ctx, s.R, "ALICE")
	if err != nil || got.ID != "u1" {
		t.Fatalf("nocase: %+v %v", got, err)
	}
	if _, err := r.GetByID(ctx, s.R, "nope"); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
	dup := u
	dup.ID, dup.Slug, dup.Username = "u2", "alice2", "aLiCe"
	if err := r.Insert(ctx, s.W, dup); !errors.Is(err, repository.ErrUniqueViolation) {
		t.Fatalf("want unique violation, got %v", err)
	}
	if err := r.SetPasswordHash(ctx, s.W, "u1", "h2"); err != nil {
		t.Fatal(err)
	}
	got, _ = r.GetByID(ctx, s.R, "u1")
	if got.PasswordHash != "h2" {
		t.Fatal("hash not updated")
	}
	n, err := r.Count(ctx, s.R)
	if err != nil || n != 1 {
		t.Fatalf("count %d %v", n, err)
	}
	list, err := r.List(ctx, s.R)
	if err != nil || len(list) != 1 {
		t.Fatalf("list %v %v", list, err)
	}
}
