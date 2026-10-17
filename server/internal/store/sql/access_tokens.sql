-- name: InsertAccessToken :exec
INSERT INTO access_tokens (token_hash, device_id, expires_at) VALUES (?, ?, ?);

-- name: GetAccessToken :one
SELECT * FROM access_tokens WHERE token_hash = ?;

-- name: DeleteAccessTokensByDevice :exec
DELETE FROM access_tokens WHERE device_id = ?;

-- name: DeleteExpiredAccessTokens :execrows
DELETE FROM access_tokens WHERE expires_at < ?;
