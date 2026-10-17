-- name: InsertPairingCode :exec
INSERT INTO pairing_codes (code_hash, user_id, created_at, expires_at, redeemed_at, invalidated_at)
VALUES (?, ?, ?, ?, ?, ?);

-- name: GetPairingCode :one
SELECT * FROM pairing_codes WHERE code_hash = ?;

-- name: MarkPairingCodeRedeemed :execrows
UPDATE pairing_codes SET redeemed_at = sqlc.arg(at)
WHERE code_hash = sqlc.arg(code_hash)
  AND redeemed_at IS NULL AND invalidated_at IS NULL AND expires_at >= sqlc.arg(at);

-- name: InvalidateOutstandingPairingCodes :execrows
UPDATE pairing_codes SET invalidated_at = sqlc.arg(now)
WHERE redeemed_at IS NULL AND invalidated_at IS NULL AND expires_at >= sqlc.arg(now);

-- name: DeleteExpiredPairingCodes :execrows
DELETE FROM pairing_codes WHERE expires_at < ?;
