# 0012. Deterministic refresh-token successors

- Status: Accepted (2026-10-13)

## Context
ADR 0011 requires that presenting a just-rotated refresh token within the 30 s grace window returns the same successor pair, because a background engine and the foreground app may refresh at the same moment. Only token hashes are stored, so the plaintext successor cannot be looked up. Storing plaintext successors would weaken the database, and keeping them in memory would lose the grace window on restart.

## Decision
On refresh, the successor pair is derived rather than drawn at random:

- `rt' = pt_rt_ + b64url(HMAC-SHA256(k, "rt|" + rt))`
- `at' = pt_at_ + b64url(HMAC-SHA256(k, "at|" + rt))`

`k` is a 32-byte server secret stored in `<data>/secret.key` with mode 0600. Presenting the rotated `rt` again within 30 s recomputes the same pair and the same stored expiry times. After 30 s, the same request revokes the token family, writes an audit event, revokes the device and returns `401 refresh_token_reused`.

## Consequences
Refresh is idempotent without storing plaintext tokens, and the grace window survives restarts. The server now holds a long-lived secret. A leaked `secret.key` lets an attacker who knows a rotated refresh token derive its successors, so the file must be kept out of the library and backed up with care. Rotating `k` makes any refresh inside the grace window fail once.
