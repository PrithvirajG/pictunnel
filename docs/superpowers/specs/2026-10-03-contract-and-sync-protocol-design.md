# Sub-project 1 — Contract, Sync Protocol & Repository Foundation

- **Status:** Draft for review (2026-10-03)
- **Parent:** [`2026-10-03-pictunnel-system-design.md`](./2026-10-03-pictunnel-system-design.md)
- **Milestone:** M0 Foundations (2 weeks)

The key words MUST, MUST NOT, SHOULD and MAY are normative as in RFC 2119.

---

## 1. Purpose and scope

Every other sub-project depends on this one. It fixes **what goes over the wire** and **how sync behaves**, so the server (sub-project 2), the native engines and Flutter app (3) and the web viewer (4) can be built in parallel against one contract and one set of executable test vectors.

### In scope
1. `api/openapi.yaml` — OpenAPI 3.1 contract for the v1 endpoints listed in §4.
2. `api/protocol/sync-protocol.md` — the normative protocol (§5–§9 of this spec, expanded with examples).
3. `api/protocol/vectors/` — machine-readable conformance vectors + JSON Schema (§10).
4. Code generation for Go, Dart, Kotlin, Swift and TypeScript, committed and drift-checked (§11).
5. Monorepo skeleton, licenses, contributor docs, CI for all stacks (§12).
6. ADRs 0001–0011 (§13).
7. A minimal vector-runner in Go, Kotlin and Swift that passes the hashing vectors, proving the cross-language harness works (§10.4).

### Out of scope
Implementing server behavior (sub-project 2), the backup engines and app UI (3), the web UI (4), albums/sharing/search/admin/ML endpoints (5, 6 — they extend the contract additively), packaging (7).

## 2. Deliverables (file map)

```
api/
├── LICENSE                         # Apache-2.0
├── openapi.yaml
├── redocly.yaml                    # lint rules + engine-subset filter
└── protocol/
    ├── sync-protocol.md
    ├── fixtures/                   # tiny binary fixtures (< 64 KB each)
    └── vectors/
        ├── vectors.schema.json
        ├── hashing/*.json
        ├── server-scenarios/*.json
        ├── client-decisions/*.json
        └── pairing/*.json
server/internal/httpapi/gen/        # generated Go (types + strict server interface)
server/internal/conformance/        # Go vector loader + hashing runner
mobile/packages/pictunnel_api/      # generated Dart client package
mobile/android/engine-api/          # generated Kotlin (engine subset) + vector runner tests
mobile/ios/EngineAPI/               # generated Swift (engine subset) + vector runner tests
web/src/lib/api/schema.d.ts         # generated TS types
docs/adr/0001…0011-*.md
Taskfile.yml, .github/workflows/*, LICENSE, README.md, CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md,
.gitignore, .gitattributes, .editorconfig
```

## 3. API conventions

| Topic | Rule |
|---|---|
| Base path | `/api/v1`. Health endpoints `/healthz`, `/readyz` sit outside it. |
| Format | JSON, UTF-8, `snake_case` field names. |
| IDs | UUIDv7 strings. |
| Content hashes | Lowercase hex SHA-256, pattern `^[0-9a-f]{64}$`. |
| Times | RFC 3339 UTC (`Z`). Capture times add `taken_at_offset_minutes` (nullable). |
| Errors | RFC 9457 `application/problem+json`: `type` = `urn:pictunnel:problem:<code>`, `title`, `status`, `detail`, and a stable `code` (catalogue in §8). Extra fields allowed per code. |
| Auth | `Authorization: Bearer pt_at_…` for apps; HttpOnly session cookie + `X-CSRF-Token` for the web viewer. |
| Pagination | Opaque base64url `cursor` / `page_token`; `limit` default 200, max 1000 unless stated. |
| Request IDs | Server echoes `X-Request-Id` or generates one; included in problem bodies as `request_id`. |
| Rate limits | `429` + `Retry-After` (seconds). |
| Compatibility | Within v1, changes MUST be additive. Clients MUST ignore unknown fields and MUST treat unknown enum values per §9 R7. Breaking changes require `/api/v2`. |
| Version gate | `426 Upgrade Required` with code `client_too_old` when `PicTunnel-Client: <platform>/<version>` is below `min_client_version`. |

## 4. Endpoint catalogue (v1, defined in M0)

