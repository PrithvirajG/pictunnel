package service

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/ids"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
)

func failedCodes(r BulkResult) map[string]string {
	m := map[string]string{}
	for _, f := range r.Failed {
		m[f.AssetID] = f.Code
	}
	return m
}

func TestTrashAndValidation(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	a := e.seed(t, e.alice, "a")
	b := e.seed(t, e.bob, "b")
	unknown := ids.New()
	res, err := e.trash.Trash(ctx, e.alice, []string{a.ID, unknown, b.ID, a.ID})
	if err != nil {
		t.Fatal(err)
	}
	if fmt.Sprint(res.Succeeded) != fmt.Sprint([]string{a.ID}) {
		t.Fatalf("succeeded %v", res.Succeeded)
	}
	if f := failedCodes(res); len(f) != 2 || f[unknown] != "not_found" || f[b.ID] != "not_found" {
		t.Fatalf("failed %+v", res.Failed)
	}
	got := e.asset(t, a.ID)
	if got.State != "trashed" || got.TrashedAt == nil || !got.TrashedAt.Equal(t0) || got.UpdatedSeq <= a.UpdatedSeq {
		t.Fatalf("trashed asset: %+v", got)
	}
	// Trashing again succeeds without touching trashed_at or the feed.
	e.clk.Advance(time.Hour)
	if res, err := e.trash.Trash(ctx, e.alice, []string{a.ID}); err != nil || len(res.Succeeded) != 1 {
		t.Fatalf("re-trash: %+v %v", res, err)
	}
	if again := e.asset(t, a.ID); !again.TrashedAt.Equal(t0) || again.UpdatedSeq != got.UpdatedSeq {
		t.Fatalf("re-trash changed the asset: %+v", again)
	}
	if e.asset(t, b.ID).State != "active" {
		t.Fatal("bob's asset was trashed")
	}
	_, err = e.trash.Trash(ctx, e.alice, nil)
	wantCode(t, err, "invalid_request")
	_, err = e.trash.Trash(ctx, e.alice, make([]string, 1001))
	wantCode(t, err, "invalid_request")
}

func TestRestore(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	a := e.seed(t, e.alice, "a")
	if _, err := e.trash.Trash(ctx, e.alice, []string{a.ID}); err != nil {
		t.Fatal(err)
	}
	trashed := e.asset(t, a.ID)
	unknown := ids.New()
	res, err := e.trash.Restore(ctx, e.alice, []string{a.ID, unknown})
	if err != nil || len(res.Succeeded) != 1 || res.Succeeded[0] != a.ID || failedCodes(res)[unknown] != "not_found" {
		t.Fatalf("restore: %+v %v", res, err)
	}
	got := e.asset(t, a.ID)
	if got.State != "active" || got.TrashedAt != nil || got.UpdatedSeq <= trashed.UpdatedSeq {
		t.Fatalf("restored asset: %+v", got)
	}
	// Restoring an active asset is a no-op success.
	if res, err := e.trash.Restore(ctx, e.alice, []string{a.ID}); err != nil || len(res.Succeeded) != 1 {
		t.Fatalf("restore active: %+v %v", res, err)
	}
	if e.asset(t, a.ID).UpdatedSeq != got.UpdatedSeq {
		t.Fatal("no-op restore appended a change")
	}
	_, err = e.trash.Restore(ctx, e.alice, nil)
	wantCode(t, err, "invalid_request")
}

func TestPurgeRequiresTrashed(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	active := e.seed(t, e.alice, "active")
	bobs := e.seed(t, e.bob, "bobs")
	if _, err := e.trash.Trash(ctx, e.bob, []string{bobs.ID}); err != nil {
		t.Fatal(err)
	}
	unknown := ids.New()
	res, err := e.trash.Purge(ctx, e.alice, []string{active.ID, unknown, bobs.ID})
	if err != nil {
		t.Fatal(err)
	}
	f := failedCodes(res)
	if len(res.Succeeded) != 0 || f[active.ID] != "not_trashed" || f[unknown] != "not_found" || f[bobs.ID] != "not_found" {
		t.Fatalf("purge: %+v", res)
	}
	if e.assetGone(t, active.ID) || e.assetGone(t, bobs.ID) {
		t.Fatal("purge removed an asset it refused")
	}
	if !exists(e.lib(active.OriginalPath)) {
		t.Fatal("purge removed the file of an active asset")
	}
	_, err = e.trash.Purge(ctx, e.alice, nil)
	wantCode(t, err, "invalid_request")
}

