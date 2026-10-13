-- name: InsertWebSession :exec
INSERT INTO web_sessions (token_hash, device_id, csrf_hash, expires_at, last_used_at)
VALUES (?, ?, ?, ?, ?);

-- name: GetWebSession :one
SELECT * FROM web_sessions WHERE token_hash = ?;

-- name: TouchWebSession :execrows
UPDATE web_sessions SET last_used_at = ?, expires_at = ? WHERE token_hash = ?;

-- name: DeleteWebSessionsByDevice :exec
DELETE FROM web_sessions WHERE device_id = ?;

-- name: DeleteExpiredWebSessions :execrows
DELETE FROM web_sessions WHERE expires_at < ?;
