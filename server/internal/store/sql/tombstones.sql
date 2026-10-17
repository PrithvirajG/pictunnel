-- name: InsertTombstone :exec
INSERT INTO tombstones (owner_id, sha256, filename, deleted_at) VALUES (?, ?, ?, ?)
ON CONFLICT(owner_id, sha256) DO UPDATE SET filename = excluded.filename, deleted_at = excluded.deleted_at;

-- name: GetTombstone :one
SELECT * FROM tombstones WHERE owner_id = ? AND sha256 = ?;

-- name: ListTombstonesBySHAs :many
SELECT * FROM tombstones WHERE owner_id = sqlc.arg(owner_id) AND sha256 IN (sqlc.slice(shas)) ORDER BY sha256;

-- name: DeleteTombstone :execrows
DELETE FROM tombstones WHERE owner_id = ? AND sha256 = ?;

-- name: PageTombstones :many
SELECT * FROM tombstones
WHERE owner_id = sqlc.arg(owner_id)
  AND (sqlc.arg(after_deleted_at) = '' OR deleted_at < sqlc.arg(after_deleted_at)
       OR (deleted_at = sqlc.arg(after_deleted_at) AND sha256 > sqlc.arg(after_sha)))
ORDER BY deleted_at DESC, sha256 ASC LIMIT sqlc.arg(row_limit);
