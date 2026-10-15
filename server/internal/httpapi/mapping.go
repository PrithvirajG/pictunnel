package httpapi

import (
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
	"github.com/PrithvirajG/pictunnel/server/internal/repository"
	"github.com/PrithvirajG/pictunnel/server/internal/service"
)

// mapper converts repository and service views to gen models. IDs are
// parsed as UUIDs; the first parse failure is kept in err (an internal
// error: stored ids are always UUIDs). nil pointers stay nil, which the
// generated models omit.
type mapper struct{ err error }

func (m *mapper) uuid(s string) uuid.UUID {
	u, err := uuid.Parse(s)
	if err != nil && m.err == nil {
		m.err = fmt.Errorf("map: bad uuid %q: %w", s, err)
	}
	return u
}

func (m *mapper) uuidPtr(s *string) *uuid.UUID {
	if s == nil {
		return nil
	}
	u := m.uuid(*s)
	return &u
}

func utc(t time.Time) time.Time { return t.UTC() }

func utcPtr(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	u := t.UTC()
	return &u
}

func intPtr(v *int64) *int {
	if v == nil {
		return nil
	}
	i := int(*v)
	return &i
}

func ptr[T any](v T) *T { return &v }

func (m *mapper) user(u repository.User) gen.User {
	return gen.User{Id: m.uuid(u.ID), Username: u.Username, DisplayName: u.DisplayName, Role: u.Role}
}

func (m *mapper) device(d repository.Device) gen.Device {
	return gen.Device{
		Id: m.uuid(d.ID), Name: d.Name, Platform: d.Platform, AppVersion: d.AppVersion,
		CreatedAt: utc(d.CreatedAt), LastSeenAt: utcPtr(d.LastSeenAt),
	}
}

func tokenPair(tp service.TokenPair) gen.TokenPair {
	return gen.TokenPair{
		AccessToken: tp.AccessToken, AccessTokenExpiresAt: utc(tp.AccessExpiresAt),
		RefreshToken: tp.RefreshToken, RefreshTokenExpiresAt: utc(tp.RefreshExpiresAt),
	}
}

func (m *mapper) asset(v service.AssetView) gen.Asset {
	a := v.Asset
	out := gen.Asset{
		Id: m.uuid(a.ID), Sha256: a.SHA256, SizeBytes: a.SizeBytes, Mime: a.Mime, Kind: a.Kind,
		Filename: a.Filename, TakenAt: utcPtr(a.TakenAt), TakenAtOffsetMinutes: intPtr(a.TakenAtOffsetMinutes),
		TakenAtSource: a.TakenAtSource, Width: intPtr(a.Width), Height: intPtr(a.Height), DurationMs: a.DurationMs,
		Lat: a.Lat, Lon: a.Lon, State: a.State, TrashedAt: utcPtr(a.TrashedAt), StackId: m.uuidPtr(a.StackID),
		ThumbnailsReady: a.ThumbnailsReady, CreatedAt: utc(a.CreatedAt), UpdatedSeq: a.UpdatedSeq,
	}
	if v.Live != nil {
		out.LiveVideo = &gen.LiveVideo{Sha256: v.Live.SHA256, SizeBytes: v.Live.SizeBytes, Mime: v.Live.Mime}
	}
	return out
}

func (m *mapper) assets(vs []service.AssetView) []gen.Asset {
	out := make([]gen.Asset, 0, len(vs))
	for _, v := range vs {
		out = append(out, m.asset(v))
	}
	return out
}

// uploadURL is the tus resource URL of an upload session.
func uploadURL(id string) string { return pathUploads + "/" + id }

func (m *mapper) checkResult(o service.CheckOutcome) gen.CheckResult {
	r := gen.CheckResult{Sha256: o.SHA256, Verdict: o.Verdict, OnDisk: o.OnDisk, DeletedAt: utcPtr(o.DeletedAt)}
	if o.Asset != nil {
		r.AssetId = ptr(m.uuid(o.Asset.ID))
		r.AssetState = ptr(o.Asset.State)
		r.HasLiveVideo = ptr(o.HasLiveVideo)
	}
	if o.Upload != nil {
		r.Upload = &gen.UploadRef{
			Id: o.Upload.ID, Url: uploadURL(o.Upload.ID), Offset: o.Upload.Offset, Length: o.Upload.Length,
			ExpiresAt: utc(o.Upload.ExpiresAt),
		}
	}
	return r
}

func (m *mapper) change(c service.Change) gen.ChangeEntry {
	e := gen.ChangeEntry{Seq: c.Seq, Kind: c.Kind}
	if c.Asset != nil {
		e.Asset = ptr(m.asset(*c.Asset))
	} else if c.AssetID != "" {
		e.AssetId = ptr(m.uuid(c.AssetID))
	}
	return e
}

func (m *mapper) bulk(r service.BulkResult) gen.BulkResult {
	out := gen.BulkResult{
		Succeeded: make([]uuid.UUID, 0, len(r.Succeeded)),
		Failed:    make([]gen.BulkFailure, 0, len(r.Failed)),
	}
	for _, id := range r.Succeeded {
		out.Succeeded = append(out.Succeeded, m.uuid(id))
	}
	for _, f := range r.Failed {
		out.Failed = append(out.Failed, gen.BulkFailure{AssetId: m.uuid(f.AssetID), Code: f.Code})
	}
	return out
}

func tombstones(ts []repository.Tombstone) []gen.Tombstone {
	out := make([]gen.Tombstone, 0, len(ts))
	for _, t := range ts {
		out = append(out, gen.Tombstone{Sha256: t.SHA256, Filename: t.Filename, DeletedAt: utc(t.DeletedAt)})
	}
	return out
}

func idStrings(ids []uuid.UUID) []string {
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		out = append(out, id.String())
	}
	return out
}

// optString and optInt dereference optional parameters.
func optString(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func optInt(p *int) int {
	if p == nil {
		return 0
	}
	return *p
}
