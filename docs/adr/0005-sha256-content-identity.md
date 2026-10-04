# 0005. SHA-256 content identity with per-user dedup

- Status: Accepted (2026-10-03)

## Context
Users must never get duplicates from retries, reinstalls or second phones, and the server must not leak whether another user owns a file.

## Decision
An asset's identity is the SHA-256 of its original bytes, lowercase hex. The database enforces `UNIQUE(owner_id, sha256)`. The check endpoint only reports on the caller's own content. Edited renditions are separate assets grouped in a stack.

## Consequences
Dedup is exact and cheap to verify on every platform with hardware-accelerated SHA-256. Identical files owned by two users are stored twice; this is the price of not leaking existence across accounts.
