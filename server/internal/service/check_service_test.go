package service

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
)

func TestCheckVerdicts(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	a := e.seed(t, e.alice, "asset-a")
	e.attachLive(t, a, "live-a")
	trashed := e.seed(t, e.alice, "asset-trashed")
	if _, err := e.trash.Trash(ctx, e.alice, []string{trashed.ID}); err != nil {
		t.Fatal(err)
	}
	shaPartial := shaHex([]byte("partial"))
	sess := e.session(t, e.alice, shaPartial, "receiving", 100, 1000, t0.Add(time.Hour))
	shaTomb := shaHex([]byte("tomb"))
	e.tombstone(t, e.alice, shaTomb, "T.JPG", t0.Add(-time.Hour))
	// Precedence: partial beats tombstoned, exists beats partial.
	shaBoth := shaHex([]byte("both"))
	e.session(t, e.alice, shaBoth, "finalizing", 10, 10, t0.Add(time.Hour))
	e.tombstone(t, e.alice, shaBoth, "B.JPG", t0)
	e.session(t, e.alice, a.SHA256, "receiving", 1, 7, t0.Add(time.Hour))
	// An expired receiving session is gone (HEAD reports not_found).
	shaExpired := shaHex([]byte("expired"))
	e.session(t, e.alice, shaExpired, "receiving", 1, 7, t0.Add(-time.Second))
	shaMissing := shaHex([]byte("missing"))

	items := []CheckItem{
		{SHA256: shaMissing, SizeBytes: 1},
		{SHA256: a.SHA256, SizeBytes: a.SizeBytes},
		{SHA256: shaPartial, SizeBytes: 1000},
		{SHA256: shaTomb, SizeBytes: 5},
		{SHA256: a.SHA256, SizeBytes: a.SizeBytes},
		{SHA256: trashed.SHA256, SizeBytes: trashed.SizeBytes},
		{SHA256: shaBoth, SizeBytes: 10},
		{SHA256: shaExpired, SizeBytes: 7},
	}
	out, err := e.check.Check(ctx, e.alice, items)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"missing", "exists", "partial", "tombstoned", "exists", "exists", "partial", "missing"}
	if len(out) != len(want) {
		t.Fatalf("got %d results, want %d", len(out), len(want))
	}
	for i, w := range want {
		if out[i].Verdict != w || out[i].SHA256 != items[i].SHA256 {
			t.Fatalf("result %d = %s/%s, want %s/%s", i, out[i].SHA256, out[i].Verdict, items[i].SHA256, w)
		}
	}
	if out[1].Asset == nil || out[1].Asset.ID != a.ID || !out[1].HasLiveVideo || out[1].OnDisk != nil || out[1].Upload != nil {
		t.Fatalf("exists result: %+v", out[1])
	}
	if out[5].Asset == nil || out[5].Asset.State != "trashed" || out[5].HasLiveVideo {
		t.Fatalf("trashed exists result: %+v", out[5])
	}
	up := out[2].Upload
	if up == nil || up.ID != sess.ID || up.Offset != 100 || up.Length != 1000 || !up.ExpiresAt.Equal(sess.ExpiresAt) || out[2].Asset != nil {
		t.Fatalf("partial result: %+v", out[2])
	}
	if out[3].DeletedAt == nil || !out[3].DeletedAt.Equal(t0.Add(-time.Hour)) {
		t.Fatalf("tombstoned result: %+v", out[3])
	}
	if out[0].Asset != nil || out[0].Upload != nil || out[0].DeletedAt != nil {
		t.Fatalf("missing result carries data: %+v", out[0])
	}

	// Validation: 1..1000 items with lowercase hex hashes.
	_, err = e.check.Check(ctx, e.alice, nil)
	wantCode(t, err, "invalid_request")
	_, err = e.check.Check(ctx, e.alice, make([]CheckItem, 1001))
	wantCode(t, err, "invalid_request")
	_, err = e.check.Check(ctx, e.alice, []CheckItem{{SHA256: strings.ToUpper(shaMissing), SizeBytes: 1}})
	wantCode(t, err, "invalid_request")
	_, err = e.check.Check(ctx, e.alice, []CheckItem{{SHA256: shaMissing, SizeBytes: -1}})
	wantCode(t, err, "invalid_request")
	many := make([]CheckItem, 1000)
	for i := range many {
		many[i] = CheckItem{SHA256: shaMissing, SizeBytes: 1}
	}
	if out, err := e.check.Check(ctx, e.alice, many); err != nil || len(out) != 1000 {
		t.Fatalf("1000 items: %d %v", len(out), err)
	}
}

