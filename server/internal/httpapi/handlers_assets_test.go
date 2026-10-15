package httpapi_test

import (
	"bytes"
	"fmt"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/httpapitest"
)

func TestGetAsset(t *testing.T) {
	a, s := withAdmin(t)
	content := []byte("jpeg-ish bytes")
	id := a.SeedAsset(t, s, content, "IMG_0001.JPG", "image/jpeg")
	resp, body := call(t, a, s.Access, "GET", "/api/v1/assets/"+id, nil)
	wantStatus(t, resp, body, 200)
	var as gen.Asset
	httpapitest.Decode(t, body, &as)
	if as.Id.String() != id || as.Sha256 != shaOf(content) || as.SizeBytes != int64(len(content)) || as.Kind != "photo" ||
		as.State != "active" || as.Filename != "IMG_0001.JPG" || as.TrashedAt != nil || as.LiveVideo != nil || as.UpdatedSeq == 0 {
		t.Fatalf("asset: %s", body)
	}

	// Another user's asset is not found.
	a.CreateUser(t, "bob", adminPass)
	bob := a.Login(t, "bob", adminPass)
	resp, body = call(t, a, bob.Access, "GET", "/api/v1/assets/"+id, nil)
	wantProblem(t, resp, body, 404, "not_found")
	resp, body = call(t, a, s.Access, "GET", "/api/v1/assets/"+unknownUUID, nil)
	wantProblem(t, resp, body, 404, "not_found")
}

func TestTrashRestorePurgeEmpty(t *testing.T) {
	a, s := withAdmin(t)
	id1 := a.SeedAsset(t, s, []byte("one"), "1.jpg", "image/jpeg")
	id2 := a.SeedAsset(t, s, []byte("two"), "2.jpg", "image/jpeg")
	id3 := a.SeedAsset(t, s, []byte("three"), "3.jpg", "image/jpeg")

	bulk := func(path string, ids ...string) gen.BulkResult {
		t.Helper()
		resp, body := call(t, a, s.Access, "POST", path, map[string]any{"asset_ids": ids})
		wantStatus(t, resp, body, 200)
		var br gen.BulkResult
		httpapitest.Decode(t, body, &br)
		if br.Succeeded == nil || br.Failed == nil {
			t.Fatalf("bulk lists must be arrays: %s", body)
		}
		return br
	}

	br := bulk("/api/v1/assets/trash", id1, unknownUUID)
	if len(br.Succeeded) != 1 || br.Succeeded[0].String() != id1 || len(br.Failed) != 1 ||
		br.Failed[0].AssetId.String() != unknownUUID || br.Failed[0].Code != "not_found" {
		t.Fatalf("trash: %+v", br)
	}
	br = bulk("/api/v1/assets/restore", id1)
	if len(br.Succeeded) != 1 || len(br.Failed) != 0 {
		t.Fatalf("restore: %+v", br)
	}
	bulk("/api/v1/assets/trash", id1)
	br = bulk("/api/v1/assets/purge", id1, id2)
	if len(br.Succeeded) != 1 || br.Succeeded[0].String() != id1 || len(br.Failed) != 1 || br.Failed[0].Code != "not_trashed" {
		t.Fatalf("purge: %+v", br)
	}

	bulk("/api/v1/assets/trash", id2, id3)
	resp, body := call(t, a, s.Access, "POST", "/api/v1/trash/empty", nil)
	wantStatus(t, resp, body, 200)
	var et gen.EmptyTrashResult
	httpapitest.Decode(t, body, &et)
	if et.PurgedCount != 2 {
		t.Fatalf("empty: %s", body)
	}

	resp, body = call(t, a, s.Access, "POST", "/api/v1/assets/trash", map[string]any{"asset_ids": []string{}})
	wantProblem(t, resp, body, 400, "invalid_request")
	resp, body = call(t, a, s.Access, "POST", "/api/v1/assets/trash", map[string]any{"asset_ids": []string{"nope"}})
	wantProblem(t, resp, body, 400, "invalid_request")
}

func TestGetOriginal(t *testing.T) {
	a, s := withAdmin(t)
	content := bytes.Repeat([]byte("0123456789"), 200)
	id := a.SeedAsset(t, s, content, "Ünïcode photo 1.jpg", "image/jpeg")
	resp, body := call(t, a, s.Access, "GET", "/api/v1/assets/"+id+"/original", nil)
	wantStatus(t, resp, body, 200)
	if !bytes.Equal(body, content) {
		t.Fatalf("original body differs (%d bytes)", len(body))
	}
	h := resp.Header
	if h.Get("ETag") != `"`+shaOf(content)+`"` || h.Get("Accept-Ranges") != "bytes" ||
		h.Get("Content-Type") != "application/octet-stream" ||
		h.Get("Content-Disposition") != `attachment; filename*=UTF-8''%C3%9Cn%C3%AFcode%20photo%201.jpg` {
		t.Fatalf("original headers: %v", h)
	}

	resp, body = call(t, a, s.Access, "GET", "/api/v1/assets/"+unknownUUID+"/original", nil)
	wantProblem(t, resp, body, 404, "not_found")
	resp, body = call(t, a, s.Access, "GET", "/api/v1/assets/not-a-uuid/original", nil)
	wantProblem(t, resp, body, 404, "not_found")
	resp, body = call(t, a, "", "GET", "/api/v1/assets/"+id+"/original", nil)
	wantProblem(t, resp, body, 401, "unauthorized")
}

