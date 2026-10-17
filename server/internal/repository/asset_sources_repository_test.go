package repository_test

import (
	"context"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func TestAssetSourcesUpsertList(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	repotest.SeedUser(t, s, "o1")
	repotest.SeedDevice(t, s, "o1", "d1")
	repotest.SeedDevice(t, s, "o1", "d2")
	ar := repository.AssetsRepository{}
	for _, id := range []string{"a1", "a2"} {
		if err := ar.Insert(ctx, s.W, newAsset(id, "o1", "s-"+id)); err != nil {
			t.Fatal(err)
		}
	}
	r := repository.AssetSourcesRepository{}
	if err := r.Upsert(ctx, s.W, "d1", "L1", "a1", ts); err != nil {
		t.Fatal(err)
	}
	if err := r.Upsert(ctx, s.W, "d2", "L9", "a1", ts); err != nil {
		t.Fatal(err)
	}
	// Re-upsert is idempotent and may repoint the asset.
	if err := r.Upsert(ctx, s.W, "d1", "L1", "a1", ts.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	list, err := r.ListByAsset(ctx, s.R, "a1")
	if err != nil || len(list) != 2 || list[0].DeviceID != "d1" || list[0].LocalID != "L1" || !list[0].CreatedAt.Equal(ts) {
		t.Fatalf("%+v %v", list, err)
	}
	if err := r.Upsert(ctx, s.W, "d1", "L1", "a2", ts); err != nil {
		t.Fatal(err)
	}
	list, _ = r.ListByAsset(ctx, s.R, "a1")
	if len(list) != 1 {
		t.Fatalf("repoint failed: %+v", list)
	}
}
