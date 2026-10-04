# 0008. One-way backup with trash and tombstones

- Status: Accepted (2026-10-03)

## Context
Two-way sync lets a phone mishap delete the backup. Pure append-only storage gives users no way to remove things.

## Decision
Phone deletions never propagate. Server deletions move assets to a 30-day Trash. Purging an asset records a tombstone `(owner_id, sha256)` so phones do not upload it again unless the user chooses "back up again". "Free up space" on the phone is opt-in and requires a fresh on-disk confirmation from the server.

## Consequences
The server is a safe archive. Tombstones must be visible and reversible so users are not confused when a photo stops backing up.
