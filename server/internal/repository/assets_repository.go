package repository

import (
	"context"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// Asset is a row of the assets table.
type Asset struct {
	ID                   string
	OwnerID              string
	SHA256               string
	SizeBytes            int64
	Mime                 string
	Kind                 string
	Filename             string
	OriginalPath         string
	TakenAt              *time.Time
	TakenAtOffsetMinutes *int64
	TakenAtSource        string
	Width                *int64
	Height               *int64
	DurationMs           *int64
	Lat                  *float64
	Lon                  *float64
	State                string
	TrashedAt            *time.Time
	StackKey             *string
	StackID              *string
	ThumbnailsReady      bool
	VideoCodec           *string
	AudioCodec           *string
	Container            *string
	Playable             *bool
	CreatedAt            time.Time
	UpdatedSeq           int64
}

// MetadataUpdate carries the extracted metadata columns replaced by
// UpdateMetadata. Every field is written as given (nil clears a nullable).
type MetadataUpdate struct {
	TakenAt              *time.Time
	TakenAtOffsetMinutes *int64
	TakenAtSource        string
	Width                *int64
	Height               *int64
	DurationMs           *int64
	Lat                  *float64
	Lon                  *float64
	StackKey             *string
	StackID              *string
	VideoCodec           *string
	AudioCodec           *string
	Container            *string
	Playable             *bool
}

// AssetsRepository accesses the assets table.
type AssetsRepository struct{}

func boolPtrToInt(b *bool) *int64 {
	if b == nil {
		return nil
	}
	v := boolInt(*b)
	return &v
}

func intPtrToBool(i *int64) *bool {
	if i == nil {
		return nil
	}
	b := *i != 0
	return &b
}

func assetFromRow(r queries.Asset) (Asset, error) {
	created, err := parseTime(r.CreatedAt)
	if err != nil {
		return Asset{}, err
	}
	taken, err := parseTimePtr(r.TakenAt)
	if err != nil {
		return Asset{}, err
	}
	trashed, err := parseTimePtr(r.TrashedAt)
	if err != nil {
		return Asset{}, err
	}
	return Asset{
		ID: r.ID, OwnerID: r.OwnerID, SHA256: r.Sha256, SizeBytes: r.SizeBytes, Mime: r.Mime, Kind: r.Kind,
		Filename: r.Filename, OriginalPath: r.OriginalPath, TakenAt: taken, TakenAtOffsetMinutes: r.TakenAtOffsetMinutes,
		TakenAtSource: r.TakenAtSource, Width: r.Width, Height: r.Height, DurationMs: r.DurationMs, Lat: r.Lat, Lon: r.Lon,
		State: r.State, TrashedAt: trashed, StackKey: r.StackKey, StackID: r.StackID, ThumbnailsReady: r.ThumbnailsReady != 0,
		VideoCodec: r.VideoCodec, AudioCodec: r.AudioCodec, Container: r.Container, Playable: intPtrToBool(r.Playable),
		CreatedAt: created, UpdatedSeq: r.UpdatedSeq,
	}, nil
}

func assetsFromRows(rows []queries.Asset) ([]Asset, error) {
	out := make([]Asset, 0, len(rows))
	for _, r := range rows {
		a, err := assetFromRow(r)
		if err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, nil
}

// Insert adds an asset; ErrUniqueViolation on a duplicate id or
// (owner_id, sha256).
func (AssetsRepository) Insert(ctx context.Context, db queries.DBTX, a Asset) error {
	return mapErr(queries.New(db).InsertAsset(ctx, queries.InsertAssetParams{
		ID: a.ID, OwnerID: a.OwnerID, Sha256: a.SHA256, SizeBytes: a.SizeBytes, Mime: a.Mime, Kind: a.Kind,
		Filename: a.Filename, OriginalPath: a.OriginalPath, TakenAt: formatTimePtr(a.TakenAt),
		TakenAtOffsetMinutes: a.TakenAtOffsetMinutes, TakenAtSource: a.TakenAtSource, Width: a.Width, Height: a.Height,
		DurationMs: a.DurationMs, Lat: a.Lat, Lon: a.Lon, State: a.State, TrashedAt: formatTimePtr(a.TrashedAt),
		StackKey: a.StackKey, StackID: a.StackID, ThumbnailsReady: boolInt(a.ThumbnailsReady), VideoCodec: a.VideoCodec,
		AudioCodec: a.AudioCodec, Container: a.Container, Playable: boolPtrToInt(a.Playable),
		CreatedAt: formatTime(a.CreatedAt), UpdatedSeq: a.UpdatedSeq,
	}))
}

// Get returns the owner's asset or ErrNotFound.
func (AssetsRepository) Get(ctx context.Context, db queries.DBTX, ownerID, id string) (Asset, error) {
	r, err := queries.New(db).GetAsset(ctx, queries.GetAssetParams{OwnerID: ownerID, ID: id})
	if err != nil {
		return Asset{}, mapErr(err)
	}
	return assetFromRow(r)
}

// GetByID returns the asset regardless of owner (for background jobs).
func (AssetsRepository) GetByID(ctx context.Context, db queries.DBTX, id string) (Asset, error) {
	r, err := queries.New(db).GetAssetByID(ctx, id)
	if err != nil {
		return Asset{}, mapErr(err)
	}
	return assetFromRow(r)
}

// GetBySHA returns the owner's asset with the content hash or ErrNotFound.
func (AssetsRepository) GetBySHA(ctx context.Context, db queries.DBTX, ownerID, sha string) (Asset, error) {
	r, err := queries.New(db).GetAssetBySHA(ctx, queries.GetAssetBySHAParams{OwnerID: ownerID, Sha256: sha})
	if err != nil {
		return Asset{}, mapErr(err)
	}
	return assetFromRow(r)
}

// ListBySHAs returns the owner's assets whose hash is in shas, ordered by id.
func (AssetsRepository) ListBySHAs(ctx context.Context, db queries.DBTX, ownerID string, shas []string) ([]Asset, error) {
	rows, err := queries.New(db).ListAssetsBySHAs(ctx, queries.ListAssetsBySHAsParams{OwnerID: ownerID, Shas: shas})
	if err != nil {
		return nil, err
	}
	return assetsFromRows(rows)
}

// SetState sets state and trashed_at and stamps updated_seq.
func (AssetsRepository) SetState(ctx context.Context, db queries.DBTX, id, state string, trashedAt *time.Time, seq int64) error {
	return requireRow(queries.New(db).SetAssetState(ctx, queries.SetAssetStateParams{
		State: state, TrashedAt: formatTimePtr(trashedAt), UpdatedSeq: seq, ID: id,
	}))
}

// SetUpdatedSeq stamps updated_seq.
func (AssetsRepository) SetUpdatedSeq(ctx context.Context, db queries.DBTX, id string, seq int64) error {
	return requireRow(queries.New(db).SetAssetUpdatedSeq(ctx, queries.SetAssetUpdatedSeqParams{UpdatedSeq: seq, ID: id}))
}

// UpdateMetadata replaces the extracted metadata columns and stamps updated_seq.
func (AssetsRepository) UpdateMetadata(ctx context.Context, db queries.DBTX, id string, m MetadataUpdate, seq int64) error {
	return requireRow(queries.New(db).UpdateAssetMetadata(ctx, queries.UpdateAssetMetadataParams{
		TakenAt: formatTimePtr(m.TakenAt), TakenAtOffsetMinutes: m.TakenAtOffsetMinutes, TakenAtSource: m.TakenAtSource,
		Width: m.Width, Height: m.Height, DurationMs: m.DurationMs, Lat: m.Lat, Lon: m.Lon,
		StackKey: m.StackKey, StackID: m.StackID, VideoCodec: m.VideoCodec, AudioCodec: m.AudioCodec,
		Container: m.Container, Playable: boolPtrToInt(m.Playable), UpdatedSeq: seq, ID: id,
	}))
}

// SetThumbnailsReady marks thumbnails as generated and stamps updated_seq.
func (AssetsRepository) SetThumbnailsReady(ctx context.Context, db queries.DBTX, id string, seq int64) error {
	return requireRow(queries.New(db).SetAssetThumbnailsReady(ctx, queries.SetAssetThumbnailsReadyParams{UpdatedSeq: seq, ID: id}))
}

// Delete removes the asset row.
func (AssetsRepository) Delete(ctx context.Context, db queries.DBTX, id string) error {
	return requireRow(queries.New(db).DeleteAsset(ctx, id))
}

// ListTrashedBefore returns trashed assets with trashed_at strictly before
// the cutoff, oldest first. An empty ownerID means every owner.
func (AssetsRepository) ListTrashedBefore(ctx context.Context, db queries.DBTX, ownerID string, before time.Time, limit int) ([]Asset, error) {
	b := formatTime(before)
	rows, err := queries.New(db).ListAssetsTrashedBefore(ctx, queries.ListAssetsTrashedBeforeParams{
		Before: &b, OwnerID: ownerID, RowLimit: int64(limit),
	})
	if err != nil {
		return nil, err
	}
	return assetsFromRows(rows)
}

// ListTrashed returns the owner's trashed assets, newest trashed first.
func (AssetsRepository) ListTrashed(ctx context.Context, db queries.DBTX, ownerID string) ([]Asset, error) {
	rows, err := queries.New(db).ListTrashedAssets(ctx, ownerID)
	if err != nil {
		return nil, err
	}
	return assetsFromRows(rows)
}

// Page returns up to limit of the owner's assets with id > afterID, by id.
func (AssetsRepository) Page(ctx context.Context, db queries.DBTX, ownerID, afterID string, limit int) ([]Asset, error) {
	rows, err := queries.New(db).PageAssets(ctx, queries.PageAssetsParams{OwnerID: ownerID, ID: afterID, Limit: int64(limit)})
	if err != nil {
		return nil, err
	}
	return assetsFromRows(rows)
}

// SumSizes returns the total size_bytes of the owner's assets.
func (AssetsRepository) SumSizes(ctx context.Context, db queries.DBTX, ownerID string) (int64, error) {
	return queries.New(db).SumAssetSizes(ctx, ownerID)
}
