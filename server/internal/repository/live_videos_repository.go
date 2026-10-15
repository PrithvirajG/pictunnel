package repository

import (
	"context"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// LiveVideo is a row of the live_videos table (the paired video of a Live
// Photo asset).
type LiveVideo struct {
	AssetID      string
	OwnerID      string
	SHA256       string
	SizeBytes    int64
	Mime         string
	Filename     string
	OriginalPath string
	CreatedAt    time.Time
}

// LiveVideosRepository accesses the live_videos table.
type LiveVideosRepository struct{}

func liveVideoFromRow(r queries.LiveVideo) (LiveVideo, error) {
	created, err := parseTime(r.CreatedAt)
	if err != nil {
		return LiveVideo{}, err
	}
	return LiveVideo{
		AssetID: r.AssetID, OwnerID: r.OwnerID, SHA256: r.Sha256, SizeBytes: r.SizeBytes, Mime: r.Mime,
		Filename: r.Filename, OriginalPath: r.OriginalPath, CreatedAt: created,
	}, nil
}

// Insert adds a live video row.
func (LiveVideosRepository) Insert(ctx context.Context, db queries.DBTX, v LiveVideo) error {
	return mapErr(queries.New(db).InsertLiveVideo(ctx, queries.InsertLiveVideoParams{
		AssetID: v.AssetID, OwnerID: v.OwnerID, Sha256: v.SHA256, SizeBytes: v.SizeBytes, Mime: v.Mime,
		Filename: v.Filename, OriginalPath: v.OriginalPath, CreatedAt: formatTime(v.CreatedAt),
	}))
}

// GetByAsset returns the live video of an asset or ErrNotFound.
func (LiveVideosRepository) GetByAsset(ctx context.Context, db queries.DBTX, assetID string) (LiveVideo, error) {
	r, err := queries.New(db).GetLiveVideoByAsset(ctx, assetID)
	if err != nil {
		return LiveVideo{}, mapErr(err)
	}
	return liveVideoFromRow(r)
}

// ListByAssets returns the live videos for the given asset ids.
func (LiveVideosRepository) ListByAssets(ctx context.Context, db queries.DBTX, assetIDs []string) ([]LiveVideo, error) {
	rows, err := queries.New(db).ListLiveVideosByAssets(ctx, assetIDs)
	if err != nil {
		return nil, err
	}
	out := make([]LiveVideo, 0, len(rows))
	for _, r := range rows {
		v, err := liveVideoFromRow(r)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, nil
}

// SumSizes returns the total size of the owner's live videos.
func (LiveVideosRepository) SumSizes(ctx context.Context, db queries.DBTX, ownerID string) (int64, error) {
	return queries.New(db).SumLiveVideoSizes(ctx, ownerID)
}

// PathReferenced reports whether any live video's original_path equals path
// (ASCII case-insensitively).
func (LiveVideosRepository) PathReferenced(ctx context.Context, db queries.DBTX, path string) (bool, error) {
	n, err := queries.New(db).LiveVideoPathReferenced(ctx, path)
	return n != 0, err
}