Tags marked **engine** form the subset generated for the native Kotlin/Swift engines.

| Method & path | Auth | Tag | Purpose |
|---|---|---|---|
| `GET /api/v1/server/info` | none | engine, server | Server id, name, version, `api_version`, `min_client_version` per platform, `capabilities[]`, upload limits (`max_file_bytes`, `recommended_chunk_bytes`), server `time` |
| `POST /api/v1/auth/setup` | none | auth | Create first admin; `409 setup_already_done` afterwards |
| `POST /api/v1/auth/login` | none | auth | Password login → tokens (apps) or session cookie (web) |
| `POST /api/v1/auth/refresh` | refresh token | engine, auth | Rotate refresh token, new access token (§6.2) |
| `POST /api/v1/auth/logout` | bearer | auth | Revoke current device session |
| `POST /api/v1/pairing/codes` | bearer/cookie | pairing | Create a one-time pairing code for the caller's account → `code`, `qr_uri`, `expires_at` |
| `POST /api/v1/pairing/redeem` | none | pairing | Exchange code + device info for device credentials |
| `GET /api/v1/devices` | bearer/cookie | devices | List caller's devices |
| `PATCH /api/v1/devices/{device_id}` | bearer/cookie | devices | Rename |
| `DELETE /api/v1/devices/{device_id}` | bearer/cookie | devices | Revoke a device |
| `POST /api/v1/sync/check` | bearer | engine, sync | Batch content check (§7.2) |
| `GET /api/v1/sync/changes` | bearer/cookie | sync | Delta change feed (§7.6) |
| `GET /api/v1/sync/snapshot` | bearer/cookie | sync | Full metadata snapshot (§7.6) |
| `OPTIONS /api/v1/uploads` | none | engine, uploads | tus capability discovery |
| `POST /api/v1/uploads` | bearer/cookie | engine, uploads | tus create / create-with-upload (§7.3) |
| `HEAD /api/v1/uploads/{upload_id}` | bearer/cookie | engine, uploads | tus offset query |
| `PATCH /api/v1/uploads/{upload_id}` | bearer/cookie | engine, uploads | tus append |
| `DELETE /api/v1/uploads/{upload_id}` | bearer/cookie | engine, uploads | tus termination |
| `GET /api/v1/assets/{asset_id}` | bearer/cookie | assets | Asset metadata |
| `GET /api/v1/assets/{asset_id}/thumbnail?size=thumb\|preview` | bearer/cookie | assets | JPEG derivative; `404 not_ready` until generated |
| `GET /api/v1/assets/{asset_id}/original` | bearer/cookie | assets | Original bytes; `Range`, `ETag: "<sha256>"`, `Content-Disposition` |
| `GET /api/v1/assets/{asset_id}/playback` | bearer/cookie | assets | Browser-playable video (original or transcode) |
| `POST /api/v1/assets/trash` | bearer/cookie | assets | `{asset_ids[]}` → state `trashed` |
| `POST /api/v1/assets/restore` | bearer/cookie | assets | `{asset_ids[]}` → state `active` |
| `POST /api/v1/assets/purge` | bearer/cookie | assets | `{asset_ids[]}` (must be trashed) → delete + tombstone |
| `POST /api/v1/trash/empty` | bearer/cookie | assets | Purge all trashed assets of caller |
| `GET /api/v1/tombstones` | bearer/cookie | assets | List caller's tombstones (paginated) |
| `DELETE /api/v1/tombstones/{sha256}` | bearer/cookie | engine, assets | Remove a tombstone ("back up again") |

Tags `users`, `albums`, `shares`, `search`, `admin`, `ml` are reserved; their endpoints are added by later specs.

### 4.1 Asset object (v1 fields)

| Field | Type | Notes |
|---|---|---|
| `id` | uuid | |
| `sha256` | hex | identity |
| `size_bytes` | int64 | |
| `mime` | string | |
| `kind` | enum `photo` \| `video` \| `live_photo` | |
| `filename` | string | original name from the device |
| `taken_at` | datetime, nullable | |
| `taken_at_offset_minutes` | int, nullable | |
| `taken_at_source` | enum `exif` \| `container` \| `client` \| `file` \| `unknown` | |
| `width`, `height` | int, nullable | null until metadata job runs |
| `duration_ms` | int, nullable | video / live component |
| `lat`, `lon` | number, nullable | |
| `state` | enum `active` \| `trashed` | |
| `trashed_at` | datetime, nullable | |
| `stack_id` | uuid, nullable | edits/bursts grouping |
| `live_video` | object, nullable | `{sha256, size_bytes, mime}` |
| `thumbnails_ready` | bool | |
| `created_at` | datetime | server ingest time |
| `updated_seq` | int64 | change-log sequence of last change |