func TestPurgeTombstonesAndRemovesFiles(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	a := e.seed(t, e.alice, "purge me")
	lv := e.attachLive(t, a, "purge my video")
	e.writeDerived(t, a.ID, "thumb.jpg", "t")
	e.writeDerived(t, a.ID, "preview.jpg", "p")
	keep := e.seed(t, e.alice, "keep me")
	src := e.device(t, e.alice)
	if _, err := e.check.Check(ctx, src, []CheckItem{{SHA256: a.SHA256, SizeBytes: a.SizeBytes, LocalID: "l1"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.trash.Trash(ctx, e.alice, []string{a.ID}); err != nil {
		t.Fatal(err)
	}
	e.clk.Advance(time.Minute)
	res, err := e.trash.Purge(ctx, e.alice, []string{a.ID})
	if err != nil || len(res.Succeeded) != 1 || len(res.Failed) != 0 {
		t.Fatalf("purge: %+v %v", res, err)
	}
	if !e.assetGone(t, a.ID) {
		t.Fatal("asset row survived purge")
	}
	if _, err := (repository.LiveVideosRepository{}).GetByAsset(ctx, e.st.R, a.ID); err != repository.ErrNotFound {
		t.Fatalf("live video row survived: %v", err)
	}
	if s, _ := (repository.AssetSourcesRepository{}).ListByAsset(ctx, e.st.R, a.ID); len(s) != 0 {
		t.Fatalf("asset sources survived: %+v", s)
	}
	tomb, err := repository.TombstonesRepository{}.Get(ctx, e.st.R, e.alice.UserID, a.SHA256)
	if err != nil || tomb.Filename != a.Filename || !tomb.DeletedAt.Equal(t0.Add(time.Minute)) {
		t.Fatalf("tombstone: %+v %v", tomb, err)
	}
	for _, p := range []string{e.lib(a.OriginalPath), e.lib(lv.OriginalPath), e.derived(a.ID)} {
		if exists(p) {
			t.Fatalf("%s survived purge", p)
		}
	}
	if !exists(e.lib(keep.OriginalPath)) {
		t.Fatal("purge removed an unrelated file")
	}
	for _, rel := range []string{a.OriginalPath, lv.OriginalPath} {
		if ok, _ := (repository.LibraryPathsRepository{}).Exists(ctx, e.st.R, storage.PathKey(rel)); ok {
			t.Fatalf("reservation %s not released", rel)
		}
	}
	if ok, _ := (repository.LibraryPathsRepository{}).Exists(ctx, e.st.R, storage.PathKey(keep.OriginalPath)); !ok {
		t.Fatal("unrelated reservation released")
	}
	// The deletions are also tracked durably as delete_file jobs.
	if jobs := e.pendingJobs(t, JobDeleteFile); len(jobs) != 3 {
		t.Fatalf("delete_file jobs: %+v", jobs)
	}
	out, err := e.check.Check(ctx, e.alice, []CheckItem{{SHA256: a.SHA256, SizeBytes: a.SizeBytes}})
	if err != nil || out[0].Verdict != "tombstoned" || out[0].DeletedAt == nil {
		t.Fatalf("check after purge: %+v %v", out, err)
	}
	if _, err := e.assets.Get(ctx, e.alice, a.ID); err == nil {
		t.Fatal("purged asset still readable")
	}
}

func TestPurgeRetriesFailedDeletes(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	e.runner.Register(JobDeleteFile, e.trash.DeleteFile, 0)
	a := e.seed(t, e.alice, "sticky")
	e.writeDerived(t, a.ID, "thumb.jpg", "t")
	e.fs.setFail(e.lib(a.OriginalPath), true)
	e.fs.setFail(e.derived(a.ID), true)
	if _, err := e.trash.Trash(ctx, e.alice, []string{a.ID}); err != nil {
		t.Fatal(err)
	}
	if res, err := e.trash.Purge(ctx, e.alice, []string{a.ID}); err != nil || len(res.Succeeded) != 1 {
		t.Fatalf("purge must succeed even when file deletes fail: %+v %v", res, err)
	}
	if !exists(e.lib(a.OriginalPath)) || !exists(e.derived(a.ID)) {
		t.Fatal("fault injection did not keep the files")
	}
	if err := e.runner.RunNow(ctx, JobDeleteFile); err == nil {
		t.Fatal("delete_file must fail while the filesystem refuses")
	}
	e.fs.setFail(e.lib(a.OriginalPath), false)
	e.fs.setFail(e.derived(a.ID), false)
	e.clk.Advance(2 * time.Hour) // past the retry backoff
	if err := e.runner.RunNow(ctx, JobDeleteFile); err != nil {
		t.Fatal(err)
	}
	if exists(e.lib(a.OriginalPath)) || exists(e.derived(a.ID)) {
		t.Fatal("retry did not remove the files")
	}
	if j := e.pendingJobs(t, JobDeleteFile); len(j) != 0 {
		t.Fatalf("jobs left: %+v", j)
	}
}

func TestDeleteFileNeverRemovesReferencedFiles(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	a := e.seed(t, e.alice, "referenced")
	lp := e.seed(t, e.alice, "primary")
	lv := e.attachLive(t, lp, "video")
	payload := func(k, v string) []byte {
		b, _ := json.Marshal(map[string]string{k: v})
		return b
	}
	run := func(p []byte) error { return e.trash.DeleteFile(ctx, p) }

	// Referenced by an asset row (also matched case-insensitively), a live
	// video row, or only by a reservation (an in-flight finalize).
	upper := a.OriginalPath[:len(a.OriginalPath)-4] + ".JPG"
	for _, rel := range []string{a.OriginalPath, upper, lv.OriginalPath} {
		if err := run(payload("path", rel)); err != nil {
			t.Fatalf("%s: %v", rel, err)
		}
	}
	reserved := "alice/2026/10/inflight.jpg"
	e.writeLib(t, reserved, "x")
	if err := (repository.LibraryPathsRepository{}).Reserve(ctx, e.st.W, repository.LibraryPath{
		PathKey: storage.PathKey(reserved), Path: reserved, UserID: e.alice.UserID,
	}); err != nil {
		t.Fatal(err)
	}
	if err := run(payload("path", reserved)); err != nil {
		t.Fatal(err)
	}
	for _, rel := range []string{a.OriginalPath, lv.OriginalPath, reserved} {
		if !exists(e.lib(rel)) {
			t.Fatalf("referenced %s deleted", rel)
		}
	}
	// A derived dir of a live asset is kept.
	e.writeDerived(t, a.ID, "thumb.jpg", "t")
	if err := run(payload("derived_asset_id", a.ID)); err != nil || !exists(e.derived(a.ID)) {
		t.Fatalf("derived dir of a live asset: %v", err)
	}
	// Unreferenced: removed; already gone: fine.
	orphan := "alice/2026/10/orphan.jpg"
	e.writeLib(t, orphan, "o")
	if err := run(payload("path", orphan)); err != nil || exists(e.lib(orphan)) {
		t.Fatalf("orphan: exists=%v err=%v", exists(e.lib(orphan)), err)
	}
	if err := run(payload("path", orphan)); err != nil {
		t.Fatalf("missing orphan: %v", err)
	}
	// Unsafe payloads are rejected without touching anything.
	outside := filepath.Join(e.libDir, "..", "outside.txt")
	if err := os.WriteFile(outside, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	e.writeLib(t, ".pictunnel-tmp/x.ptpart", "tmp")
	for _, bad := range [][]byte{payload("path", "../outside.txt"), payload("path", outside), payload("path", ""),
		payload("path", ".pictunnel-tmp/x.ptpart"), payload("derived_asset_id", "../x"), []byte("{"), []byte("{}")} {
		if err := run(bad); err == nil {
			t.Fatalf("payload %s accepted", bad)
		}
	}
	if !exists(outside) || !exists(e.lib(".pictunnel-tmp/x.ptpart")) {
		t.Fatal("unsafe payload deleted a file")
	}
}

func TestEmptyTrash(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	var trashed []string
	for i := 0; i < 3; i++ {
		trashed = append(trashed, e.seed(t, e.alice, fmt.Sprint("t", i)).ID)
	}
	active := e.seed(t, e.alice, "active")
	bobs := e.seed(t, e.bob, "bobs")
	if _, err := e.trash.Trash(ctx, e.alice, trashed); err != nil {
		t.Fatal(err)
	}
	if _, err := e.trash.Trash(ctx, e.bob, []string{bobs.ID}); err != nil {
		t.Fatal(err)
	}
	n, err := e.trash.Empty(ctx, e.alice)
	if err != nil || n != 3 {
		t.Fatalf("empty: %d %v", n, err)
	}
	for _, id := range trashed {
		if !e.assetGone(t, id) {
			t.Fatalf("%s survived empty", id)
		}
	}
	if e.assetGone(t, active.ID) || e.assetGone(t, bobs.ID) {
		t.Fatal("empty purged an active or foreign asset")
	}
	if n, err := e.trash.Empty(ctx, e.alice); err != nil || n != 0 {
		t.Fatalf("second empty: %d %v", n, err)
	}
}

func TestPurgeExpiredAfter30Days(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	old := e.seed(t, e.alice, "old")
	bobOld := e.seed(t, e.bob, "bob old")
	if _, err := e.trash.Trash(ctx, e.alice, []string{old.ID}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.trash.Trash(ctx, e.bob, []string{bobOld.ID}); err != nil {
		t.Fatal(err)
	}
	e.clk.Advance(20 * 24 * time.Hour)
	young := e.seed(t, e.alice, "young")
	if _, err := e.trash.Trash(ctx, e.alice, []string{young.ID}); err != nil {
		t.Fatal(err)
	}
	e.clk.Advance(9 * 24 * time.Hour) // day 29
	if err := e.trash.PurgeExpired(ctx); err != nil {
		t.Fatal(err)
	}
	if e.assetGone(t, old.ID) {
		t.Fatal("purged before 30 days")
	}
	e.clk.Advance(2 * 24 * time.Hour) // day 31
	if err := e.trash.PurgeExpired(ctx); err != nil {
		t.Fatal(err)
	}
	if !e.assetGone(t, old.ID) || !e.assetGone(t, bobOld.ID) || e.assetGone(t, young.ID) {
		t.Fatal("wrong assets purged")
	}
	if exists(e.lib(old.OriginalPath)) {
		t.Fatal("expired asset's file not removed")
	}
	for _, p := range []Principal{e.alice, e.bob} {
		ts, _, _, err := e.trash.ListTombstones(ctx, p, "", 0)
		if err != nil || len(ts) != 1 {
			t.Fatalf("%s tombstones: %+v %v", p.Username, ts, err)
		}
	}
	ch, _, _, err := e.feed.Changes(ctx, e.alice, EncodeCursor(0), 0)
	if err != nil {
		t.Fatal(err)
	}
	removed := false
	for _, c := range ch {
		removed = removed || (c.Kind == "asset.removed" && c.AssetID == old.ID)
	}
	if !removed {
		t.Fatalf("no asset.removed for the expired asset: %+v", ch)
	}
}

func TestTombstonesListAndDelete(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	var shas []string
	for i := 0; i < 5; i++ {
		sha := shaHex([]byte(fmt.Sprint("tomb", i)))
		shas = append(shas, sha)
		e.tombstone(t, e.alice, sha, fmt.Sprint("F", i, ".JPG"), t0.Add(time.Duration(i%3)*time.Hour))
	}
	e.tombstone(t, e.bob, shaHex([]byte("bob")), "B.JPG", t0)
	var got []repository.Tombstone
	cursor := ""
	pages := 0
	for {
		page, next, more, err := e.trash.ListTombstones(ctx, e.alice, cursor, 2)
		if err != nil {
			t.Fatal(err)
		}
		pages++
		got = append(got, page...)
		if more != (next != "") {
			t.Fatalf("has_more %v next %q", more, next)
		}
		if !more {
			break
		}
		cursor = next
	}
	if len(got) != 5 || pages != 3 {
		t.Fatalf("got %d tombstones in %d pages", len(got), pages)
	}
	for i := 1; i < len(got); i++ {
		p, c := got[i-1], got[i]
		if p.DeletedAt.Before(c.DeletedAt) || (p.DeletedAt.Equal(c.DeletedAt) && p.SHA256 >= c.SHA256) {
			t.Fatalf("order broken at %d: %+v then %+v", i, p, c)
		}
		if c.OwnerID != e.alice.UserID {
			t.Fatal("foreign tombstone listed")
		}
	}
	_, _, _, err := e.trash.ListTombstones(ctx, e.alice, "bogus", 2)
	wantCode(t, err, "invalid_request")

	if err := e.trash.DeleteTombstone(ctx, e.alice, shas[0]); err != nil {
		t.Fatal(err)
	}
	if err := e.trash.DeleteTombstone(ctx, e.alice, shas[0]); err != nil {
		t.Fatalf("idempotent delete: %v", err)
	}
	if err := e.trash.DeleteTombstone(ctx, e.alice, shaHex([]byte("bob"))); err != nil {
		t.Fatal(err)
	}
	if _, err := (repository.TombstonesRepository{}).Get(ctx, e.st.R, e.bob.UserID, shaHex([]byte("bob"))); err != nil {
		t.Fatal("alice deleted bob's tombstone")
	}
	err = e.trash.DeleteTombstone(ctx, e.alice, "NOT-A-SHA")
	wantCode(t, err, "invalid_request")
	list, _, _, _ := e.trash.ListTombstones(ctx, e.alice, "", 0)
	if len(list) != 4 {
		t.Fatalf("after delete: %d", len(list))
	}
}
