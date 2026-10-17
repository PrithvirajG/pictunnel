package service

import (
	"context"
	"database/sql"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/storage"
)

func readAll(t *testing.T, f storage.File) string {
	t.Helper()
	defer f.Close()
	b, err := io.ReadAll(f)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestOriginalOwnerScoped(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	a := e.seed(t, e.alice, "alice original")
	lv := e.attachLive(t, a, "alice live")
	v, err := e.assets.Get(ctx, e.alice, a.ID)
	if err != nil || v.ID != a.ID || v.Live == nil || v.Live.SHA256 != lv.SHA256 {
		t.Fatalf("Get: %+v %v", v, err)
	}
	f, got, err := e.assets.OpenOriginal(ctx, e.alice, a.ID)
	if err != nil {
		t.Fatal(err)
	}
	if readAll(t, f) != "alice original" || got.ID != a.ID || got.Mime != "image/jpeg" {
		t.Fatalf("original: %+v", got)
	}
	_, err = e.assets.Get(ctx, e.bob, a.ID)
	wantCode(t, err, "not_found")
	_, _, err = e.assets.OpenOriginal(ctx, e.bob, a.ID)
	wantCode(t, err, "not_found")
	_, _, err = e.assets.OpenThumbnail(ctx, e.bob, a.ID, "thumb")
	wantCode(t, err, "not_found")
	_, _, err = e.assets.OpenPlayback(ctx, e.bob, a.ID)
	wantCode(t, err, "not_found")
	_, err = e.assets.Get(ctx, e.alice, "not-an-id")
	wantCode(t, err, "not_found")
	// A trashed asset is still readable by its owner.
	if _, err := e.trash.Trash(ctx, e.alice, []string{a.ID}); err != nil {
		t.Fatal(err)
	}
	if v, err := e.assets.Get(ctx, e.alice, a.ID); err != nil || v.State != "trashed" {
		t.Fatalf("trashed Get: %+v %v", v, err)
	}
	// A row whose file vanished is not_found, not a 500.
	if err := os.Remove(e.lib(a.OriginalPath)); err != nil {
		t.Fatal(err)
	}
	_, _, err = e.assets.OpenOriginal(ctx, e.alice, a.ID)
	wantCode(t, err, "not_found")
}

func setThumbsReady(t *testing.T, e *senv, a repository.Asset) {
	t.Helper()
	ctx := context.Background()
	err := e.st.WithTx(ctx, func(tx *sql.Tx) error {
		return repository.AssetsRepository{}.SetThumbnailsReady(ctx, tx, a.ID, a.UpdatedSeq)
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestThumbnailRules(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	a := e.seed(t, e.alice, "photo")
	_, _, err := e.assets.OpenThumbnail(ctx, e.alice, a.ID, "thumb")
	wantCode(t, err, "not_ready")
	e.writeDerived(t, a.ID, "thumb.jpg", "small")
	_, _, err = e.assets.OpenThumbnail(ctx, e.alice, a.ID, "thumb")
	wantCode(t, err, "not_ready") // flag not set yet
	setThumbsReady(t, e, a)
	f, got, err := e.assets.OpenThumbnail(ctx, e.alice, a.ID, "")
	if err != nil || readAll(t, f) != "small" || got.SHA256 != a.SHA256 {
		t.Fatalf("default size: %+v %v", got, err)
	}
	_, _, err = e.assets.OpenThumbnail(ctx, e.alice, a.ID, "preview")
	wantCode(t, err, "not_ready") // derived file missing
	e.writeDerived(t, a.ID, "preview.jpg", "big")
	f, _, err = e.assets.OpenThumbnail(ctx, e.alice, a.ID, "preview")
	if err != nil || readAll(t, f) != "big" {
		t.Fatalf("preview: %v", err)
	}
	_, _, err = e.assets.OpenThumbnail(ctx, e.alice, a.ID, "huge")
	wantCode(t, err, "invalid_request")
}

func TestPlaybackRules(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	photo := e.seed(t, e.alice, "photo")
	_, _, err := e.assets.OpenPlayback(ctx, e.alice, photo.ID)
	wantCode(t, err, "not_found")

	setPlayable := func(a repository.Asset, playable bool) {
		t.Helper()
		err := e.st.WithTx(ctx, func(tx *sql.Tx) error {
			return repository.AssetsRepository{}.UpdateMetadata(ctx, tx, a.ID, repository.MetadataUpdate{
				TakenAtSource: a.TakenAtSource, Playable: &playable,
			}, a.UpdatedSeq)
		})
		if err != nil {
			t.Fatal(err)
		}
	}

	mp4 := e.seed(t, e.alice, "h264 video", withMime("video/mp4", "video"))
	// Metadata not extracted yet: playability unknown → not_ready.
	_, _, err = e.assets.OpenPlayback(ctx, e.alice, mp4.ID)
	wantCode(t, err, "not_ready")
	setPlayable(mp4, true)
	f, mime, err := e.assets.OpenPlayback(ctx, e.alice, mp4.ID)
	if err != nil || mime != "video/mp4" || readAll(t, f) != "h264 video" {
		t.Fatalf("playable original: %q %v", mime, err)
	}

	hevc := e.seed(t, e.alice, "hevc video", withMime("video/quicktime", "video"))
	setPlayable(hevc, false)
	_, _, err = e.assets.OpenPlayback(ctx, e.alice, hevc.ID)
	wantCode(t, err, "not_ready")
	e.writeDerived(t, hevc.ID, "web.mp4", "transcoded")
	f, mime, err = e.assets.OpenPlayback(ctx, e.alice, hevc.ID)
	if err != nil || mime != "video/mp4" || readAll(t, f) != "transcoded" {
		t.Fatalf("transcoded: %q %v", mime, err)
	}

	live := e.seed(t, e.alice, "live still")
	e.attachLive(t, live, "live motion")
	f, mime, err = e.assets.OpenPlayback(ctx, e.alice, live.ID)
	if err != nil || mime != "video/quicktime" || readAll(t, f) != "live motion" {
		t.Fatalf("live playback: %q %v", mime, err)
	}
}

// TestPlaybackMissingFilesAreNotFound: a library file that vanished from
// disk is not_found (the client stops retrying), never an internal error;
// a Live Photo row without its video component is not_found too.
func TestPlaybackMissingFilesAreNotFound(t *testing.T) {
	e := newSenv(t)
	ctx := context.Background()
	playable := true
	mp4 := e.seed(t, e.alice, "h264 video", withMime("video/mp4", "video"))
	err := e.st.WithTx(ctx, func(tx *sql.Tx) error {
		return repository.AssetsRepository{}.UpdateMetadata(ctx, tx, mp4.ID, repository.MetadataUpdate{
			TakenAtSource: mp4.TakenAtSource, Playable: &playable,
		}, mp4.UpdatedSeq)
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(e.libDir, filepath.FromSlash(mp4.OriginalPath))); err != nil {
		t.Fatal(err)
	}
	_, _, err = e.assets.OpenPlayback(ctx, e.alice, mp4.ID)
	wantCode(t, err, "not_found")
	_, _, err = e.assets.OpenOriginal(ctx, e.alice, mp4.ID)
	wantCode(t, err, "not_found")

	live := e.seed(t, e.alice, "live still")
	e.attachLive(t, live, "live motion")
	lv, err := repository.LiveVideosRepository{}.GetByAsset(ctx, e.st.R, live.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(e.libDir, filepath.FromSlash(lv.OriginalPath))); err != nil {
		t.Fatal(err)
	}
	_, _, err = e.assets.OpenPlayback(ctx, e.alice, live.ID)
	wantCode(t, err, "not_found")

	orphan := e.seed(t, e.alice, "orphan still", withMime("image/heic", assetKindLive))
	_, _, err = e.assets.OpenPlayback(ctx, e.alice, orphan.ID)
	wantCode(t, err, "not_found")
}