## 5. Content identity and hashing

- H1. Identity is SHA-256 over the **exact bytes of the original resource** as the OS exposes it: on iOS the `PHAssetResource` bytes (see H3), on Android the MediaStore file bytes. No re-encoding, no metadata stripping.
- H2. Encoding is lowercase hex (64 chars).
- H3. iOS edited photos: the engine backs up the **current rendition** (`fullSizePhoto`/`fullSizeVideo` when present, else `photo`/`video`). If the user enables "also back up unedited originals", the unedited resource is uploaded as a separate asset with the same `stack_key`.
- H4. Live Photos / motion photos: the still is the primary asset. The paired video is uploaded as a separate tus upload with metadata `pair_role=live_video` and `pair_sha256=<primary sha256>`. The server attaches it as the primary's `live_video`; it is not a standalone asset in listings. Engines MUST upload the primary first; a `live_video` upload whose primary does not exist is rejected with `409 pair_primary_missing`. An `exists` check result for a primary reports `has_live_video`, so an engine that crashed between the two uploads detects and uploads the missing component. Re-uploading a component that is already attached resolves like outcome #3 of §7.3. Android motion photos with the video embedded in the JPEG are a single file and need no pairing.
- H5. Dedup scope is per user: `UNIQUE(owner_id, sha256)`. The check endpoint MUST NOT reveal anything about other users' content.

## 6. Authentication, pairing and discovery

### 6.1 Tokens
| Token | Format | Lifetime | Storage |
|---|---|---|---|
| Access | `pt_at_` + 32 random bytes base64url | 15 min | server stores SHA-256 hash; client keeps in memory |
| Refresh | `pt_rt_` + 32 random bytes base64url | expires 90 days after last use | server stores hash + `family_id`; client stores in Keychain/Keystore |

Prefixes make leaked tokens detectable by secret scanners. Opaque tokens (not JWT) are chosen so revocation is immediate and no signing keys need managing (ADR 0011).

### 6.2 Refresh rotation
- Every successful refresh issues a new refresh token and marks the old one `rotated` with `rotated_at`.
- **Grace window:** presenting a `rotated` token within 30 s of rotation returns the **same** successor pair (idempotent refresh — background engine and foreground app may race).
- Presenting a `rotated` token after the grace window is **reuse**: the whole family is revoked, an audit event is written, and the response is `401 refresh_token_reused` (client must re-pair).

### 6.3 Pairing
1. A logged-in user (web or app) calls `POST /pairing/codes` → `code` (10 Crockford base32 chars shown as `XXXX-XXXX-XX`, ~50 bits), TTL 10 min, single use, invalidated after 5 failed redemptions; redemption is rate-limited per IP.
2. QR payload URI:
   ```
   pictunnel://pair?v=1&sid=<server_id>&code=<code>&fp=<spki_sha256_b64url>&u=<endpoint>&u=<endpoint>
   ```
   `u` repeats in preference order (LAN first, then remote). `fp` is the base64url SHA-256 of the server certificate's SubjectPublicKeyInfo.
3. Client connects to the first reachable `u`. **Pinning rule:** if the certificate chain validates against the system trust store and matches the host, accept; otherwise the SPKI hash MUST equal `fp`, else abort.
4. `POST /pairing/redeem {code, device_name, platform, app_version}` → `{device_id, user, access_token, refresh_token, server_id}`.
5. Manual setup without QR: user enters a URL and logs in; for a self-signed certificate the app shows the fingerprint's first 16 chars for comparison with the server's admin page (trust on first use) and then pins it.

### 6.4 Discovery and transport
- mDNS service `_pictunnel._tcp.local.`; TXT `sid`, `v` (server version), `api=1`, `fp16` (first 16 chars of `fp`). No secrets.
- Default listeners: HTTPS `:8443` (all interfaces); HTTP `127.0.0.1:8080` for the local first-run page only.
- `PICTUNNEL_TLS=off` is allowed only when explicitly set (behind a TLS-terminating proxy) and logs a warning at every start.

