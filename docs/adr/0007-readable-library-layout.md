# 0007. Human-readable library layout

- Status: Accepted (2026-10-03)

## Context
Self-hosters distrust opaque storage; competitors added readable "storage templates" after user demand.

## Decision
Store originals at `<library>/<user>/<YYYY>/<MM>/<filename>`. The path is fixed at ingest and never moved. Collisions are detected case-insensitively after NFC normalization and resolved with `~2`, `~3`. The library is documented as read-only from outside; a weekly fsck reports drift and `import_library` can rebuild the catalog.

## Consequences
No lock-in: photos are plain files. Path sanitization and collision handling need careful tests. End-to-end encryption, if ever added, will need a different layout.
