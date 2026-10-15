package service

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/store"
)

// AssetView is an asset with its Live Photo video component, if any.
type AssetView struct {
	repository.Asset
	Live *repository.LiveVideo
}

// Change is one change-feed entry. Asset is set for asset.upsert (the
// asset's current state); AssetID is always set.
type Change struct {
	Seq     int64
	Kind    string
	Asset   *AssetView
	AssetID string
}

// FeedServiceDeps are the FeedService dependencies.
type FeedServiceDeps struct {
	Store       *store.Store
	Assets      repository.AssetsRepository
	LiveVideos  repository.LiveVideosRepository
	ChangeLog   repository.ChangeLogRepository
	ServerState repository.ServerStateRepository
}

// FeedService serves the snapshot and the change feed (S§7, P§7.6).
type FeedService struct{ d FeedServiceDeps }

// NewFeedService returns a FeedService.
func NewFeedService(d FeedServiceDeps) *FeedService { return &FeedService{d: d} }

// readTx runs fn in a transaction on the reader pool so every read in fn
// sees one consistent WAL snapshot.
func readTx(ctx context.Context, st *store.Store, fn func(tx *sql.Tx) error) error {
	tx, err := st.R.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	return fn(tx)
}

// views attaches live videos to assets, preserving order.
func views(ctx context.Context, tx *sql.Tx, lvr repository.LiveVideosRepository, assets []repository.Asset) ([]AssetView, error) {
	out := make([]AssetView, len(assets))
	if len(assets) == 0 {
		return out, nil
	}
	ids := make([]string, len(assets))
	for i, a := range assets {
		ids[i] = a.ID
	}
	lvs, err := lvr.ListByAssets(ctx, tx, ids)
	if err != nil {
		return nil, err
	}
	byAsset := make(map[string]*repository.LiveVideo, len(lvs))
	for i := range lvs {
		byAsset[lvs[i].AssetID] = &lvs[i]
	}
	for i, a := range assets {
		out[i] = AssetView{Asset: a, Live: byAsset[a.ID]}
	}
	return out, nil
}

// Snapshot returns one page of the caller's assets (active and trashed)
// ordered by id. The first page records cursor = change-log head in the
// same read transaction; later pages carry it in pageToken.
func (s *FeedService) Snapshot(ctx context.Context, p Principal, pageToken string, limit int) (string, []AssetView, string, bool, error) {
	limit, err := pageLimit(limit, defaultSnapshotLimit)
	if err != nil {
		return "", nil, "", false, err
	}
	var cursor int64
	after := ""
	if pageToken != "" {
		parts, ok := decodeToken(pageToken, 2)
		if !ok {
			return "", nil, "", false, apperr.InvalidRequest("page_token is malformed")
		}
		if cursor, err = DecodeCursor(parts[0]); err != nil {
			return "", nil, "", false, apperr.InvalidRequest("page_token is malformed")
		}
		after = parts[1]
	}
	var page []AssetView
	err = readTx(ctx, s.d.Store, func(tx *sql.Tx) error {
		if pageToken == "" {
			h, err := s.d.ChangeLog.Head(ctx, tx)
			if err != nil {
				return err
			}
			cursor = h
		}
		rows, err := s.d.Assets.Page(ctx, tx, p.UserID, after, limit+1)
		if err != nil {
			return err
		}
		page, err = views(ctx, tx, s.d.LiveVideos, rows)
		return err
	})
	if err != nil {
		return "", nil, "", false, fmt.Errorf("snapshot: %w", err)
	}
	c := EncodeCursor(cursor)
	if len(page) <= limit {
		return c, page, "", false, nil
	}
	page = page[:limit]
	return c, page, encodeToken(c, page[limit-1].ID), true, nil
}

// Changes returns the caller's changes after cursor, by seq. next is the
// last returned seq (the input cursor when nothing was returned).
//
// Errors: missing cursor → cursor_required; malformed or ahead of the head →
// invalid_request; cursor ≤ change_log_floor (when the floor exists) →
// cursor_expired.
func (s *FeedService) Changes(ctx context.Context, p Principal, cursor string, limit int) ([]Change, string, bool, error) {
	if cursor == "" {
		return nil, "", false, apperr.CursorRequired()
	}
	c, err := DecodeCursor(cursor)
	if err != nil {
		return nil, "", false, apperr.InvalidRequest("cursor is malformed")
	}
	limit, err = pageLimit(limit, defaultChangesLimit)
	if err != nil {
		return nil, "", false, err
	}
	var out []Change
	next, more := cursor, false
	err = readTx(ctx, s.d.Store, func(tx *sql.Tx) error {
		head, err := s.d.ChangeLog.Head(ctx, tx)
		if err != nil {
			return err
		}
		if c > head {
			return apperr.InvalidRequest("cursor is ahead of the change log")
		}
		if fv, ok, err := s.d.ServerState.Get(ctx, tx, changeLogFloorKey); err != nil {
			return err
		} else if ok {
			floor, err := strconv.ParseInt(fv, 10, 64)
			if err != nil {
				return fmt.Errorf("bad %s %q: %w", changeLogFloorKey, fv, err)
			}
			if c <= floor {
				return apperr.CursorExpired()
			}
		}
		rows, err := s.d.ChangeLog.ListAfter(ctx, tx, p.UserID, c, limit+1)
		if err != nil {
			return err
		}
		if more = len(rows) > limit; more {
			rows = rows[:limit]
		}
		if len(rows) > 0 {
			next = EncodeCursor(rows[len(rows)-1].Seq)
		}
		var upsertIDs []string
		for _, r := range rows {
			if r.Kind == changeAssetUpsert {
				upsertIDs = append(upsertIDs, r.AssetID)
			}
		}
		assets, err := s.d.Assets.ListByIDs(ctx, tx, p.UserID, upsertIDs)
		if err != nil {
			return err
		}
		vs, err := views(ctx, tx, s.d.LiveVideos, assets)
		if err != nil {
			return err
		}
		byID := make(map[string]*AssetView, len(vs))
		for i := range vs {
			byID[vs[i].ID] = &vs[i]
		}
		out = make([]Change, 0, len(rows))
		for _, r := range rows {
			ch := Change{Seq: r.Seq, Kind: r.Kind, AssetID: r.AssetID}
			if r.Kind == changeAssetUpsert {
				// The asset's latest row is the only one kept, and purge
				// replaces it with asset.removed, so it is present here.
				ch.Asset = byID[r.AssetID]
				if ch.Asset == nil {
					continue
				}
			}
			out = append(out, ch)
		}
		return nil
	})
	if err != nil {
		if _, ok := apperr.As(err); ok {
			return nil, "", false, err
		}
		return nil, "", false, fmt.Errorf("changes: %w", err)
	}
	return out, next, more, nil
}