## 7. Sync protocol

### 7.1 Client pipeline
Scan → Hash → Check → Upload → Confirm, per the state machine in the system design §4. All engine rules in §9 apply.

### 7.2 `POST /api/v1/sync/check`
Request (device is derived from the access token):
```json
{ "items": [ { "sha256": "…", "size_bytes": 2481234, "local_id": "A1B2…", "confirm_on_disk": false } ] }
```
- 1–1000 items; body ≤ 512 KB. Duplicates allowed; each answered in order.
- `local_id` optional. When present and the verdict is `exists`, the server upserts `asset_sources(device_id, local_id → asset_id)` (idempotent side effect, the only write this endpoint performs).
- `confirm_on_disk=true` makes the server `stat` the original and compare size, returning `on_disk`. Used before "free up space".

Response:
```json
{ "results": [
  { "sha256": "…", "verdict": "exists",  "asset_id": "…", "asset_state": "active", "has_live_video": false, "on_disk": true },
  { "sha256": "…", "verdict": "missing" },
  { "sha256": "…", "verdict": "partial", "upload": { "id": "…", "url": "/api/v1/uploads/…", "offset": 8388608, "length": 52428800, "expires_at": "…" } },
  { "sha256": "…", "verdict": "tombstoned", "deleted_at": "…" }
] }
```
| Verdict | Meaning | Client action |
|---|---|---|
| `exists` | Asset (active or trashed) owned by caller has this hash | Mark BackedUp with `asset_id` (trashed counts as backed up) |
| `missing` | Nothing known | Queue upload |
| `partial` | Active upload session exists | Resume at `offset` |
| `tombstoned` | User deliberately purged this content | Mark Skipped; offer "back up again" |

### 7.3 Uploads — tus profile
- tus `1.0.0` at `/api/v1/uploads`; extensions `creation`, `creation-with-upload`, `termination`, `expiration`, `checksum` (`Tus-Checksum-Algorithm: sha256`; per-request body checksum is OPTIONAL). `Upload-Defer-Length` is not supported.
- `Upload-Metadata` keys (values base64 per tus):

| Key | Req. | Meaning |
|---|---|---|
| `sha256` | yes | declared content hash |
| `filename` | yes | original filename |
| `mime` | yes | MIME type |
| `local_id` | no | device local identifier → `asset_sources` |
| `created_at` | no | client-known capture/creation time (RFC 3339) used when embedded metadata lacks a date |
| `modified_at` | no | client-known modification time |
| `pair_role` | no | `primary` (default) or `live_video` |
| `pair_sha256` | if `live_video` | hash of the primary still |
| `stack_key` | no | opaque; assets of one owner with equal `stack_key` share a stack |
| `override_tombstone` | no | `1` to upload despite a tombstone; tombstone removed on successful finalize |

**`POST` outcomes (in this precedence order):**

| # | Situation | Response |
|---|---|---|
| 1 | `Upload-Length` > `max_file_bytes` | `413 file_too_large` |
| 2 | Tombstone exists and no override | `409 tombstoned` |
| 3 | Asset `(owner, sha256)` already exists | `201`, `Location` of a completed upload resource (`Upload-Offset` = `Upload-Length`), headers `PicTunnel-Asset-Id`, `PicTunnel-Asset-Created: false`. Body bytes discarded. |
| 4 | Active session for `(owner, sha256)` exists | `201` with that session's `Location` and current `Upload-Offset`. If the session's length differs → `409 length_mismatch`. Body bytes are appended only if the session offset is 0; otherwise discarded. |
| 5 | Quota would be exceeded | `413 quota_exceeded` |
| 6 | Free space < `Upload-Length` + reserve (default 1 GiB) | `507 insufficient_storage` |
| 7 | Otherwise | New session, `201`, `Location`, `Upload-Expires`; with body (creation-with-upload) the bytes are appended and `Upload-Offset` returned. If the body completes the upload, finalize runs (§7.4) before responding. |

Because content is identical by definition, **any device may continue any session for the same `(owner, sha256)`** — two phones uploading the same video cooperatively converge on one upload.

