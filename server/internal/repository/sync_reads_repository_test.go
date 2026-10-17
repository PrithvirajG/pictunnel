package repository_test

import (
	"context"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func TestAssetsListByIDsAndPathReferenced(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	repotest.SeedUser(t, s, "o1")
	repotest.SeedUser(t, s, "o2")
	r := repository.AssetsRepository{}
	for _, a := range []repository.Asset{newAsset("a1", "o1", "s1"), newAsset("a2", "o1", "s2"), newAsset("a3", "o2", "s3")} {
		if err := r.Insert(ctx, s.W, a); err != nil {
			t.Fatal(err)
		}
	}
	got, err := r.ListByIDs(ctx, s.R, "o1", []string{"a2", "a3", "a1", "zz"})
	if err != nil || len(got) != 2 || got[0].ID != "a1" || got[1].ID != "a2" {
		t.Fatalf("ListByIDs must be owner scoped and ordered: %+v %v", got, err)
	}
	if got, err := r.ListByIDs(ctx, s.R, "o1", nil); err != nil || len(got) != 0 {
		t.Fatalf("empty ids: %+v %v", got, err)
	}
	for path, want := range map[string]bool{"2026/06/a1.jpg": true, "2026/06/A1.JPG": true, "2026/06/a9.jpg": false} {
		if ok, err := r.PathReferenced(ctx, s.R, path); err != nil || ok != want {
			t.Fatalf("PathReferenced(%q) = %v %v, want %v", path, ok, err, want)
		}
	}
}

func TestLiveVideosPathReferenced(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	repotest.SeedUser(t, s, "o1")
	if err := (repository.AssetsRepository{}).Insert(ctx, s.W, newAsset("a1", "o1", "s1")); err != nil {
		t.Fatal(err)
	}
	r := repository.LiveVideosRepository{}
	lv := repository.LiveVideo{AssetID: "a1", OwnerID: "o1", SHA256: "lv", SizeBytes: 5, Mime: "video/quicktime",
		Filename: "a1.mov", OriginalPath: "x/a1.MOV", CreatedAt: ts}
	if err := r.Insert(ctx, s.W, lv); err != nil {
		t.Fatal(err)
	}
	for path, want := range map[string]bool{"x/a1.mov": true, "x/a1.MOV": true, "x/a2.mov": false} {
		if ok, err := r.PathReferenced(ctx, s.R, path); err != nil || ok != want {
			t.Fatalf("PathReferenced(%q) = %v %v, want %v", path, ok, err, want)
		}
	}
}

func TestChangeLogAdvanceHead(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	repotest.SeedUser(t, s, "o1")
	r := repository.ChangeLogRepository{}
	// No sequence row yet: AdvanceHead creates it.
	if err := r.AdvanceHead(ctx, s.W, 3); err != nil {
		t.Fatal(err)
	}
	if h, _ := r.Head(ctx, s.R); h != 3 {
		t.Fatalf("head %d want 3", h)
	}
	seq, err := r.Append(ctx, s.W, "o1", "asset.upsert", "a1", ts)
	if err != nil || seq != 4 {
		t.Fatalf("append after advance: %d %v", seq, err)
	}
	// Never moves backwards.
	if err := r.AdvanceHead(ctx, s.W, 2); err != nil {
		t.Fatal(err)
	}
	if h, _ := r.Head(ctx, s.R); h != 4 {
		t.Fatalf("head %d want 4", h)
	}
	if err := r.AdvanceHead(ctx, s.W, 10); err != nil {
		t.Fatal(err)
	}
	if h, _ := r.Head(ctx, s.R); h != 10 {
		t.Fatalf("head %d want 10", h)
	}
}
