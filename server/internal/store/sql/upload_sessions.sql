-- name: InsertUploadSession :exec
INSERT INTO upload_sessions (
    id, owner_id, device_id, sha256, length, "offset", state, pair_role, pair_sha256, meta_json,
    staging_path, dest_path, asset_id, asset_created, failure_code, created_at, updated_at, expires_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);

-- name: GetUploadSession :one
SELECT * FROM upload_sessions WHERE id = ?;

-- name: GetActiveUploadSession :one
SELECT * FROM upload_sessions
WHERE owner_id = ? AND sha256 = ? AND state IN ('receiving', 'finalizing');

-- name: ListActiveUploadSessionsBySHAs :many
SELECT * FROM upload_sessions
WHERE owner_id = sqlc.arg(owner_id) AND sha256 IN (sqlc.slice(shas)) AND state IN ('receiving', 'finalizing')
ORDER BY id;

-- name: UpdateUploadSessionOffset :execrows
UPDATE upload_sessions SET "offset" = ?, updated_at = ?, expires_at = ? WHERE id = ?;

-- name: SetUploadSessionFinalizing :execrows
UPDATE upload_sessions SET state = 'finalizing', dest_path = ?, updated_at = ? WHERE id = ?;

-- name: SetUploadSessionDone :execrows
UPDATE upload_sessions SET state = 'done', asset_id = ?, asset_created = ?, updated_at = ? WHERE id = ?;

-- name: SetUploadSessionFailed :execrows
UPDATE upload_sessions SET state = 'failed', failure_code = ?, updated_at = ? WHERE id = ?;

-- name: ListUploadSessionsByState :many
SELECT * FROM upload_sessions WHERE state = ? ORDER BY created_at, id;

-- name: ListExpiredUploadSessions :many
SELECT * FROM upload_sessions WHERE state = 'receiving' AND expires_at < ? ORDER BY expires_at, id;

-- name: ListStuckFinalizingUploadSessions :many
SELECT * FROM upload_sessions WHERE state = 'finalizing' AND updated_at < ? ORDER BY updated_at, id;

-- name: DeleteUploadSessionsOlderThan :execrows
DELETE FROM upload_sessions WHERE updated_at < sqlc.arg(before) AND state IN (sqlc.slice(states));

-- name: DeleteUploadSession :execrows
DELETE FROM upload_sessions WHERE id = ?;

-- name: SumActiveUploadLengths :one
SELECT CAST(COALESCE(SUM(length), 0) AS INTEGER) FROM upload_sessions
WHERE owner_id = ? AND state IN ('receiving', 'finalizing');
