package repository

import (
	"context"

	"github.com/PrithvirajG/pictunnel/server/internal/store/queries"
)

// LibraryPath is a row of the library_paths table: a reserved on-disk path.
type LibraryPath struct {
	PathKey  string // normalised (case-folded) key; unique
	Path     string // the path as written to disk
	UserID   string
	UploadID *string
	AssetID  *string
}

// LibraryPathsRepository accesses the library_paths table.
type LibraryPathsRepository struct{}

// Reserve claims a path; ErrUniqueViolation when path_key is already taken.
func (LibraryPathsRepository) Reserve(ctx context.Context, db queries.DBTX, p LibraryPath) error {
	return mapErr(queries.New(db).ReserveLibraryPath(ctx, queries.ReserveLibraryPathParams{
		PathKey: p.PathKey, Path: p.Path, UserID: p.UserID, UploadID: p.UploadID, AssetID: p.AssetID,
	}))
}

// Exists reports whether the path_key is reserved.
func (LibraryPathsRepository) Exists(ctx context.Context, db queries.DBTX, pathKey string) (bool, error) {
	n, err := queries.New(db).LibraryPathExists(ctx, pathKey)
	return n != 0, err
}

// PointToAsset links a reserved path to its asset.
func (LibraryPathsRepository) PointToAsset(ctx context.Context, db queries.DBTX, pathKey, assetID string) error {
	return requireRow(queries.New(db).PointLibraryPathToAsset(ctx, queries.PointLibraryPathToAssetParams{AssetID: &assetID, PathKey: pathKey}))
}

// ReleaseByUpload frees every path reserved by the upload session.
func (LibraryPathsRepository) ReleaseByUpload(ctx context.Context, db queries.DBTX, uploadID string) error {
	_, err := queries.New(db).ReleaseLibraryPathsByUpload(ctx, &uploadID)
	return err
}

// ReleaseByAsset frees every path pointing at the asset.
func (LibraryPathsRepository) ReleaseByAsset(ctx context.Context, db queries.DBTX, assetID string) error {
	_, err := queries.New(db).ReleaseLibraryPathsByAsset(ctx, &assetID)
	return err
}

// ListAll returns every reservation (for the orphan sweep).
func (LibraryPathsRepository) ListAll(ctx context.Context, db queries.DBTX) ([]LibraryPath, error) {
	rows, err := queries.New(db).ListAllLibraryPaths(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]LibraryPath, 0, len(rows))
	for _, r := range rows {
		out = append(out, LibraryPath{PathKey: r.PathKey, Path: r.Path, UserID: r.UserID, UploadID: r.UploadID, AssetID: r.AssetID})
	}
	return out, nil
}
