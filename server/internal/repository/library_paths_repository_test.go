package repository_test

import (
	"context"
	"errors"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func TestLibraryPaths(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	repotest.SeedUser(t, s, "o1")
	ar := repository.AssetsRepository{}
	if err := ar.Insert(ctx, s.W, newAsset("a1", "o1", "s1")); err != nil {
		t.Fatal(err)
	}
	r := repository.LibraryPathsRepository{}

	up := "up1"
	p := repository.LibraryPath{PathKey: "2026/06/img.jpg", Path: "2026/06/IMG.jpg", UserID: "o1", UploadID: &up}
	if err := r.Reserve(ctx, s.W, p); err != nil {
		t.Fatal(err)
	}
	if err := r.Reserve(ctx, s.W, p); !errors.Is(err, repository.ErrUniqueViolation) {
		t.Fatalf("collision: want ErrUniqueViolation, got %v", err)
	}
	if ok, err := r.Exists(ctx, s.R, p.PathKey); err != nil || !ok {
		t.Fatalf("Exists: %v %v", ok, err)
	}
	if ok, _ := r.Exists(ctx, s.R, "missing"); ok {
		t.Fatal("Exists(missing) = true")
	}
	if err := r.PointToAsset(ctx, s.W, p.PathKey, "a1"); err != nil {
		t.Fatal(err)
	}
	all, err := r.ListAll(ctx, s.R)
	if err != nil || len(all) != 1 || all[0].AssetID == nil || *all[0].AssetID != "a1" || all[0].Path != "2026/06/IMG.jpg" {
		t.Fatalf("ListAll: %+v %v", all, err)
	}
	if err := r.ReleaseByAsset(ctx, s.W, "a1"); err != nil {
		t.Fatal(err)
	}
	if ok, _ := r.Exists(ctx, s.R, p.PathKey); ok {
		t.Fatal("ReleaseByAsset did not free the path")
	}
	p2 := repository.LibraryPath{PathKey: "k2", Path: "K2", UserID: "o1", UploadID: &up}
	if err := r.Reserve(ctx, s.W, p2); err != nil {
		t.Fatal(err)
	}
	if err := r.ReleaseByUpload(ctx, s.W, "up1"); err != nil {
		t.Fatal(err)
	}
	if ok, _ := r.Exists(ctx, s.R, "k2"); ok {
		t.Fatal("ReleaseByUpload did not free the path")
	}
}
