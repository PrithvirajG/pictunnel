package repository_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

func TestAssetsInsertUniqueAndRoundTrip(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	repotest.SeedUser(t, s, "o1")
	repotest.SeedUser(t, s, "o2")
	r := repository.AssetsRepository{}

	taken := time.Date(2025, 12, 25, 8, 30, 0, 123_000_000, time.UTC)
	off, w, h, dur := int64(-300), int64(4000), int64(3000), int64(1500)
	lat, lon := 12.5, -45.25
	sk, vc := "stack1", "h264"
	playable := true
	a := newAsset("a1", "o1", "sha1")
	a.TakenAt, a.TakenAtOffsetMinutes = &taken, &off
	a.Width, a.Height, a.DurationMs, a.Lat, a.Lon = &w, &h, &dur, &lat, &lon
	a.StackKey, a.VideoCodec, a.Playable = &sk, &vc, &playable
	a.ThumbnailsReady = true
	a.UpdatedSeq = 7
	if err := r.Insert(ctx, s.W, a); err != nil {
		t.Fatal(err)
	}
	got, err := r.Get(ctx, s.R, "o1", "a1")
	if err != nil {
		t.Fatal(err)
	}
	if !got.TakenAt.Equal(taken) || *got.TakenAtOffsetMinutes != -300 || *got.Lat != lat || !got.ThumbnailsReady ||
		*got.Playable != true || *got.StackKey != "stack1" || !got.CreatedAt.Equal(ts) || got.UpdatedSeq != 7 || got.TrashedAt != nil {
		t.Fatalf("round trip mismatch: %+v", got)
	}
	if _, err := r.Get(ctx, s.R, "o2", "a1"); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("Get must be owner scoped, got %v", err)
	}
	if g, err := r.GetByID(ctx, s.R, "a1"); err != nil || g.OwnerID != "o1" {
		t.Fatalf("GetByID: %+v %v", g, err)
	}
	dup := newAsset("a2", "o1", "sha1")
	if err := r.Insert(ctx, s.W, dup); !errors.Is(err, repository.ErrUniqueViolation) {
		t.Fatalf("same owner+sha: want ErrUniqueViolation, got %v", err)
	}
	other := newAsset("a3", "o2", "sha1")
	if err := r.Insert(ctx, s.W, other); err != nil {
		t.Fatalf("same sha other owner must be ok: %v", err)
	}
	if g, err := r.GetBySHA(ctx, s.R, "o2", "sha1"); err != nil || g.ID != "a3" {
		t.Fatalf("GetBySHA: %+v %v", g, err)
	}
}

func TestAssetsMutationsAndQueries(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	repotest.SeedUser(t, s, "o1")
	repotest.SeedUser(t, s, "o2")
	r := repository.AssetsRepository{}

	for _, a := range []repository.Asset{
		newAsset("a1", "o1", "s1"), newAsset("a2", "o1", "s2"), newAsset("a3", "o1", "s3"), newAsset("b1", "o2", "s1"),
	} {
		if err := r.Insert(ctx, s.W, a); err != nil {
			t.Fatal(err)
		}
	}
	list, err := r.ListBySHAs(ctx, s.R, "o1", []string{"s1", "s3", "nope"})
	if err != nil || len(list) != 2 || list[0].ID != "a1" || list[1].ID != "a3" {
		t.Fatalf("ListBySHAs: %+v %v", list, err)
	}
	if list, err := r.ListBySHAs(ctx, s.R, "o1", nil); err != nil || len(list) != 0 {
		t.Fatalf("empty ListBySHAs: %+v %v", list, err)
	}

	t1 := ts.Add(-48 * time.Hour)
	if err := r.SetState(ctx, s.W, "a1", "trashed", &t1, 11); err != nil {
		t.Fatal(err)
	}
	if err := r.SetState(ctx, s.W, "b1", "trashed", &ts, 12); err != nil {
		t.Fatal(err)
	}
	g, _ := r.GetByID(ctx, s.R, "a1")
	if g.State != "trashed" || g.TrashedAt == nil || !g.TrashedAt.Equal(t1) || g.UpdatedSeq != 11 {
		t.Fatalf("SetState: %+v", g)
	}
	tr, err := r.ListTrashed(ctx, s.R, "o1")
	if err != nil || len(tr) != 1 || tr[0].ID != "a1" {
		t.Fatalf("ListTrashed: %+v %v", tr, err)
	}
	cut := ts.Add(time.Hour)
	all, err := r.ListTrashedBefore(ctx, s.R, "", cut, 10)
	if err != nil || len(all) != 2 {
		t.Fatalf("ListTrashedBefore all owners: %+v %v", all, err)
	}
	own, err := r.ListTrashedBefore(ctx, s.R, "o1", cut, 10)
	if err != nil || len(own) != 1 {
		t.Fatalf("ListTrashedBefore o1: %+v %v", own, err)
	}
	early, _ := r.ListTrashedBefore(ctx, s.R, "", t1, 10)
	if len(early) != 0 {
		t.Fatalf("strictly before: %+v", early)
	}

	if err := r.SetUpdatedSeq(ctx, s.W, "a2", 20); err != nil {
		t.Fatal(err)
	}
	if err := r.SetThumbnailsReady(ctx, s.W, "a2", 21); err != nil {
		t.Fatal(err)
	}
	g, _ = r.GetByID(ctx, s.R, "a2")
	if !g.ThumbnailsReady || g.UpdatedSeq != 21 {
		t.Fatalf("thumbs: %+v", g)
	}

	w, h := int64(640), int64(480)
	codec := "hevc"
	mu := repository.MetadataUpdate{TakenAtSource: "exif", Width: &w, Height: &h, VideoCodec: &codec}
	if err := r.UpdateMetadata(ctx, s.W, "a2", mu, 30); err != nil {
		t.Fatal(err)
	}
	g, _ = r.GetByID(ctx, s.R, "a2")
	if *g.Width != 640 || *g.Height != 480 || *g.VideoCodec != "hevc" || g.UpdatedSeq != 30 {
		t.Fatalf("UpdateMetadata: %+v", g)
	}

	page, err := r.Page(ctx, s.R, "o1", "", 2)
	if err != nil || len(page) != 2 || page[0].ID != "a1" || page[1].ID != "a2" {
		t.Fatalf("Page 1: %+v %v", page, err)
	}
	page, _ = r.Page(ctx, s.R, "o1", "a2", 2)
	if len(page) != 1 || page[0].ID != "a3" {
		t.Fatalf("Page 2: %+v", page)
	}

	sum, err := r.SumSizes(ctx, s.R, "o1")
	if err != nil || sum != 300 {
		t.Fatalf("SumSizes: %d %v", sum, err)
	}
	if sum, _ := r.SumSizes(ctx, s.R, "nobody"); sum != 0 {
		t.Fatalf("empty sum: %d", sum)
	}

	if err := r.Delete(ctx, s.W, "a3"); err != nil {
		t.Fatal(err)
	}
	if _, err := r.GetByID(ctx, s.R, "a3"); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("after delete: %v", err)
	}
}

