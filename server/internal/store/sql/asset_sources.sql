-- name: UpsertAssetSource :exec
INSERT INTO asset_sources (device_id, local_id, asset_id, created_at) VALUES (?, ?, ?, ?)
ON CONFLICT(device_id, local_id) DO UPDATE SET asset_id = excluded.asset_id;

-- name: ListAssetSourcesByAsset :many
SELECT * FROM asset_sources WHERE asset_id = ? ORDER BY device_id, local_id;
