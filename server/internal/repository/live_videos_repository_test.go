package repository_test

import (
	"context"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func TestLiveVideos(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	repotest.SeedUser(t, s, "o1")
	ar := repository.AssetsRepository{}
	r := repository.LiveVideosRepository{}
	for _, id := range []string{"a1", "a2", "a3"} {
		if err := ar.Insert(ctx, s.W, newAsset(id, "o1", "sha-"+id)); err != nil {
			t.Fatal(err)
		}
	}
	for _, id := range []string{"a1", "a2"} {
		lv := repository.LiveVideo{AssetID: id, OwnerID: "o1", SHA256: "lv-" + id, SizeBytes: 50, Mime: "video/quicktime", Filename: id + ".mov", OriginalPath: "x/" + id + ".mov", CreatedAt: ts}
		if err := r.Insert(ctx, s.W, lv); err != nil {
			t.Fatal(err)
		}
	}
	got, err := r.GetByAsset(ctx, s.R, "a1")
	if err != nil || got.SizeBytes != 50 || !got.CreatedAt.Equal(ts) {
		t.Fatalf("%+v %v", got, err)
	}
	if _, err := r.GetByAsset(ctx, s.R, "a3"); err != repository.ErrNotFound {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
	list, err := r.ListByAssets(ctx, s.R, []string{"a1", "a2", "a3"})
	if err != nil || len(list) != 2 {
		t.Fatalf("%+v %v", list, err)
	}
	sum, err := r.SumSizes(ctx, s.R, "o1")
	if err != nil || sum != 100 {
		t.Fatalf("sum %d %v", sum, err)
	}
}