func TestAssetsSetKindAndStackIDForKey(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	repotest.SeedUser(t, s, "o1")
	repotest.SeedUser(t, s, "o2")
	r := repository.AssetsRepository{}
	if _, ok, err := r.StackIDForKey(ctx, s.R, "o1", "k"); err != nil || ok {
		t.Fatalf("empty: ok=%v err=%v", ok, err)
	}
	k := "k"
	a := newAsset("a1", "o1", "s1")
	a.StackKey = &k
	b := newAsset("a2", "o1", "s2")
	b.StackKey = &k
	first := "a1"
	b.StackID = &first
	o := newAsset("a0", "o2", "s3")
	o.StackKey = &k
	for _, x := range []repository.Asset{a, b, o} {
		if err := r.Insert(ctx, s.W, x); err != nil {
			t.Fatal(err)
		}
	}
	if id, ok, err := r.StackIDForKey(ctx, s.R, "o1", "k"); err != nil || !ok || id != "a1" {
		t.Fatalf("got %q %v %v", id, ok, err)
	}
	// After the first asset goes away the survivors keep the stack id.
	if err := r.Delete(ctx, s.W, "a1"); err != nil {
		t.Fatal(err)
	}
	if id, ok, err := r.StackIDForKey(ctx, s.R, "o1", "k"); err != nil || !ok || id != "a1" {
		t.Fatalf("after delete got %q %v %v", id, ok, err)
	}
	if err := r.SetKind(ctx, s.W, "a2", "live_photo"); err != nil {
		t.Fatal(err)
	}
	if g, _ := r.GetByID(ctx, s.R, "a2"); g.Kind != "live_photo" {
		t.Fatalf("kind = %q", g.Kind)
	}
	if err := r.SetKind(ctx, s.W, "nope", "video"); !errors.Is(err, repository.ErrNotFound) {
		t.Fatalf("missing: %v", err)
	}
}

func TestAssetsListMediaPending(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	repotest.SeedUser(t, s, "o1")
	r := repository.AssetsRepository{}
	yes, no := true, false
	mk := func(id, kind string, thumbs bool, playable *bool) {
		a := newAsset(id, "o1", "sha-"+id)
		a.Kind, a.ThumbnailsReady, a.Playable = kind, thumbs, playable
		if err := r.Insert(ctx, s.W, a); err != nil {
			t.Fatal(err)
		}
	}
	mk("a1", "photo", true, nil)      // done
	mk("a2", "photo", false, nil)     // needs thumbnails
	mk("a3", "video", true, nil)      // playability unknown
	mk("a4", "video", true, &yes)     // done
	mk("a5", "video", true, &no)      // may need a transcode
	mk("a6", "live_photo", true, nil) // done (still)
	got, err := r.ListMediaPending(ctx, s.R)
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, m := range got {
		ids = append(ids, m.ID)
	}
	if want := "a2,a3,a5"; strings.Join(ids, ",") != want {
		t.Fatalf("ListMediaPending = %v, want %s", ids, want)
	}
	if got[0].ThumbnailsReady || !got[1].ThumbnailsReady || got[1].Playable != nil || got[2].Playable == nil || *got[2].Playable ||
		got[1].Kind != "video" {
		t.Fatalf("rows: %+v", got)
	}
}