**`PATCH`:** standard tus. `Upload-Offset` mismatch → `409 offset_mismatch` with the current `Upload-Offset` header. A concurrent `PATCH` on a locked session → `423 upload_locked`. The `PATCH` that completes the upload runs finalize and returns `204` with `PicTunnel-Asset-Id` and `PicTunnel-Asset-Created`.

**`HEAD`:** returns `Upload-Offset`, `Upload-Length`, `Upload-Expires`, and `PicTunnel-Asset-Id` once finalized. Unknown or expired → `404` (client restarts with `POST`, which is safe).

**Expiration:** sessions expire 24 h after last activity; staging bytes are deleted by `expire_uploads`.

**Client upload profiles (advisory):**
- *Single-shot:* any file ≤ `recommended_chunk_bytes` (server default 8 MiB), and on iOS background sessions any file ≤ 64 MiB → one `POST` creation-with-upload from the file (iOS `uploadTask(with:fromFile:)`).
- *Chunked:* larger files → `POST` without body, then sequential `PATCH` chunks (default 8 MiB on Android foreground work, 64 MiB on iOS background tasks, each chunk written to a temp file for the background session).

### 7.4 Server finalize (normative)
Session states: `receiving` → `finalizing` → `done` | `failed`.

1. When `offset == length`, obtain the digest. Hashing is incremental while receiving; after a server restart the server re-hashes the existing staged prefix before accepting further bytes.
2. Digest ≠ declared `sha256` → state `failed`, delete staging, respond `460 checksum_mismatch`.
3. In one write transaction: re-check tombstone (unless override) and existing asset. Existing → state `done(asset_id)`, delete staging, respond as outcome #3. Otherwise compute the destination path (§7.5), store it as `dest_path`, set state `finalizing`, commit.
4. `fsync` the staging file; move it to `dest_path`: `rename` when on the same volume, else copy to `<dest>.ptpart` in the destination directory → `fsync` → `rename` → `fsync` the directory → delete staging.
5. In one write transaction: insert `assets` row, `asset_sources` row (if `local_id`), `change_log` entry, enqueue `extract_metadata` + `generate_thumbnails` (and ML jobs if enabled), delete the tombstone if overridden, set session `done(asset_id)`. On a unique-constraint conflict, remove the moved file and resolve to the existing asset.
6. Respond with `PicTunnel-Asset-Id`.

