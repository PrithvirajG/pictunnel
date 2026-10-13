-- name: AppendChange :one
INSERT INTO change_log (owner_id, kind, asset_id, created_at) VALUES (?, ?, ?, ?) RETURNING seq;

-- name: DeleteChangesForAsset :execrows
DELETE FROM change_log WHERE asset_id = ? AND seq <> ?;

-- name: ListChangesAfter :many
SELECT * FROM change_log WHERE owner_id = ? AND seq > ? ORDER BY seq LIMIT ?;

-- name: MaxChangeSeqBefore :one
SELECT CAST(COALESCE(MAX(seq), 0) AS INTEGER) FROM change_log WHERE created_at < ?;

-- name: DeleteChangesBefore :execrows
DELETE FROM change_log WHERE created_at < ?;
