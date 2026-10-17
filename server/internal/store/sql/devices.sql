-- name: InsertDevice :exec
INSERT INTO devices (id, user_id, name, platform, app_version, created_at, last_seen_at, revoked_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?);

-- name: GetDevice :one
SELECT * FROM devices WHERE id = ?;

-- name: ListDevicesByUser :many
SELECT * FROM devices WHERE user_id = ? AND revoked_at IS NULL ORDER BY created_at, id;

-- name: RenameDevice :execrows
UPDATE devices SET name = ? WHERE id = ?;

-- name: RevokeDevice :execrows
UPDATE devices SET revoked_at = ? WHERE id = ?;

-- name: TouchDeviceLastSeen :execrows
UPDATE devices SET last_seen_at = ? WHERE id = ?;
