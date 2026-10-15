-- name: InsertAsset :exec
INSERT INTO assets (
    id, owner_id, sha256, size_bytes, mime, kind, filename, original_path,
    taken_at, taken_at_offset_minutes, taken_at_source, width, height, duration_ms, lat, lon,
    state, trashed_at, stack_key, stack_id, thumbnails_ready, video_codec, audio_codec, container,
    playable, created_at, updated_seq
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);

-- name: GetAsset :one
SELECT * FROM assets WHERE owner_id = ? AND id = ?;

-- name: GetAssetByID :one
SELECT * FROM assets WHERE id = ?;

-- name: GetAssetBySHA :one
SELECT * FROM assets WHERE owner_id = ? AND sha256 = ?;

-- name: ListAssetsBySHAs :many
SELECT * FROM assets WHERE owner_id = sqlc.arg(owner_id) AND sha256 IN (sqlc.slice(shas)) ORDER BY id;

-- name: SetAssetState :execrows
UPDATE assets SET state = ?, trashed_at = ?, updated_seq = ? WHERE id = ?;

-- name: SetAssetUpdatedSeq :execrows
UPDATE assets SET updated_seq = ? WHERE id = ?;

-- name: UpdateAssetMetadata :execrows
UPDATE assets SET
    taken_at = ?, taken_at_offset_minutes = ?, taken_at_source = ?,
    width = ?, height = ?, duration_ms = ?, lat = ?, lon = ?,
    stack_key = ?, stack_id = ?, video_codec = ?, audio_codec = ?, container = ?, playable = ?,
    updated_seq = ?
WHERE id = ?;

-- name: SetAssetThumbnailsReady :execrows
UPDATE assets SET thumbnails_ready = 1, updated_seq = ? WHERE id = ?;

-- name: DeleteAsset :execrows
DELETE FROM assets WHERE id = ?;

-- name: ListAssetsTrashedBefore :many
SELECT * FROM assets
WHERE state = 'trashed' AND trashed_at < sqlc.arg(before)
  AND (sqlc.arg(owner_id) = '' OR owner_id = sqlc.arg(owner_id))
ORDER BY trashed_at, id LIMIT sqlc.arg(row_limit);

-- name: ListTrashedAssets :many
SELECT * FROM assets WHERE owner_id = ? AND state = 'trashed' ORDER BY trashed_at DESC, id;

-- name: PageAssets :many
SELECT * FROM assets WHERE owner_id = ? AND id > ? ORDER BY id LIMIT ?;

-- name: SumAssetSizes :one
SELECT CAST(COALESCE(SUM(size_bytes), 0) AS INTEGER) FROM assets WHERE owner_id = ?;

-- name: ListAssetsByIDs :many
SELECT * FROM assets WHERE owner_id = sqlc.arg(owner_id) AND id IN (sqlc.slice(ids)) ORDER BY id;

-- name: AssetPathReferenced :one
SELECT EXISTS(SELECT 1 FROM assets WHERE original_path = sqlc.arg(path) COLLATE NOCASE);

-- name: ListAssetsMediaPending :many
SELECT id, kind, thumbnails_ready, playable FROM assets
WHERE thumbnails_ready = 0 OR (kind = 'video' AND (playable IS NULL OR playable = 0))
ORDER BY id;
