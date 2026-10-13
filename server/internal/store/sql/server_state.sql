-- name: GetServerState :one
SELECT value FROM server_state WHERE key = ?;

-- name: UpsertServerState :exec
INSERT INTO server_state (key, value) VALUES (?, ?)
ON CONFLICT(key) DO UPDATE SET value = excluded.value;
