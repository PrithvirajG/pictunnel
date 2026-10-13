-- name: EnqueueJob :execrows
INSERT INTO jobs (id, kind, dedupe_key, payload, state, attempts, max_attempts, run_after, lease_until, last_error, created_at, updated_at)
VALUES (?, ?, ?, ?, 'pending', 0, ?, ?, NULL, NULL, ?, ?)
ON CONFLICT DO NOTHING;

-- name: LeaseNextJob :one
UPDATE jobs SET state = 'running', attempts = attempts + 1, lease_until = sqlc.arg(lease_until), updated_at = sqlc.arg(now)
WHERE id = (
    SELECT j.id FROM jobs j
    WHERE j.kind IN (sqlc.slice(kinds))
      AND ((j.state = 'pending' AND j.run_after <= sqlc.arg(now))
        OR (j.state = 'running' AND j.lease_until < sqlc.arg(now)))
    ORDER BY j.run_after, j.id LIMIT 1
)
RETURNING *;

-- name: ExtendJobLease :execrows
UPDATE jobs SET lease_until = ?, updated_at = ? WHERE id = ? AND state = 'running';

-- name: CompleteJob :execrows
UPDATE jobs SET state = 'done', lease_until = NULL, updated_at = ? WHERE id = ?;

-- name: FailJob :execrows
UPDATE jobs SET state = 'pending', last_error = ?, run_after = ?, lease_until = NULL, updated_at = ? WHERE id = ?;

-- name: DeadJob :execrows
UPDATE jobs SET state = 'dead', last_error = ?, lease_until = NULL, updated_at = ? WHERE id = ?;

-- name: ListPendingJobs :many
SELECT * FROM jobs WHERE kind = ? AND state IN ('pending', 'running') ORDER BY run_after, id;

-- name: JobCounts :many
SELECT kind, state, COUNT(*) AS n FROM jobs GROUP BY kind, state ORDER BY kind, state;
