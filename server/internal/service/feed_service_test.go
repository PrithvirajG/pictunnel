package service

import (
	"context"
	"database/sql"
	"fmt"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/ids"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
)

func TestCursorCodec(t *testing.T) {
	if got := EncodeCursor(1001); got != "c_00000000000003e9" {
		t.Fatalf("EncodeCursor = %q", got)
	}
	if v, err := DecodeCursor("c_00000000000003e9"); err != nil || v != 1001 {
		t.Fatalf("DecodeCursor = %d %v", v, err)
	}
	for _, bad := range []string{"", "c_", "c_3e9", "c_00000000000003E9", "x_00000000000003e9", "c_00000000000003e9 ",
		"c_ffffffffffffffff", "c_0000000000000g00"} {
		if _, err := DecodeCursor(bad); err == nil {
			t.Fatalf("DecodeCursor(%q) must fail", bad)
		}
	}
}

func TestSnapshotPagination(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	// 2,500 assets for alice (one trashed) plus noise from bob, inserted in
	// bulk with one change each.
	err := e.st.WithTx(ctx, func(tx *sql.Tx) error {
		for i := 0; i < 2510; i++ {
			p := e.alice
			if i >= 2500 {
				p = e.bob
			}
			a := repository.Asset{
				ID: ids.New(), OwnerID: p.UserID, SHA256: shaHex([]byte(fmt.Sprint(i))), SizeBytes: 1, Mime: "image/jpeg",
				Kind: "photo", Filename: "f.jpg", OriginalPath: fmt.Sprintf("%s/%d.jpg", p.Slug, i), TakenAtSource: "unknown",
				State: "active", CreatedAt: t0,
			}
			if i == 7 {
				a.State, a.TrashedAt = "trashed", &t0
			}
			if err := (repository.AssetsRepository{}).Insert(ctx, tx, a); err != nil {
				return err
			}
			if _, err := appendAssetUpsert(ctx, tx, repository.ChangeLogRepository{}, repository.AssetsRepository{}, p.UserID, a.ID, t0); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	head, _ := repository.ChangeLogRepository{}.Head(ctx, e.st.R)

	seen := map[string]bool{}
	last := ""
	token := ""
	var sizes []int
	trashed := 0
	for page := 0; ; page++ {
		cursor, assets, next, more, err := e.feed.Snapshot(ctx, e.alice, token, 1000)
		if err != nil {
			t.Fatalf("page %d: %v", page, err)
		}
		if cursor != EncodeCursor(head) {
			t.Fatalf("page %d cursor %q, want %q", page, cursor, EncodeCursor(head))
		}
		sizes = append(sizes, len(assets))
		for _, a := range assets {
			if a.OwnerID != e.alice.UserID || seen[a.ID] || a.ID <= last {
				t.Fatalf("page %d: bad order/dup/owner at %s", page, a.ID)
			}
			if a.State == "trashed" {
				trashed++
			}
			seen[a.ID], last = true, a.ID
		}
		if more != (next != "") {
			t.Fatalf("has_more %v with next %q", more, next)
		}
		if !more {
			break
		}
		// A change between pages does not move the snapshot cursor.
		if page == 0 {
			e.seed(t, e.bob, "late")
		}
		token = next
	}
	if fmt.Sprint(sizes) != "[1000 1000 500]" || len(seen) != 2500 || trashed != 1 {
		t.Fatalf("pages %v, %d assets, %d trashed", sizes, len(seen), trashed)
	}

	_, _, _, _, err = e.feed.Snapshot(ctx, e.alice, "garbage", 10)
	wantCode(t, err, "invalid_request")
	_, _, _, _, err = e.feed.Snapshot(ctx, e.alice, "", 1001)
	wantCode(t, err, "invalid_request")
	// Default limit is 1000.
	if _, a, _, more, err := e.feed.Snapshot(ctx, e.alice, "", 0); err != nil || len(a) != 1000 || !more {
		t.Fatalf("default limit: %d %v %v", len(a), more, err)
	}
}

func TestSnapshotIncludesLiveVideo(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	a := e.seed(t, e.alice, "still")
	lv := e.attachLive(t, a, "motion")
	e.seed(t, e.alice, "plain")
	_, assets, _, _, err := e.feed.Snapshot(ctx, e.alice, "", 10)
	if err != nil || len(assets) != 2 {
		t.Fatalf("%+v %v", assets, err)
	}
	for _, v := range assets {
		if v.ID == a.ID {
			if v.Live == nil || v.Live.SHA256 != lv.SHA256 || v.Kind != "live_photo" {
				t.Fatalf("live photo view: %+v", v)
			}
		} else if v.Live != nil {
			t.Fatalf("plain asset with live video: %+v", v)
		}
	}
}

// TestChangesAfterSnapshot is vector snapshot_changes_overlap at service level.
func TestChangesAfterSnapshot(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	a := e.seed(t, e.alice, "IMG_0001")
	cursor, assets, _, more, err := e.feed.Snapshot(ctx, e.alice, "", 0)
	if err != nil || len(assets) != 1 || assets[0].ID != a.ID || more {
		t.Fatalf("snapshot: %+v %v %v", assets, more, err)
	}
	b := e.seed(t, e.alice, "IMG_0002")
	e.seed(t, e.bob, "bob noise")
	if res, err := e.trash.Trash(ctx, e.alice, []string{a.ID}); err != nil || len(res.Succeeded) != 1 {
		t.Fatalf("trash: %+v %v", res, err)
	}
	changes, next, more, err := e.feed.Changes(ctx, e.alice, cursor, 0)
	if err != nil || more || len(changes) != 2 {
		t.Fatalf("changes: %+v %v %v", changes, more, err)
	}
	if changes[0].Kind != "asset.upsert" || changes[0].Asset == nil || changes[0].Asset.ID != b.ID || changes[0].Asset.State != "active" ||
		changes[1].Kind != "asset.upsert" || changes[1].Asset == nil || changes[1].Asset.ID != a.ID || changes[1].Asset.State != "trashed" {
		t.Fatalf("changes: %+v / %+v", changes[0], changes[1])
	}
	if changes[0].Seq >= changes[1].Seq || changes[1].Asset.UpdatedSeq != changes[1].Seq || next != EncodeCursor(changes[1].Seq) {
		t.Fatalf("seqs %d %d next %s", changes[0].Seq, changes[1].Seq, next)
	}
	// Nothing new: next stays put.
	again, next2, more, err := e.feed.Changes(ctx, e.alice, next, 0)
	if err != nil || len(again) != 0 || more || next2 != next {
		t.Fatalf("caught up: %+v %q %v %v", again, next2, more, err)
	}
	// Paging by limit.
	page, n1, more, err := e.feed.Changes(ctx, e.alice, cursor, 1)
	if err != nil || len(page) != 1 || !more || n1 != EncodeCursor(page[0].Seq) {
		t.Fatalf("limit 1: %+v %v %v", page, more, err)
	}
	_, _, _, err = e.feed.Changes(ctx, e.alice, cursor, 1001)
	wantCode(t, err, "invalid_request")
}

func TestCursorRequiredAndInvalid(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	e.seed(t, e.alice, "x")
	_, _, _, err := e.feed.Changes(ctx, e.alice, "", 0)
	wantCode(t, err, "cursor_required")
	_, _, _, err = e.feed.Changes(ctx, e.alice, "c_zz", 0)
	wantCode(t, err, "invalid_request")
	head, _ := repository.ChangeLogRepository{}.Head(ctx, e.st.R)
	_, _, _, err = e.feed.Changes(ctx, e.alice, EncodeCursor(head+1), 0)
	wantCode(t, err, "invalid_request")
}

func TestCursorExpired(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	e.seed(t, e.alice, "old")
	cursor, _, _, _, err := e.feed.Snapshot(ctx, e.alice, "", 0)
	if err != nil {
		t.Fatal(err)
	}
	e.clk.Advance(91 * 24 * time.Hour)
	if err := e.maint.CompactChangeLog(ctx); err != nil {
		t.Fatal(err)
	}
	_, _, _, err = e.feed.Changes(ctx, e.alice, cursor, 0)
	wantCode(t, err, "cursor_expired")
	_, _, _, err = e.feed.Changes(ctx, e.alice, EncodeCursor(0), 0)
	wantCode(t, err, "cursor_expired")

	// A fresh snapshot taken after compaction must be usable even though
	// nothing changed since (head would otherwise equal the floor).
	fresh, assets, _, _, err := e.feed.Snapshot(ctx, e.alice, "", 0)
	if err != nil || len(assets) != 1 {
		t.Fatalf("fresh snapshot: %+v %v", assets, err)
	}
	if ch, _, _, err := e.feed.Changes(ctx, e.alice, fresh, 0); err != nil || len(ch) != 0 {
		t.Fatalf("fresh cursor after compaction: %+v %v", ch, err)
	}
	b := e.seed(t, e.alice, "new")
	if ch, _, _, err := e.feed.Changes(ctx, e.alice, fresh, 0); err != nil || len(ch) != 1 || ch[0].Asset.ID != b.ID {
		t.Fatalf("change after fresh cursor: %+v %v", ch, err)
	}

	// Recent rows survive compaction and the floor never drops.
	e.clk.Advance(24 * time.Hour)
	if err := e.maint.CompactChangeLog(ctx); err != nil {
		t.Fatal(err)
	}
	if ch, _, _, err := e.feed.Changes(ctx, e.alice, fresh, 0); err != nil || len(ch) != 1 {
		t.Fatalf("recent change compacted: %+v %v", ch, err)
	}
}

func TestCursorEmptyServerNotExpired(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	cursor, assets, next, more, err := e.feed.Snapshot(ctx, e.alice, "", 0)
	if err != nil || cursor != EncodeCursor(0) || len(assets) != 0 || next != "" || more {
		t.Fatalf("empty snapshot: %q %+v %q %v %v", cursor, assets, next, more, err)
	}
	if err := e.maint.CompactChangeLog(ctx); err != nil {
		t.Fatal(err)
	}
	ch, n, more, err := e.feed.Changes(ctx, e.alice, cursor, 0)
	if err != nil || len(ch) != 0 || n != cursor || more {
		t.Fatalf("empty changes: %+v %q %v %v", ch, n, more, err)
	}
	e.clk.Advance(200 * 24 * time.Hour)
	if err := e.maint.CompactChangeLog(ctx); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := e.feed.Changes(ctx, e.alice, cursor, 0); err != nil {
		t.Fatalf("empty server cursor expired: %v", err)
	}
}

func TestChangesOneRowPerAsset(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	a := e.seed(t, e.alice, "flip")
	for _, op := range []func(context.Context, Principal, []string) (BulkResult, error){e.trash.Trash, e.trash.Restore, e.trash.Trash} {
		if _, err := op(ctx, e.alice, []string{a.ID}); err != nil {
			t.Fatal(err)
		}
	}
	ch, _, _, err := e.feed.Changes(ctx, e.alice, EncodeCursor(0), 0)
	if err != nil || len(ch) != 1 {
		t.Fatalf("want one row, got %+v %v", ch, err)
	}
	cur := e.asset(t, a.ID)
	if ch[0].Asset.State != "trashed" || ch[0].Seq != cur.UpdatedSeq {
		t.Fatalf("row %+v, asset seq %d", ch[0], cur.UpdatedSeq)
	}
	var n int
	if err := e.st.R.QueryRowContext(ctx, `SELECT COUNT(*) FROM change_log WHERE asset_id = ?`, a.ID).Scan(&n); err != nil || n != 1 {
		t.Fatalf("change_log rows for asset = %d %v", n, err)
	}
	// Purge replaces the row with asset.removed.
	if _, err := e.trash.Purge(ctx, e.alice, []string{a.ID}); err != nil {
		t.Fatal(err)
	}
	ch, _, _, err = e.feed.Changes(ctx, e.alice, EncodeCursor(0), 0)
	if err != nil || len(ch) != 1 || ch[0].Kind != "asset.removed" || ch[0].AssetID != a.ID || ch[0].Asset != nil {
		t.Fatalf("after purge: %+v %v", ch, err)
	}
}
