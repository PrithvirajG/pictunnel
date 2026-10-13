package repository_test

import (
	"context"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func TestChangeLog(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	repotest.SeedUser(t, s, "o1")
	repotest.SeedUser(t, s, "o2")
	r := repository.ChangeLogRepository{}

	if h, err := r.Head(ctx, s.R); err != nil || h != 0 {
		t.Fatalf("empty head: %d %v", h, err)
	}
	var seqs []int64
	for i, a := range []string{"a1", "a1", "a2", "a3"} {
		owner := "o1"
		if a == "a3" {
			owner = "o2"
		}
		seq, err := r.Append(ctx, s.W, owner, "upsert", a, ts.Add(time.Duration(i)*time.Hour))
		if err != nil {
			t.Fatal(err)
		}
		if len(seqs) > 0 && seq <= seqs[len(seqs)-1] {
			t.Fatalf("seq not strictly increasing: %v then %d", seqs, seq)
		}
		seqs = append(seqs, seq)
	}
	if h, _ := r.Head(ctx, s.R); h != seqs[3] {
		t.Fatalf("head %d want %d", h, seqs[3])
	}

	// Compaction: keep only the newest entry for a1.
	n, err := r.DeleteForAsset(ctx, s.W, "a1", seqs[1])
	if err != nil || n != 1 {
		t.Fatalf("DeleteForAsset n=%d %v", n, err)
	}
	list, err := r.ListAfter(ctx, s.R, "o1", 0, 10)
	if err != nil || len(list) != 2 || list[0].Seq != seqs[1] || list[1].Seq != seqs[2] || list[0].Kind != "upsert" || list[0].AssetID != "a1" {
		t.Fatalf("ListAfter: %+v %v", list, err)
	}
	if !list[0].CreatedAt.Equal(ts.Add(time.Hour)) {
		t.Fatalf("created_at: %v", list[0].CreatedAt)
	}
	list, _ = r.ListAfter(ctx, s.R, "o1", seqs[1], 10)
	if len(list) != 1 || list[0].Seq != seqs[2] {
		t.Fatalf("cursor: %+v", list)
	}
	if list, _ := r.ListAfter(ctx, s.R, "o1", 0, 1); len(list) != 1 {
		t.Fatalf("limit: %+v", list)
	}

	// DeleteBefore reports the max seq it removed (a1@+1h and a2@+2h are before +3h).
	maxDel, cnt, err := r.DeleteBefore(ctx, s.W, ts.Add(3*time.Hour))
	if err != nil || maxDel != seqs[2] || cnt != 2 {
		t.Fatalf("DeleteBefore max=%d n=%d err=%v (seqs %v)", maxDel, cnt, err, seqs)
	}
	if maxDel, cnt, _ := r.DeleteBefore(ctx, s.W, ts); maxDel != 0 || cnt != 0 {
		t.Fatalf("nothing to delete: %d %d", maxDel, cnt)
	}

	// AUTOINCREMENT: deleting the newest row must not let its seq be reused.
	if _, _, err := r.DeleteBefore(ctx, s.W, ts.Add(100*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if h, _ := r.Head(ctx, s.R); h != seqs[3] {
		t.Fatalf("head after emptying: %d want %d", h, seqs[3])
	}
	next, err := r.Append(ctx, s.W, "o1", "upsert", "a9", ts)
	if err != nil || next <= seqs[3] {
		t.Fatalf("seq reused: next=%d last=%d err=%v", next, seqs[3], err)
	}
}
