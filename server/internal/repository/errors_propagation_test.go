package repository_test

import (
	"context"
	"errors"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/repository/repotest"
)

// TestDriverErrorsPropagate runs every read and write against a closed
// database. Each must return the driver error itself: never nil (a
// swallowed failure), never ErrNotFound (a failure mistaken for a missing
// row) and never ErrUniqueViolation.
func TestDriverErrorsPropagate(t *testing.T) {
	ctx := context.Background()
	s := repotest.NewStore(t)
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	db := s.R
	shas := []string{"sha1"}
	var (
		assets    repository.AssetsRepository
		access    repository.AccessTokensRepository
		sources   repository.AssetSourcesRepository
		audit     repository.AuditLogRepository
		changes   repository.ChangeLogRepository
		devices   repository.DevicesRepository
		jobs      repository.JobsRepository
		paths     repository.LibraryPathsRepository
		lives     repository.LiveVideosRepository
		pairing   repository.PairingCodesRepository
		refresh   repository.RefreshTokensRepository
		state     repository.ServerStateRepository
		tombs     repository.TombstonesRepository
		sessions  repository.UploadSessionsRepository
		users     repository.UsersRepository
		web       repository.WebSessionsRepository
		discarded any
	)
	calls := map[string]func() error{
		"Assets.Get":               func() (err error) { discarded, err = assets.Get(ctx, db, "o", "a"); return },
		"Assets.GetByID":           func() (err error) { discarded, err = assets.GetByID(ctx, db, "a"); return },
		"Assets.GetBySHA":          func() (err error) { discarded, err = assets.GetBySHA(ctx, db, "o", "sha1"); return },
		"Assets.ListBySHAs":        func() (err error) { discarded, err = assets.ListBySHAs(ctx, db, "o", shas); return },
		"Assets.ListTrashed":       func() (err error) { discarded, err = assets.ListTrashed(ctx, db, "o"); return },
		"Assets.ListTrashedBefore": func() (err error) { discarded, err = assets.ListTrashedBefore(ctx, db, "o", ts, 10); return },
		"Assets.Page":              func() (err error) { discarded, err = assets.Page(ctx, db, "o", "", 10); return },
		"Assets.SumSizes":          func() (err error) { discarded, err = assets.SumSizes(ctx, db, "o"); return },
		"Assets.SetKind":           func() error { return assets.SetKind(ctx, db, "a", "video") },
		"Assets.StackIDForKey":     func() (err error) { _, discarded, err = assets.StackIDForKey(ctx, db, "o", "k"); return },
		"Assets.ListByIDs":         func() (err error) { discarded, err = assets.ListByIDs(ctx, db, "o", []string{"a"}); return },
		"Assets.PathReferenced":    func() (err error) { discarded, err = assets.PathReferenced(ctx, db, "p"); return },
		"Assets.ListMediaPending":  func() (err error) { discarded, err = assets.ListMediaPending(ctx, db); return },
		"Assets.Insert":            func() error { return assets.Insert(ctx, db, newAsset("a", "o", "sha1")) },
		"AccessTokens.Get":         func() (err error) { discarded, err = access.Get(ctx, db, "h"); return },
		"AccessTokens.Expired":     func() (err error) { discarded, err = access.DeleteExpired(ctx, db, ts); return },
		"AssetSources.ListByAsset": func() (err error) { discarded, err = sources.ListByAsset(ctx, db, "a"); return },
		"AuditLog.List":            func() (err error) { discarded, err = audit.List(ctx, db, 10); return },
		"ChangeLog.ListAfter":      func() (err error) { discarded, err = changes.ListAfter(ctx, db, "o", 0, 10); return },
		"ChangeLog.Head":           func() (err error) { discarded, err = changes.Head(ctx, db); return },
		"ChangeLog.DeleteBefore":   func() (err error) { _, discarded, err = changes.DeleteBefore(ctx, db, ts); return },
		"Devices.Get":              func() (err error) { discarded, err = devices.Get(ctx, db, "d"); return },
		"Devices.ListByUser":       func() (err error) { discarded, err = devices.ListByUser(ctx, db, "u"); return },
		"Jobs.Enqueue": func() (err error) {
			discarded, err = jobs.Enqueue(ctx, db, repository.Job{ID: "j", Kind: "k", DedupeKey: "d", Payload: "{}", RunAfter: ts, CreatedAt: ts, UpdatedAt: ts})
			return
		},
		"Jobs.LeaseNext":            func() (err error) { discarded, err = jobs.LeaseNext(ctx, db, []string{"k"}, ts, ts); return },
		"Jobs.ListPending":          func() (err error) { discarded, err = jobs.ListPending(ctx, db, "k"); return },
		"Jobs.Counts":               func() (err error) { discarded, err = jobs.Counts(ctx, db); return },
		"LibraryPaths.Exists":       func() (err error) { discarded, err = paths.Exists(ctx, db, "p"); return },
		"LibraryPaths.ListAll":      func() (err error) { discarded, err = paths.ListAll(ctx, db); return },
		"LiveVideos.GetByAsset":     func() (err error) { discarded, err = lives.GetByAsset(ctx, db, "a"); return },
		"LiveVideos.ListByAssets":   func() (err error) { discarded, err = lives.ListByAssets(ctx, db, []string{"a"}); return },
		"LiveVideos.SumSizes":       func() (err error) { discarded, err = lives.SumSizes(ctx, db, "o"); return },
		"PairingCodes.Get":          func() (err error) { discarded, err = pairing.Get(ctx, db, "h"); return },
		"PairingCodes.MarkRedeemed": func() (err error) { discarded, err = pairing.MarkRedeemed(ctx, db, "h", ts); return },
		"RefreshTokens.Get":         func() (err error) { discarded, err = refresh.Get(ctx, db, "h"); return },
		"RefreshTokens.MarkRotated": func() (err error) { discarded, err = refresh.MarkRotated(ctx, db, "h", ts); return },
		"ServerState.Get":           func() (err error) { _, discarded, err = state.Get(ctx, db, "k"); return },
		"Tombstones.Get":            func() (err error) { discarded, err = tombs.Get(ctx, db, "o", "sha1"); return },
		"Tombstones.ListBySHAs":     func() (err error) { discarded, err = tombs.ListBySHAs(ctx, db, "o", shas); return },
		"Tombstones.Delete":         func() (err error) { discarded, err = tombs.Delete(ctx, db, "o", "sha1"); return },
		"Tombstones.Page":           func() (err error) { discarded, err = tombs.Page(ctx, db, "o", ts, "", 10); return },
		"UploadSessions.Get":        func() (err error) { discarded, err = sessions.Get(ctx, db, "u"); return },
		"UploadSessions.GetActive":  func() (err error) { discarded, err = sessions.GetActive(ctx, db, "o", "sha1"); return },
		"UploadSessions.ListActive": func() (err error) { discarded, err = sessions.ListActiveBySHAs(ctx, db, "o", shas); return },
		"UploadSessions.ListByState": func() (err error) {
			discarded, err = sessions.ListByState(ctx, db, "receiving")
			return
		},
		"UploadSessions.ListExpired": func() (err error) { discarded, err = sessions.ListExpired(ctx, db, ts); return },
		"UploadSessions.ListStuck":   func() (err error) { discarded, err = sessions.ListStuckFinalizing(ctx, db, ts); return },
		"UploadSessions.SetMetaJSON": func() error { return sessions.SetMetaJSON(ctx, db, "u", "{}") },
		"UploadSessions.SumActive":   func() (err error) { discarded, err = sessions.SumActiveLengths(ctx, db, "o"); return },
		"Users.GetByID":              func() (err error) { discarded, err = users.GetByID(ctx, db, "u"); return },
		"Users.GetByUsername":        func() (err error) { discarded, err = users.GetByUsername(ctx, db, "u"); return },
		"Users.Count":                func() (err error) { discarded, err = users.Count(ctx, db); return },
		"Users.List":                 func() (err error) { discarded, err = users.List(ctx, db); return },
		"WebSessions.Get":            func() (err error) { discarded, err = web.Get(ctx, db, "h"); return },
	}
	for name, call := range calls {
		err := call()
		if err == nil || errors.Is(err, repository.ErrNotFound) || errors.Is(err, repository.ErrUniqueViolation) {
			t.Errorf("%s on a closed database: %v", name, err)
		}
	}
	_ = discarded
}
