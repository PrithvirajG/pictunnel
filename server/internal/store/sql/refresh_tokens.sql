-- name: InsertRefreshToken :exec
INSERT INTO refresh_tokens (token_hash, device_id, family_id, state, issued_at, rotated_at, expires_at)
VALUES (?, ?, ?, ?, ?, ?, ?);

-- name: GetRefreshToken :one
SELECT * FROM refresh_tokens WHERE token_hash = ?;

-- name: MarkRefreshTokenRotated :execrows
UPDATE refresh_tokens SET state = 'rotated', rotated_at = ?
WHERE token_hash = ? AND state = 'active';

-- name: RevokeRefreshTokenFamily :exec
UPDATE refresh_tokens SET state = 'revoked' WHERE family_id = ?;

-- name: RevokeRefreshTokensByDevice :exec
UPDATE refresh_tokens SET state = 'revoked' WHERE device_id = ?;

-- name: DeleteExpiredRefreshTokens :execrows
DELETE FROM refresh_tokens WHERE expires_at < ?;