**Startup recovery** for sessions in `finalizing`: if `dest_path` exists with the expected size and hash → run step 5; if only staging exists → redo steps 4–5; if neither is valid → mark `failed` (the client's next check returns `missing` and it re-uploads). Recovery MUST be idempotent.

### 7.5 Library path assignment
- Template: `<library>/<user_slug>/<YYYY>/<MM>/<filename>`. The date comes from, in order: a fast embedded-date read during finalize (EXIF `DateTimeOriginal` or the video container's creation time), then the client's `created_at` metadata, then server receive time. Full metadata extraction still runs later as a job. **The path never changes after ingest** (later date corrections update the DB only).
- Collision check is case-insensitive after Unicode NFC normalization against existing `assets.original_path` and `dest_path` of `finalizing` sessions; on collision append `~2`, `~3`, … before the extension.
- Filenames are sanitized: path separators, control chars and Windows-reserved names/characters are replaced; total path length kept below 240 chars (truncate the stem, keep the extension).
- Live-photo video components live next to the still with the same stem.

### 7.6 Browsing: change feed and snapshot
- `GET /sync/changes?cursor=<c>&limit=500` → `{ "changes": [ { "seq": 1042, "kind": "asset.upsert", "asset": {…} }, { "seq": 1043, "kind": "asset.removed", "asset_id": "…" } ], "next_cursor": "…", "has_more": false }`.
- Kinds in v1/M0: `asset.upsert` (full asset object; covers create, trash, restore, metadata updates) and `asset.removed` (purged). Clients MUST ignore unknown kinds (albums etc. are added later).
- Change log retention: 90 days. Older cursor → `410 cursor_expired`.
- `GET /sync/snapshot?page_token=&limit=1000` → first page includes `cursor` = the change-log head at snapshot start; assets ordered by `id`. After the last page the client continues with `/sync/changes?cursor=<cursor>`. Clients apply upserts keyed by `id`, ignoring any whose `updated_seq` is older than what they hold — this makes snapshot+feed overlap safe.
- Calling `changes` without a cursor returns `400 cursor_required` (forces a snapshot first).

### 7.7 Trash, purge, tombstones
- Trash sets `state=trashed`; auto-purge after 30 days (server setting).
- Purge deletes original + derivatives + row, inserts tombstone `(owner_id, sha256, deleted_at, filename)`, appends `asset.removed`.
- `DELETE /tombstones/{sha256}` or an upload with `override_tombstone=1` clears it.
- Deleting on the phone never calls any of these (one-way backup).

### 7.8 Free-up-space safety
A client MAY delete a local original only when, **immediately before** the OS delete request, a check with `confirm_on_disk=true` returned `verdict=exists`, `asset_state=active`, `on_disk=true`, and the local file's fingerprint is unchanged since it was hashed. The OS confirmation dialog is always shown.

## 8. Problem code catalogue

| Code | HTTP | Retryable | Client action |
|---|---|---|---|
| `invalid_request` | 400 | no | log, mark item needs attention |
| `cursor_required` | 400 | no | run snapshot |
| `pairing_code_invalid` | 400 | no | show error |
| `unauthorized` | 401 | after refresh | refresh once, then re-login |
| `token_expired` | 401 | after refresh | refresh, retry |
| `refresh_token_reused` | 401 | no | require re-pairing |
| `forbidden` | 403 | no | show error |
| `not_found` | 404 | no | for uploads: restart with `POST` |
| `not_ready` | 404 | yes | thumbnail not generated yet; retry later |
| `offset_mismatch` | 409 | yes | `HEAD`, resume from returned offset |
| `length_mismatch` | 409 | no | rehash file; if still mismatching, needs attention |
| `tombstoned` | 409 | no | mark Skipped |
| `pair_primary_missing` | 409 | yes | upload the primary still first, then retry |
| `setup_already_done` | 409 | no | go to login |
| `cursor_expired` | 410 | no | run snapshot |
| `file_too_large` | 413 | no | needs attention |
| `quota_exceeded` | 413 | no | pause backup, notify user |
| `upload_locked` | 423 | yes | backoff, then `HEAD` |
| `client_too_old` | 426 | no | prompt app update |
| `rate_limited` | 429 | yes | wait `Retry-After` |
| `checksum_mismatch` | 460 | yes | rehash local file, requeue (counts toward attempts) |
| `internal` | 500 | yes | backoff |
| `server_unavailable` | 503 | yes | wait `Retry-After` or backoff |
| `insufficient_storage` | 507 | no | pause all uploads, notify user |

## 9. Engine requirements (normative for Kotlin and Swift engines)

- **R1 Persist before acting.** A queue row (with state) MUST be durably written before any network call it governs.
- **R2 Ambiguity means re-ask.** A timeout or dropped connection leaves the outcome unknown; the engine MUST resolve it via `HEAD` (known upload) or `check` (otherwise) — never by assuming success or failure.
- **R3 Hash cache.** Keyed by `(local_id, modified_at, size_bytes)`; any difference forces re-hash. The cache lives in app storage only (lost on reinstall, rebuilt by re-hashing).
- **R4 Proof of backup.** An item becomes BackedUp only with a server-provided `asset_id`.
- **R5 Retry.** Exponential backoff, base 2 s, factor 2, cap 15 min, full jitter; honor `Retry-After`; at most 10 retryable failures per item before "needs attention". Periods with no network do not count as attempts.
- **R6 Batching and concurrency.** Check batches ≤ 1000. Upload concurrency default 2, max 4 (iOS background sessions are scheduled by the OS).
- **R7 Unknown values.** Unknown verdicts, kinds or problem codes → skip the item for this run and log; unknown 4xx → treat as non-retryable; unknown 5xx → retryable.
- **R8 No silent deletes.** Local media is deleted only through §7.8.
- **R9 Endpoints.** Try endpoints in stored order (LAN first); apply the pinning rule of §6.3 on every connection.
- **R10 Clocks.** Correctness MUST NOT depend on the device clock.
- **R11 Auth.** On `401 token_expired` refresh once and retry; concurrent refreshes rely on the grace window (§6.2).

## 10. Conformance vectors

### 10.1 Format
All vector files validate against `vectors.schema.json` (JSON Schema 2020-12). Each file: `{ "schema_version": 1, "kind": "<hashing|server-scenario|client-decision|pairing>", "name": "...", "description": "...", ... }`.

Large inputs are described by deterministic generators instead of committed blobs:
```json
{ "generate": { "pattern": "counter", "length": 8388609 } }
```
`counter` = byte `i mod 256` at position `i`. `fixtures/` holds only small real files (JPEG, HEIC, MP4 snippets ≤ 64 KB).

### 10.2 Kinds and minimum coverage

| Kind | Consumer | Minimum cases | Must include |
|---|---|---|---|
| `hashing` | Go, Kotlin, Swift | 8 | empty file; 1 byte; exactly one chunk (8 MiB); chunk + 1; 64 MiB + 1 generated; real JPEG; real HEIC; real MP4 |
| `server-scenario` | Go conformance runner (sub-project 2) | 14 | fresh upload; creation-with-upload single shot; resume after drop; duplicate `POST` returns same session; existing asset short-circuit; two devices same hash cooperative; tombstone blocks; tombstone override; checksum mismatch; offset mismatch; length mismatch; check links sources; snapshot + changes overlap; cursor expired |
| `client-decision` | Kotlin, Swift (and Dart where relevant) | 25 | every verdict; every problem code in §8; timeout during `POST`/`PATCH`/finalize (R2); unknown verdict (R7); free-up-space preconditions (§7.8); refresh grace and reuse |
| `pairing` | Dart, Kotlin, Swift | 8 | valid multi-endpoint URI; missing `fp`; bad version; malformed code; pin match; pin mismatch; public-CA endpoint; duplicate `u` |

### 10.3 Shapes
- **server-scenario:** ordered `steps[]`, each `{request: {method, path, headers, body|body_generate}, expect: {status, headers_subset, body_subset}, save: {var: jsonpath}}` with `${var}` substitution and `actor` (`device_a`, `device_b`).
- **client-decision:** `{given: {item_state, item, last_action}, server: {status, headers, body}|{transport: "timeout"|"reset"}, expect: {next_state, action, attempts_delta}}`.

### 10.4 M0 proof of harness
M0 ships minimal runners that load vectors and pass all `hashing` vectors in Go (`go test ./internal/conformance`), Kotlin (JUnit) and Swift (XCTest), and validate every vector file against the schema in CI. `server-scenario` and `client-decision` runners are completed in sub-projects 2 and 3.

## 11. Code generation and contract tooling

| Target | Tool | Output | Notes |
|---|---|---|---|
| Lint | Redocly CLI | — | rules: `operationId` on all ops, `snake_case` props, problem responses declared, tags required |
| Breaking changes | `oasdiff breaking` | — | PRs compared against `main`; fails on breaking change within v1 |
| Go | `oapi-codegen` (strict server + models) | `server/internal/httpapi/gen/` | |
| Dart | `openapi-generator` `dart-dio` (Docker image) | `mobile/packages/pictunnel_api/` | full API for the Flutter app |
| Kotlin | `openapi-generator` `kotlin`, `jvm-okhttp4`, kotlinx-serialization | `mobile/android/engine-api/` | **engine subset** only |
| Swift | `swift-openapi-generator` | `mobile/ios/EngineAPI/` | **engine subset** only |
| TypeScript | `openapi-typescript` + `openapi-fetch` | `web/src/lib/api/` | |

- The engine subset is produced by `redocly bundle` with a `filter-in` decorator on tag `engine` → `api/build/engine-openapi.yaml` (git-ignored; regenerated).
- Generated code is **committed**. CI runs `task gen` and fails if the working tree changes.
- Generator versions are pinned (Docker image tags, `go.mod` tool directives, `package.json`, SwiftPM `Package.resolved`).
- tus requests are exercised through tus client libraries (tus-java-client, TUSKit or a thin URLSession implementation, tus-js-client); the OpenAPI document still describes headers and responses for documentation and testing.

## 12. Repository foundation and CI

### 12.1 Skeletons
| Dir | Skeleton | Builds in M0 |
|---|---|---|
| `server/` | Go module, `cmd/pictunnel/main.go` (prints version), `internal/httpapi/gen`, `internal/conformance` | yes, cross-compiled |
| `mobile/` | `flutter create` app, `packages/pictunnel_api`, `android/engine-api`, `ios/EngineAPI` | Android debug + iOS `--no-codesign` |
| `web/` | SvelteKit static adapter + generated types | yes |
| `ml/` | `pyproject.toml` (uv), empty package, one test | yes |

### 12.2 Identifiers (confirm during review)
| Identifier | Proposed value | Why it matters |
|---|---|---|
| Go module path | `github.com/PrithvirajG/pictunnel/server` | Changing later is a mechanical rename |
| Android `applicationId` | `io.github.prithvirajg.pictunnel` | **Cannot change after the first Play Store release**; needs no domain purchase |
| iOS bundle id | `io.github.prithvirajg.pictunnel` | Same reasoning |
| Docker image | `ghcr.io/prithvirajg/pictunnel` | |

### 12.3 Repo hygiene
`.gitattributes` normalizes text to LF (the primary dev machine is Windows) and marks generated dirs `linguist-generated`; `.editorconfig`; `.gitignore` per stack; root `LICENSE` (AGPL-3.0) with `api/LICENSE` and `mobile/LICENSE` (Apache-2.0); `README.md` (status: pre-alpha); `CONTRIBUTING.md` (DCO sign-off, `task` commands, toolchain); `SECURITY.md`; `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1); issue and PR templates.

### 12.4 Toolchain
Go: latest stable at M0 start, pinned with `toolchain` in `go.mod`. Flutter: stable channel, pinned in `mobile/.flutter-version` and CI. Node: LTS with pnpm via `packageManager`. Python ≥ 3.12 with uv. Task (taskfile.dev) as the single entry point: `task gen`, `task lint`, `task test`, `task vectors:validate`, `task ci`.

### 12.5 CI workflows (GitHub Actions, path-filtered)
| Workflow | Runs when | Jobs |
|---|---|---|
| `ci-api` | `api/**` | Redocly lint · `oasdiff` (PRs) · vector schema validation · `task gen` drift check |
| `ci-server` | `server/**`, `api/**` | `go vet` · golangci-lint · `go test` · cross-build linux/amd64, linux/arm64, windows/amd64, darwin/arm64 |
| `ci-mobile` | `mobile/**`, `api/**` | `flutter analyze` + `flutter test` · Android `assembleDebug` + Kotlin unit tests · **macOS runner:** `flutter build ios --no-codesign` + XCTest |
| `ci-web` | `web/**`, `api/**` | `svelte-check` · Vitest · build |
| `ci-ml` | `ml/**` | ruff · pytest |
| `dco` | PRs | every commit has `Signed-off-by` |

## 13. ADRs to write (`docs/adr/`, MADR-lite)

0001 Record architecture decisions · 0002 Monorepo · 0003 Go modular monolith with embedded SQLite · 0004 Flutter UI with native backup engines · 0005 SHA-256 content identity, per-user dedup · 0006 tus for resumable uploads · 0007 Human-readable library layout · 0008 One-way backup with trash and tombstones · 0009 License split with DCO · 0010 OpenAPI-first contract with committed generated code · 0011 Opaque tokens with rotating refresh tokens.

## 14. Acceptance criteria (M0 "done")

1. `api/openapi.yaml` passes lint and contains every endpoint in §4 with request/response schemas, examples and problem responses.
2. `api/protocol/sync-protocol.md` covers §5–§9 normatively with at least one worked example per endpoint.
3. Vector files meet §10.2 minimums and validate against the schema in CI.
4. `task gen` produces Go, Dart, Kotlin (engine subset), Swift (engine subset) and TS outputs that compile in CI; drift check passes.
5. Hashing vectors pass in Go, Kotlin and Swift.
6. All CI workflows are green on `main`, including the macOS iOS build.
7. ADRs 0001–0011, licenses and contributor docs are committed; the DCO check is active.

## 15. Risks

| Risk | Mitigation |
|---|---|
| OpenAPI 3.1 support gaps in a generator | Lint for the generator-safe subset; fall back to 3.0.3 output via `redocly bundle` if a generator lags |
| Java/Docker needed for openapi-generator on Windows | Run generators via Docker in `task gen`; CI is the source of truth |
| tus semantics not expressible in OpenAPI | Document headers/responses in OpenAPI; behavior lives in `sync-protocol.md` + server-scenario vectors |
| No local iOS toolchain | All Swift work verified on GitHub macOS runners |
