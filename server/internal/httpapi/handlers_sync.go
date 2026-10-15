package httpapi

import (
	"context"

	"github.com/PrithvirajG/pictunnel/server/internal/apperr"
	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
)

// limitParam returns the limit query parameter; absent is 0 (the service
// default), anything outside 1..1000 is invalid_request.
func limitParam(p *int) (int, error) {
	if p == nil {
		return 0, nil
	}
	if *p < 1 || *p > 1000 {
		return 0, apperr.InvalidRequest("limit must be between 1 and 1000")
	}
	return *p, nil
}

// CheckContent runs a batch content check (P§7.2).
func (s *server) CheckContent(ctx context.Context, req gen.CheckContentRequestObject) (gen.CheckContentResponseObject, error) {
	p, err := principal(ctx)
	if err != nil {
		return nil, err
	}
	items := make([]service.CheckItem, 0, len(req.Body.Items))
	for _, it := range req.Body.Items {
		items = append(items, service.CheckItem{
			SHA256: it.Sha256, SizeBytes: it.SizeBytes, LocalID: optString(it.LocalId),
			ConfirmOnDisk: it.ConfirmOnDisk != nil && *it.ConfirmOnDisk,
		})
	}
	outs, err := s.d.Check.Check(ctx, p, items)
	if err != nil {
		return nil, err
	}
	var m mapper
	res := gen.CheckContent200JSONResponse{Results: make([]gen.CheckResult, 0, len(outs))}
	for _, o := range outs {
		res.Results = append(res.Results, m.checkResult(o))
	}
	return res, m.err
}

// GetChanges returns the caller's change feed after a cursor (P§7.6).
func (s *server) GetChanges(ctx context.Context, req gen.GetChangesRequestObject) (gen.GetChangesResponseObject, error) {
	p, err := principal(ctx)
	if err != nil {
		return nil, err
	}
	limit, err := limitParam(req.Params.Limit)
	if err != nil {
		return nil, err
	}
	changes, next, more, err := s.d.Feed.Changes(ctx, p, optString(req.Params.Cursor), limit)
	if err != nil {
		return nil, err
	}
	var m mapper
	out := gen.GetChanges200JSONResponse{Changes: make([]gen.ChangeEntry, 0, len(changes)), NextCursor: next, HasMore: more}
	for _, c := range changes {
		out.Changes = append(out.Changes, m.change(c))
	}
	return out, m.err
}

// GetSnapshot returns one snapshot page; the first page carries the cursor.
func (s *server) GetSnapshot(ctx context.Context, req gen.GetSnapshotRequestObject) (gen.GetSnapshotResponseObject, error) {
	p, err := principal(ctx)
	if err != nil {
		return nil, err
	}
	limit, err := limitParam(req.Params.Limit)
	if err != nil {
		return nil, err
	}
	pageToken := optString(req.Params.PageToken)
	cursor, page, next, more, err := s.d.Feed.Snapshot(ctx, p, pageToken, limit)
	if err != nil {
		return nil, err
	}
	var m mapper
	out := gen.GetSnapshot200JSONResponse{Assets: m.assets(page), HasMore: more}
	if pageToken == "" {
		out.Cursor = ptr(cursor)
	}
	if next != "" {
		out.NextPageToken = ptr(next)
	}
	return out, m.err
}

// ListTombstones pages the caller's tombstones, newest first.
func (s *server) ListTombstones(ctx context.Context, req gen.ListTombstonesRequestObject) (gen.ListTombstonesResponseObject, error) {
	p, err := principal(ctx)
	if err != nil {
		return nil, err
	}
	limit, err := limitParam(req.Params.Limit)
	if err != nil {
		return nil, err
	}
	ts, next, more, err := s.d.Trash.ListTombstones(ctx, p, optString(req.Params.Cursor), limit)
	if err != nil {
		return nil, err
	}
	out := gen.ListTombstones200JSONResponse{Tombstones: tombstones(ts), HasMore: more}
	if next != "" {
		out.NextCursor = ptr(next)
	}
	return out, nil
}

// DeleteTombstone removes a tombstone; absent is not an error.
func (s *server) DeleteTombstone(ctx context.Context, req gen.DeleteTombstoneRequestObject) (gen.DeleteTombstoneResponseObject, error) {
	p, err := principal(ctx)
	if err != nil {
		return nil, err
	}
	if err := s.d.Trash.DeleteTombstone(ctx, p, req.Sha256); err != nil {
		return nil, err
	}
	return gen.DeleteTombstone204Response{}, nil
}
