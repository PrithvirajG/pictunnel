-- name: ReserveLibraryPath :exec
INSERT INTO library_paths (path_key, path, user_id, upload_id, asset_id) VALUES (?, ?, ?, ?, ?);

-- name: LibraryPathExists :one
SELECT EXISTS(SELECT 1 FROM library_paths WHERE path_key = ?);

-- name: PointLibraryPathToAsset :execrows
UPDATE library_paths SET asset_id = ? WHERE path_key = ?;

-- name: ReleaseLibraryPathsByUpload :execrows
DELETE FROM library_paths WHERE upload_id = ?;

-- name: ReleaseLibraryPathsByAsset :execrows
DELETE FROM library_paths WHERE asset_id = ?;

-- name: ListAllLibraryPaths :many
SELECT * FROM library_paths ORDER BY path_key;