func TestRangeOriginal(t *testing.T) {
	a, s := withAdmin(t)
	content := bytes.Repeat([]byte("abcdefghij"), 100)
	id := a.SeedAsset(t, s, content, "r.jpg", "image/jpeg")
	req := httpapitest.Bearer(a.Req(t, "GET", "/api/v1/assets/"+id+"/original", nil), s.Access)
	req.Header.Set("Range", "bytes=0-99")
	resp, body := a.Do(t, req)
	wantStatus(t, resp, body, 206)
	if resp.Header.Get("Content-Range") != fmt.Sprintf("bytes 0-99/%d", len(content)) || !bytes.Equal(body, content[:100]) {
		t.Fatalf("range: %v %d bytes", resp.Header, len(body))
	}
	if resp.Header.Get("ETag") != `"`+shaOf(content)+`"` {
		t.Fatalf("206 without ETag: %v", resp.Header)
	}

	req = httpapitest.Bearer(a.Req(t, "GET", "/api/v1/assets/"+id+"/original", nil), s.Access)
	req.Header.Set("Range", "bytes=5000-6000")
	resp, body = a.Do(t, req)
	wantProblem(t, resp, body, 416, "invalid_request")
}

func TestETagNotModified(t *testing.T) {
	a, s := withAdmin(t)
	content := []byte("etag content")
	id := a.SeedAsset(t, s, content, "e.jpg", "image/jpeg")
	req := httpapitest.Bearer(a.Req(t, "GET", "/api/v1/assets/"+id+"/original", nil), s.Access)
	req.Header.Set("If-None-Match", `"`+shaOf(content)+`"`)
	resp, body := a.Do(t, req)
	wantStatus(t, resp, body, 304)
	if len(body) != 0 {
		t.Fatalf("304 with body %q", body)
	}

	a.SetThumbnails(t, id, []byte("thumb jpeg"), []byte("preview jpeg"))
	req = httpapitest.Bearer(a.Req(t, "GET", "/api/v1/assets/"+id+"/thumbnail", nil), s.Access)
	req.Header.Set("If-None-Match", `"`+shaOf(content)+`-thumb"`)
	resp, body = a.Do(t, req)
	wantStatus(t, resp, body, 304)
}

func TestThumbnail(t *testing.T) {
	a, s := withAdmin(t)
	content := []byte("photo for thumbs")
	id := a.SeedAsset(t, s, content, "t.jpg", "image/jpeg")
	resp, body := call(t, a, s.Access, "GET", "/api/v1/assets/"+id+"/thumbnail", nil)
	wantProblem(t, resp, body, 404, "not_ready")

	a.SetThumbnails(t, id, []byte("thumb jpeg"), []byte("preview jpeg"))
	resp, body = call(t, a, s.Access, "GET", "/api/v1/assets/"+id+"/thumbnail", nil)
	wantStatus(t, resp, body, 200)
	if string(body) != "thumb jpeg" || resp.Header.Get("Content-Type") != "image/jpeg" ||
		resp.Header.Get("ETag") != `"`+shaOf(content)+`-thumb"` ||
		resp.Header.Get("Cache-Control") != "private, max-age=31536000, immutable" {
		t.Fatalf("thumb: %v %q", resp.Header, body)
	}
	resp, body = call(t, a, s.Access, "GET", "/api/v1/assets/"+id+"/thumbnail?size=preview", nil)
	wantStatus(t, resp, body, 200)
	if string(body) != "preview jpeg" || resp.Header.Get("ETag") != `"`+shaOf(content)+`-preview"` {
		t.Fatalf("preview: %v %q", resp.Header, body)
	}
	resp, body = call(t, a, s.Access, "GET", "/api/v1/assets/"+id+"/thumbnail?size=huge", nil)
	wantProblem(t, resp, body, 400, "invalid_request")
	resp, body = call(t, a, s.Access, "GET", "/api/v1/assets/"+unknownUUID+"/thumbnail", nil)
	wantProblem(t, resp, body, 404, "not_found")
}

func TestPlayback(t *testing.T) {
	a, s := withAdmin(t)
	video := bytes.Repeat([]byte("mp4!"), 64)
	vid := a.SeedAsset(t, s, video, "clip.mp4", "video/mp4")
	photo := a.SeedAsset(t, s, []byte("still"), "still.jpg", "image/jpeg")

	resp, body := call(t, a, s.Access, "GET", "/api/v1/assets/"+vid+"/playback", nil)
	wantProblem(t, resp, body, 404, "not_ready")
	resp, body = call(t, a, s.Access, "GET", "/api/v1/assets/"+photo+"/playback", nil)
	wantProblem(t, resp, body, 404, "not_found")

	a.SetPlayable(t, vid, true)
	resp, body = call(t, a, s.Access, "GET", "/api/v1/assets/"+vid+"/playback", nil)
	wantStatus(t, resp, body, 200)
	if !bytes.Equal(body, video) || resp.Header.Get("Content-Type") != "video/mp4" {
		t.Fatalf("playback: %v", resp.Header)
	}
	req := httpapitest.Bearer(a.Req(t, "GET", "/api/v1/assets/"+vid+"/playback", nil), s.Access)
	req.Header.Set("Range", "bytes=0-")
	resp, body = a.Do(t, req)
	wantStatus(t, resp, body, 206)
	if resp.Header.Get("Content-Range") != fmt.Sprintf("bytes 0-%d/%d", len(video)-1, len(video)) {
		t.Fatalf("playback range: %v", resp.Header)
	}
}
