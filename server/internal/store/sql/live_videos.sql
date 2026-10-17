-- name: InsertLiveVideo :exec
INSERT INTO live_videos (asset_id, owner_id, sha256, size_bytes, mime, filename, original_path, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?);

-- name: GetLiveVideoByAsset :one
SELECT * FROM live_videos WHERE asset_id = ?;

-- name: ListLiveVideosByAssets :many
SELECT * FROM live_videos WHERE asset_id IN (sqlc.slice(asset_ids)) ORDER BY asset_id;

-- name: SumLiveVideoSizes :one
SELECT CAST(COALESCE(SUM(size_bytes), 0) AS INTEGER) FROM live_videos WHERE owner_id = ?;

-- name: LiveVideoPathReferenced :one
SELECT EXISTS(SELECT 1 FROM live_videos WHERE original_path = sqlc.arg(path) COLLATE NOCASE);
