package repository_test

import (
	"context"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func TestTombstones(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	repotest.SeedUser(t, s, "o1")
	repotest.SeedUser(t, s, "o2")
	r := repository.TombstonesRepository{}

	t0 := ts
	for _, tb := range []repository.Tombstone{
		{OwnerID: "o1", SHA256: "bbb", Filename: "b", DeletedAt: t0},
		{OwnerID: "o1", SHA256: "aaa", Filename: "a", DeletedAt: t0},
		{OwnerID: "o1", SHA256: "ccc", Filename: "c", DeletedAt: t0.Add(time.Hour)},
		{OwnerID: "o1", SHA256: "ddd", Filename: "d", DeletedAt: t0.Add(-time.Hour)},
		{OwnerID: "o2", SHA256: "zzz", Filename: "z", DeletedAt: t0},
	} {
		if err := r.Insert(ctx, s.W, tb); err != nil {
			t.Fatal(err)
		}
	}
	g, err := r.Get(ctx, s.R, "o1", "aaa")
	if err != nil || g.Filename != "a" || !g.DeletedAt.Equal(t0) {
		t.Fatalf("%+v %v", g, err)
	}
	if _, err := r.Get(ctx, s.R, "o2", "aaa"); err != repository.ErrNotFound {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
	by, err := r.ListBySHAs(ctx, s.R, "o1", []string{"aaa", "ccc", "zzz"})
	if err != nil || len(by) != 2 {
		t.Fatalf("ListBySHAs: %+v %v", by, err)
	}

	// deleted_at desc, sha asc: ccc, aaa, bbb, ddd
	want := []string{"ccc", "aaa", "bbb", "ddd"}
	p1, err := r.Page(ctx, s.R, "o1", time.Time{}, "", 2)
	if err != nil || len(p1) != 2 || p1[0].SHA256 != want[0] || p1[1].SHA256 != want[1] {
		t.Fatalf("page 1: %+v %v", p1, err)
	}
	p2, err := r.Page(ctx, s.R, "o1", p1[1].DeletedAt, p1[1].SHA256, 2)
	if err != nil || len(p2) != 2 || p2[0].SHA256 != want[2] || p2[1].SHA256 != want[3] {
		t.Fatalf("page 2: %+v %v", p2, err)
	}
	p3, _ := r.Page(ctx, s.R, "o1", p2[1].DeletedAt, p2[1].SHA256, 2)
	if len(p3) != 0 {
		t.Fatalf("page 3: %+v", p3)
	}

	ok, err := r.Delete(ctx, s.W, "o1", "aaa")
	if err != nil || !ok {
		t.Fatalf("Delete: %v %v", ok, err)
	}
	if ok, _ := r.Delete(ctx, s.W, "o1", "aaa"); ok {
		t.Fatal("second delete should report false")
	}
}
