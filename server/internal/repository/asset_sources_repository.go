package repository

import (
	"context"
	"time"

	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// AssetSource records that a device's local item maps to a server asset.
type AssetSource struct {
	DeviceID  string
	LocalID   string
	AssetID   string
	CreatedAt time.Time
}

// AssetSourcesRepository accesses the asset_sources table.
type AssetSourcesRepository struct{}

// Upsert maps (deviceID, localID) to assetID, repointing an existing mapping.
func (AssetSourcesRepository) Upsert(ctx context.Context, db queries.DBTX, deviceID, localID, assetID string, at time.Time) error {
	return mapErr(queries.New(db).UpsertAssetSource(ctx, queries.UpsertAssetSourceParams{
		DeviceID: deviceID, LocalID: localID, AssetID: assetID, CreatedAt: formatTime(at),
	}))
}

// ListByAsset returns every device mapping of the asset.
func (AssetSourcesRepository) ListByAsset(ctx context.Context, db queries.DBTX, assetID string) ([]AssetSource, error) {
	rows, err := queries.New(db).ListAssetSourcesByAsset(ctx, assetID)
	if err != nil {
		return nil, err
	}
	out := make([]AssetSource, 0, len(rows))
	for _, r := range rows {
		c, err := parseTime(r.CreatedAt)
		if err != nil {
			return nil, err
		}
		out = append(out, AssetSource{DeviceID: r.DeviceID, LocalID: r.LocalID, AssetID: r.AssetID, CreatedAt: c})
	}
	return out, nil
}