func TestCheckLinksSourcesIdempotent(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	a := e.seed(t, e.alice, "linked")
	devB := e.device(t, e.alice)
	item := []CheckItem{{SHA256: a.SHA256, SizeBytes: a.SizeBytes, LocalID: "b-7"}}
	sources := func() []repository.AssetSource {
		s, err := repository.AssetSourcesRepository{}.ListByAsset(ctx, e.st.R, a.ID)
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	for i := 0; i < 2; i++ {
		out, err := e.check.Check(ctx, devB, item)
		if err != nil || out[0].Verdict != "exists" {
			t.Fatalf("check %d: %+v %v", i, out, err)
		}
		s := sources()
		if len(s) != 1 || s[0].DeviceID != devB.DeviceID || s[0].LocalID != "b-7" {
			t.Fatalf("after check %d: sources %+v", i, s)
		}
	}
	if _, err := e.check.Check(ctx, e.alice, []CheckItem{{SHA256: a.SHA256, SizeBytes: a.SizeBytes, LocalID: "a-1"}}); err != nil {
		t.Fatal(err)
	}
	if s := sources(); len(s) != 2 {
		t.Fatalf("two devices: %+v", s)
	}
	// Only exists links: a missing verdict with a local_id writes nothing.
	if _, err := e.check.Check(ctx, devB, []CheckItem{{SHA256: shaHex([]byte("nope")), SizeBytes: 1, LocalID: "b-8"}}); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := e.st.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM asset_sources`).Scan(&n); err != nil || n != 2 {
		t.Fatalf("asset_sources rows = %d %v, want 2", n, err)
	}
}

func TestCheckConfirmOnDisk(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	a := e.seed(t, e.alice, "on-disk")
	lp := e.seed(t, e.alice, "live-primary")
	lv := e.attachLive(t, lp, "live-video")
	confirm := func(x repository.Asset) bool {
		t.Helper()
		out, err := e.check.Check(ctx, e.alice, []CheckItem{{SHA256: x.SHA256, SizeBytes: x.SizeBytes, ConfirmOnDisk: true}})
		if err != nil {
			t.Fatal(err)
		}
		if out[0].OnDisk == nil {
			t.Fatalf("confirm_on_disk must set OnDisk: %+v", out[0])
		}
		return *out[0].OnDisk
	}
	if !confirm(a) || !confirm(lp) {
		t.Fatal("present originals must be on disk")
	}
	// A size mismatch is not on disk.
	e.writeLib(t, a.OriginalPath, "truncated")
	if confirm(a) {
		t.Fatal("size mismatch must be on_disk=false")
	}
	if err := os.Remove(e.lib(a.OriginalPath)); err != nil {
		t.Fatal(err)
	}
	if confirm(a) {
		t.Fatal("deleted original must be on_disk=false")
	}
	// A Live Photo is on disk only with its video component.
	if err := os.Remove(e.lib(lv.OriginalPath)); err != nil {
		t.Fatal(err)
	}
	if confirm(lp) {
		t.Fatal("missing live video must be on_disk=false")
	}
}

func TestCheckNoCrossUserLeak(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	b := e.seed(t, e.bob, "bobs")
	shaSess := shaHex([]byte("bob-session"))
	e.session(t, e.bob, shaSess, "receiving", 0, 10, t0.Add(time.Hour))
	shaTomb := shaHex([]byte("bob-tomb"))
	e.tombstone(t, e.bob, shaTomb, "X.JPG", t0)
	out, err := e.check.Check(ctx, e.alice, []CheckItem{
		{SHA256: b.SHA256, SizeBytes: b.SizeBytes, LocalID: "steal", ConfirmOnDisk: true},
		{SHA256: shaSess, SizeBytes: 10},
		{SHA256: shaTomb, SizeBytes: 1},
	})
	if err != nil {
		t.Fatal(err)
	}
	for i, r := range out {
		if r.Verdict != "missing" || r.Asset != nil || r.Upload != nil || r.DeletedAt != nil || r.OnDisk != nil {
			t.Fatalf("result %d leaks another user's data: %+v", i, r)
		}
	}
	if s, _ := (repository.AssetSourcesRepository{}).ListByAsset(ctx, e.st.R, b.ID); len(s) != 0 {
		t.Fatalf("alice linked bob's asset: %+v", s)
	}
}
