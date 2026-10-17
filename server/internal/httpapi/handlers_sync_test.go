package httpapi_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/httpapitest"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
)

func shaOf(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

func TestCheckContent(t *testing.T) {
	a, s := withAdmin(t)
	photo := []byte("photo bytes one")
	id := a.SeedAsset(t, s, photo, "IMG_0001.JPG", "image/jpeg")
	missing := shaOf([]byte("not uploaded"))

	// A partial upload.
	part := []byte("partial content 123456")
	if _, err := a.Upload.Create(context.Background(), a.Principal(t, s.Access), service.CreateInput{
		Length: int64(len(part)), Meta: service.UploadMeta{SHA256: shaOf(part), Filename: "p.jpg", Mime: "image/jpeg"},
	}); err != nil {
		t.Fatal(err)
	}

	resp, body := call(t, a, s.Access, "POST", "/api/v1/sync/check", map[string]any{"items": []map[string]any{
		{"sha256": shaOf(photo), "size_bytes": len(photo), "local_id": "a-1", "confirm_on_disk": true},
		{"sha256": missing, "size_bytes": 10},
		{"sha256": shaOf(part), "size_bytes": len(part)},
	}})
	wantStatus(t, resp, body, 200)
	var cr gen.CheckResponse
	httpapitest.Decode(t, body, &cr)
	if len(cr.Results) != 3 {
		t.Fatalf("results: %s", body)
	}
	r0, r1, r2 := cr.Results[0], cr.Results[1], cr.Results[2]
	if r0.Verdict != "exists" || r0.AssetId == nil || r0.AssetId.String() != id || r0.AssetState == nil || *r0.AssetState != "active" ||
		r0.HasLiveVideo == nil || *r0.HasLiveVideo || r0.OnDisk == nil || !*r0.OnDisk {
		t.Errorf("exists result: %s", body)
	}
	if r1.Verdict != "missing" || r1.Sha256 != missing || r1.AssetId != nil {
		t.Errorf("missing result: %s", body)
	}
	if r2.Verdict != "partial" || r2.Upload == nil || r2.Upload.Url != "/api/v1/uploads/"+r2.Upload.Id ||
		r2.Upload.Offset != 0 || r2.Upload.Length != int64(len(part)) {
		t.Errorf("partial result: %s", body)
	}
}

func TestCheckContentInvalid(t *testing.T) {
	a, s := withAdmin(t)
	resp, body := call(t, a, s.Access, "POST", "/api/v1/sync/check", map[string]any{"items": []any{}})
	wantProblem(t, resp, body, 400, "invalid_request")
	resp, body = call(t, a, s.Access, "POST", "/api/v1/sync/check", `not json`)
	wantProblem(t, resp, body, 400, "invalid_request")
}

func TestSnapshotThenChanges(t *testing.T) {
	a, s := withAdmin(t)
	id1 := a.SeedAsset(t, s, []byte("first"), "a.jpg", "image/jpeg")

	resp, body := call(t, a, s.Access, "GET", "/api/v1/sync/snapshot?limit=1000", nil)
	wantStatus(t, resp, body, 200)
	var snap gen.SnapshotPage
	httpapitest.Decode(t, body, &snap)
	if snap.Cursor == nil || len(snap.Assets) != 1 || snap.Assets[0].Id.String() != id1 || snap.HasMore {
		t.Fatalf("snapshot: %s", body)
	}

	id2 := a.SeedAsset(t, s, []byte("second"), "b.jpg", "image/jpeg")
	resp, body = call(t, a, s.Access, "GET", "/api/v1/sync/changes?limit=500&cursor="+*snap.Cursor, nil)
	wantStatus(t, resp, body, 200)
	var ch gen.ChangesPage
	httpapitest.Decode(t, body, &ch)
	if len(ch.Changes) != 1 || ch.Changes[0].Kind != "asset.upsert" || ch.Changes[0].Asset == nil ||
		ch.Changes[0].Asset.Id.String() != id2 || ch.HasMore || ch.NextCursor == *snap.Cursor {
		t.Fatalf("changes: %s", body)
	}

	// Purge shows up as asset.removed.
	resp, body = call(t, a, s.Access, "POST", "/api/v1/assets/trash", map[string]any{"asset_ids": []string{id1}})
	wantStatus(t, resp, body, 200)
	resp, body = call(t, a, s.Access, "POST", "/api/v1/assets/purge", map[string]any{"asset_ids": []string{id1}})
	wantStatus(t, resp, body, 200)
	resp, body = call(t, a, s.Access, "GET", "/api/v1/sync/changes?cursor="+ch.NextCursor, nil)
	wantStatus(t, resp, body, 200)
	ch = gen.ChangesPage{}
	httpapitest.Decode(t, body, &ch)
	if len(ch.Changes) != 1 || ch.Changes[0].Kind != "asset.removed" || ch.Changes[0].AssetId == nil ||
		ch.Changes[0].AssetId.String() != id1 || ch.Changes[0].Asset != nil {
		t.Fatalf("removed change: %s", body)
	}
}

func TestSnapshotPaging(t *testing.T) {
	a, s := withAdmin(t)
	a.SeedAsset(t, s, []byte("one"), "1.jpg", "image/jpeg")
	a.SeedAsset(t, s, []byte("two"), "2.jpg", "image/jpeg")
	resp, body := call(t, a, s.Access, "GET", "/api/v1/sync/snapshot?limit=1", nil)
	wantStatus(t, resp, body, 200)
	var p1 gen.SnapshotPage
	httpapitest.Decode(t, body, &p1)
	if !p1.HasMore || p1.NextPageToken == nil || p1.Cursor == nil {
		t.Fatalf("page 1: %s", body)
	}
	resp, body = call(t, a, s.Access, "GET", "/api/v1/sync/snapshot?limit=1&page_token="+*p1.NextPageToken, nil)
	wantStatus(t, resp, body, 200)
	var p2 gen.SnapshotPage
	httpapitest.Decode(t, body, &p2)
	if p2.HasMore || p2.Cursor != nil || len(p2.Assets) != 1 || p2.Assets[0].Id == p1.Assets[0].Id {
		t.Fatalf("page 2: %s", body)
	}
	resp, body = call(t, a, s.Access, "GET", "/api/v1/sync/snapshot?page_token=not.a.token", nil)
	wantProblem(t, resp, body, 400, "invalid_request")
	resp, body = call(t, a, s.Access, "GET", "/api/v1/sync/snapshot?limit=abc", nil)
	wantProblem(t, resp, body, 400, "invalid_request")
}

func TestChangesCursorRequired(t *testing.T) {
	a, s := withAdmin(t)
	resp, body := call(t, a, s.Access, "GET", "/api/v1/sync/changes", nil)
	wantProblem(t, resp, body, 400, "cursor_required")
	resp, body = call(t, a, s.Access, "GET", "/api/v1/sync/changes?cursor=bogus", nil)
	wantProblem(t, resp, body, 400, "invalid_request")
}

func TestChangesCursorExpired(t *testing.T) {
	a, s := withAdmin(t)
	a.SeedAsset(t, s, []byte("x"), "x.jpg", "image/jpeg")
	if _, err := a.Store.W.ExecContext(context.Background(),
		`INSERT INTO server_state (key, value) VALUES ('change_log_floor', '1')
		 ON CONFLICT(key) DO UPDATE SET value = excluded.value`); err != nil {
		t.Fatal(err)
	}
	resp, body := call(t, a, s.Access, "GET", "/api/v1/sync/changes?cursor="+service.EncodeCursor(1), nil)
	wantProblem(t, resp, body, 410, "cursor_expired")
}

func TestTombstones(t *testing.T) {
	a, s := withAdmin(t)
	content := []byte("to be purged")
	id := a.SeedAsset(t, s, content, "IMG_0001.JPG", "image/jpeg")
	call(t, a, s.Access, "POST", "/api/v1/assets/trash", map[string]any{"asset_ids": []string{id}})
	call(t, a, s.Access, "POST", "/api/v1/assets/purge", map[string]any{"asset_ids": []string{id}})

	resp, body := call(t, a, s.Access, "GET", "/api/v1/tombstones?limit=50", nil)
	wantStatus(t, resp, body, 200)
	var tp gen.TombstonePage
	httpapitest.Decode(t, body, &tp)
	if len(tp.Tombstones) != 1 || tp.Tombstones[0].Sha256 != shaOf(content) || tp.Tombstones[0].Filename != "IMG_0001.JPG" || tp.HasMore {
		t.Fatalf("tombstones: %s", body)
	}

	resp, body = call(t, a, s.Access, "DELETE", "/api/v1/tombstones/"+shaOf(content), nil)
	wantStatus(t, resp, body, 204)
	resp, body = call(t, a, s.Access, "DELETE", "/api/v1/tombstones/"+shaOf(content), nil)
	wantStatus(t, resp, body, 204)
	resp, body = call(t, a, s.Access, "GET", "/api/v1/tombstones", nil)
	wantStatus(t, resp, body, 200)
	httpapitest.Decode(t, body, &tp)
	if len(tp.Tombstones) != 0 {
		t.Fatalf("tombstone not deleted: %s", body)
	}
}
