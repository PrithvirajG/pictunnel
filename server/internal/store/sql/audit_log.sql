-- name: AppendAuditEvent :exec
INSERT INTO audit_log (id, at, user_id, device_id, event, detail_json) VALUES (?, ?, ?, ?, ?, ?);

-- name: ListAuditEvents :many
SELECT * FROM audit_log ORDER BY at DESC, id DESC LIMIT ?;
