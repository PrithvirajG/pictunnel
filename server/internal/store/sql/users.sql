-- name: InsertUser :exec
INSERT INTO users (id, username, slug, display_name, role, password_hash, quota_bytes, created_at, disabled_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);

-- name: GetUserByID :one
SELECT * FROM users WHERE id = ?;

-- name: GetUserByUsername :one
SELECT * FROM users WHERE username = ? COLLATE NOCASE;

-- name: CountUsers :one
SELECT COUNT(*) FROM users;

-- name: SetUserPasswordHash :execrows
UPDATE users SET password_hash = ? WHERE id = ?;

-- name: ListUsers :many
SELECT * FROM users ORDER BY created_at, id;
