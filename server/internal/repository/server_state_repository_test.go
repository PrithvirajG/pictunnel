package repository_test

import (
	"context"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func TestServerStateGetSet(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	r := repository.ServerStateRepository{}

	if _, ok, err := r.Get(ctx, s.R, "k"); err != nil || ok {
		t.Fatalf("missing: ok=%v err=%v", ok, err)
	}
	if err := r.Set(ctx, s.W, "k", "v1"); err != nil {
		t.Fatal(err)
	}
	if err := r.Set(ctx, s.W, "k", "v2"); err != nil {
		t.Fatal(err)
	}
	v, ok, err := r.Get(ctx, s.R, "k")
	if err != nil || !ok || v != "v2" {
		t.Fatalf("got %q %v %v", v, ok, err)
	}
}
