# PicTunnel Sync Protocol (API v1)

- Status: Normative for API v1 · License: Apache-2.0
- Wire format: [`../openapi.yaml`](../openapi.yaml) · Decisions: [`../../docs/adr/`](../../docs/adr/)

## 1. Scope

This document defines how PicTunnel clients and servers identify content, authenticate, upload, browse and delete, so that independent implementations (the Go server, the Kotlin and Swift backup engines, the Flutter app, the web viewer) behave identically. The OpenAPI document defines the wire format; this document defines behavior. Section numbers are stable and are referenced from the OpenAPI descriptions.

## 2. Normative language and terms

The key words MUST, MUST NOT, SHOULD and MAY are to be interpreted as in RFC 2119.

- **Asset**: one unique original owned by one user, identified by the SHA-256 of its bytes.
- **Engine**: the native backup pipeline on a phone (Kotlin on Android, Swift on iOS).
- **Session**: a tus upload resource on the server.
- **Tombstone**: a record that a user deliberately purged content with a given hash.
- **Counter pattern**: test content where byte *i* is (*i* + seed) mod 256.

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
| Open value sets | Response fields whose set of values may grow (verdicts, states, kinds, problem codes, roles, platforms in responses) are declared `type: string` with the known values listed in `x-known-values`, never as a closed `enum`, so generated clients cannot crash on a new value. Request-only fields MAY use `enum`. |
| Version gate | `426 Upgrade Required` with code `client_too_old` when `PicTunnel-Client: <platform>/<version>` is below `min_client_version`. `GET /api/v1/server/info`, `/healthz` and `/readyz` are exempt from the version gate, since clients use server info to learn `min_client_version`. |

## 4. Endpoint catalogue (v1, defined in M0)

Operations tagged **engine** are the only ones the native backup engines call.

| Method & path | Auth | Tag | Purpose |
|---|---|---|---|
| `GET /api/v1/server/info` | none | engine, server | Server id, name, version, `api_version`, `min_client_version` per platform, `capabilities[]`, upload limits (`max_file_bytes`, `recommended_chunk_bytes`), server `time` |
| `POST /api/v1/auth/setup` | none | auth | Create first admin; `409 setup_already_done` afterwards |
| `POST /api/v1/auth/login` | none | auth | Password login → tokens (apps) or session cookie (web) |
| `POST /api/v1/auth/refresh` | refresh token | engine, auth | Rotate refresh token, new access token (§6.2) |
| `POST /api/v1/auth/logout` | bearer/cookie | auth | Revoke current device session |
| `POST /api/v1/pairing/codes` | bearer/cookie | pairing | Create a one-time pairing code for the caller's account → `code`, `qr_uri`, `expires_at` |
| `POST /api/v1/pairing/redeem` | none | pairing | Exchange code + device info for device credentials |
| `GET /api/v1/devices` | bearer/cookie | devices | List caller's devices |
| `PATCH /api/v1/devices/{device_id}` | bearer/cookie | devices | Rename |
| `DELETE /api/v1/devices/{device_id}` | bearer/cookie | devices | Revoke a device |
| `POST /api/v1/sync/check` | bearer/cookie | engine, sync | Batch content check (§7.2) |
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

The tags `users`, `albums`, `shares`, `search`, `admin` and `ml` are reserved for future, additive versions of API v1.

### 4.1 Asset object (v1 fields)

| Field | Type | Notes |
|---|---|---|
| `id` | uuid | |
| `sha256` | hex | identity |
| `size_bytes` | int64 | |
| `mime` | string | |
| `kind` | string (known values: `photo`, `video`, `live_photo`) | |
| `filename` | string | original name from the device |
| `taken_at` | datetime, nullable | |
| `taken_at_offset_minutes` | int, nullable | |
| `taken_at_source` | string (known values: `exif`, `container`, `client`, `file`, `unknown`) | |
| `width`, `height` | int, nullable | null until metadata job runs |
| `duration_ms` | int, nullable | video / live component |
| `lat`, `lon` | number, nullable | |
| `state` | string (known values: `active`, `trashed`) | |
| `trashed_at` | datetime, nullable | |
| `stack_id` | uuid, nullable | edits/bursts grouping |
| `live_video` | object, omitted when absent | `{sha256, size_bytes, mime}` |
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
4. `POST /pairing/redeem {code, device: {device_name, platform, app_version}}` → `201 {server_id, user, device, tokens}`.
5. Manual setup without QR: user enters a URL and logs in; for a self-signed certificate the app shows the fingerprint's first 16 chars for comparison with the server's admin page (trust on first use) and then pins it.

**Setup hijack guard.** `POST /auth/setup` on the loopback listener is accepted as-is. On any other listener it MUST carry `PicTunnel-Setup-Token`, the one-time token the server prints to its log and stdout on first boot. A missing or wrong token returns `403 forbidden`.

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

For a `live_video` upload, `PicTunnel-Asset-Id` is the id of the primary still the component is attached to.

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

Vectors live in `vectors/<dir>/*.json` and validate against `vectors/vectors.schema.json` (run `node api/tools/validate-vectors.mjs --strict`). Each file has `schema_version: 1`, a `kind`, a `description` and a list of `cases`. Directories map to kinds: `hashing/` → `hashing`, `pairing/` → `pairing`, `server-scenarios/` → `server-scenario`, `client-decisions/` → `client-decision`.

### 10.1 Generated content

`{"pattern": "counter", "seed": s, "length": L, "start": a, "end": b}` denotes the bytes at absolute positions *i* ∈ [*a*, *b*) of a stream of length *L* where byte *i* = (*i* + *s*) mod 256. `seed` defaults to 0, `start` to 0 and `end` to *L*. `start` and `end` may be `${name}` references to saved decimal values. Payloads used across vectors:

| Name | seed | length | sha256 |
|---|---|---|---|
| A | 0 | 1048576 | `fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83` |
| B | 1 | 1048576 | `18af9b054114c04a1eb836533a3e760dfa9dc53934ecb02fc059ff27150e77fb` |
| C | 0 | 3145728 | `f6dd7fec8584ad00219a447071c1fa368a1caee4d9c146083d233713ddccd2c0` |
| V | 2 | 1048576 | `c11788fa01aebe9ddeadf2d6fd661693d75a0ca28dc957a6042b5ff6d8a08e66` |

### 10.2 Hashing

The runner streams the input (`file` relative to `api/protocol/`, `inline_utf8` as UTF-8 bytes, or `generate`) through SHA-256 in chunks and compares the lowercase hex digest with `expected_sha256`.

### 10.3 Pairing

Parsing: the scheme MUST be `pictunnel` with host `pair` (`invalid_scheme`); `v` MUST be `1` (`unsupported_version`); `sid` is required (`missing_server_id`); `code` MUST match `^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{2}$` (`invalid_code`); `fp` is required (`missing_fingerprint`); at least one `u` is required (`missing_endpoint`); every `u` MUST use `https://` (`insecure_endpoint`). Duplicate `u` values are dropped, keeping first-occurrence order. Errors are checked in the order listed. When `connection` is present, the expected `accept_connection` is `true` if `system_trusted` is true, otherwise only if `spki_sha256` equals `fp`.

### 10.4 Server scenarios

- Each case runs against a fresh server with an empty library and a controllable test clock.
- For every distinct `user` the runner creates an account (the user slug equals the name); for every actor it pairs a device with the given `platform` to that user. HTTP steps carry `Authorization: Bearer <actor access token>` unless `request.headers.Authorization` is set to an empty string.
- `${name}` is substituted in `path`, header values, JSON string values and `generate.start`/`end`.
- `tus_metadata` becomes the `Upload-Metadata` header: `key base64(UTF-8 value)` pairs, comma-separated, in the listed order.
- `body.generate` becomes the request body with a matching `Content-Length`.
- `transport.drop_after_bytes: N` makes the runner send the headers and the first N body bytes, then close the connection without reading a response; such steps expect `no_response: true`.
- `Location` header values are normalized to their path before saving or comparing.
- `save` reads `header:<Name>` (case-insensitive) or `body:<JSON Pointer>`; numbers are saved as decimal strings.
- Matchers in `expect.headers` and `expect.body` string values: `$any` (present), `$uuid`, `$int` (decimal string or JSON integer), `$sha256`, `$datetime` (RFC 3339), `${name}` (equals a saved value); any other value must be equal. Objects match as subsets (extra keys allowed). Arrays match as ordered subsequences. `{"$len": n}` matches an array of exactly n items.
- Control steps: `advance_clock_seconds` moves the server test clock; `run_job` runs the named job to completion synchronously; `assert_library_paths` compares the exact set of file paths under `<library>/<user>/` (NFC-normalized, relative to the library root); `assert_asset_sources` compares the exact set of `(device, local_id)` links of an asset.

### 10.5 Client decisions

The engine's decision function is fed `given` (flow, item state, last action, item flags) and `server` (a response, or a `transport` failure: `timeout`, `reset` or `offline`), and must produce `expect.next_state`, `expect.action` and `expect.attempts_delta`. `server.problem: "<code>"` expands to the body `{"type": "urn:pictunnel:problem:<code>", "title": "<code>", "status": <status>, "code": "<code>"}`.

| Action | Meaning |
|---|---|
| `mark_backed_up` | Record the server `asset_id`; the item is done |
| `queue_upload` | Put the item in the upload queue |
| `resume_upload` | Continue the known session from the server offset |
| `head_then_resume` | `HEAD` the session, then continue from its offset |
| `restart_upload` | Forget the session and `POST` again (safe: creation is idempotent) |
| `mark_skipped` | Content is tombstoned; offer "back up again" |
| `rehash_and_requeue` | Discard the cached hash, re-hash the file, check again |
| `backoff_retry` | Retry with exponential backoff and full jitter (R5) |
| `wait_retry_after` | Wait for `Retry-After`, then retry |
| `wait_for_network` | Wait for connectivity; not an attempt |
| `refresh_then_retry` | Refresh tokens once, then retry the request (R11) |
| `retry_original_request` | The refresh succeeded; repeat the request that needed it |
| `require_repair` | Credentials are revoked; ask the user to pair again |
| `pause_all_uploads` | Stop uploading for every item and notify the user |
| `notify_quota` | Pause and tell the user how much space is left |
| `prompt_update` | Pause and ask the user to update the app |
| `mark_needs_attention` | Stop retrying this item and list it for the user |
| `run_snapshot` | Discard the cursor and run a full snapshot |
| `retry_later` | Try again on the next view of the item |
| `skip_this_run` | Leave the item unchanged until the next run (R7) |
| `upload_primary_first` | Upload the Live Photo still before its video |
| `upload_live_video` | Upload the missing Live Photo video component |
| `check_then_resolve` | Outcome unknown; ask `/sync/check` before acting (R2) |
| `delete_local_allowed` | All §7.8 conditions hold; request the OS delete with confirmation |
| `delete_local_denied` | At least one §7.8 condition failed; keep the local file |
| `show_error` | Show the problem's message to the user |
| `go_to_login` | Navigate to the login screen |

**Attempt counting.** A `429 rate_limited` response waits `Retry-After` and does NOT count as an attempt. A `503 server_unavailable` response waits `Retry-After` (or backs off) and DOES count as an attempt. A transport failure of `offline` (no network) never counts as an attempt (R5); transport failures of `timeout` and `reset` count.

## 11. Worked examples

Bodies are abbreviated only where marked `…`. Authentication headers are omitted after the first example.

### 11.1 Server

#### `getHealthz`

```http
GET /healthz

HTTP/1.1 200 OK
Content-Type: text/plain

ok
```

#### `getReadyz`

```http
GET /readyz

HTTP/1.1 503 Service Unavailable
Content-Type: application/problem+json
Retry-After: 5

{"type":"urn:pictunnel:problem:server_unavailable","title":"Storage is not writable","status":503,"code":"server_unavailable"}
```

#### `getServerInfo`

```http
GET /api/v1/server/info

HTTP/1.1 200 OK
Content-Type: application/json

{"server_id":"01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f","name":"Home server","version":"0.1.0","api_version":"1.0",
 "min_client_version":{"android":"0.1.0","ios":"0.1.0","web":"0.1.0"},"capabilities":["tus"],
 "upload":{"tus_version":"1.0.0","max_file_bytes":53687091200,"recommended_chunk_bytes":8388608},
 "time":"2026-10-03T12:00:00Z"}
```

### 11.2 Accounts and tokens

#### `setupFirstAdmin`

```http
POST /api/v1/auth/setup
Content-Type: application/json

{"username":"alice","password":"correct horse battery","display_name":"Alice"}

HTTP/1.1 201 Created
{"user":{"id":"01928f3f-0000-7000-8000-00000000a11c","username":"alice","display_name":"Alice","role":"admin"}}
```
A second call returns `409` with `"code":"setup_already_done"`.

#### `login`

```http
POST /api/v1/auth/login
Content-Type: application/json
PicTunnel-Client: android/0.1.0

{"username":"alice","password":"correct horse battery","mode":"tokens",
 "device":{"device_name":"Pixel 9","platform":"android","app_version":"0.1.0"}}

HTTP/1.1 200 OK
{"user":{"id":"01928f3f-0000-7000-8000-00000000a11c","username":"alice","display_name":"Alice","role":"admin"},
 "device":{"id":"01928f3f-1111-7000-8000-0000000d0001","name":"Pixel 9","platform":"android","app_version":"0.1.0","created_at":"2026-10-03T12:00:00Z","last_seen_at":null},
 "tokens":{"access_token":"pt_at_…","access_token_expires_at":"2026-10-03T12:15:00Z","refresh_token":"pt_rt_…","refresh_token_expires_at":"2027-01-01T12:00:00Z"}}
```
With `"mode":"cookie"` the response sets `Set-Cookie: pt_session=…; HttpOnly; Secure; SameSite=Lax; Path=/` and returns `csrf_token`; later state-changing requests send `X-CSRF-Token`.

#### `refreshTokens`

```http
POST /api/v1/auth/refresh
Content-Type: application/json

{"refresh_token":"pt_rt_…"}

HTTP/1.1 200 OK
{"access_token":"pt_at_…","access_token_expires_at":"2026-10-03T12:30:00Z","refresh_token":"pt_rt_…(new)","refresh_token_expires_at":"2027-01-01T12:15:00Z"}
```
Presenting the old refresh token again within 30 s returns the same pair; after 30 s it returns `401` with `"code":"refresh_token_reused"` and the device is revoked.

#### `logout`

```http
POST /api/v1/auth/logout
Authorization: Bearer pt_at_…

HTTP/1.1 204 No Content
```

### 11.3 Pairing and devices

#### `createPairingCode`

```http
POST /api/v1/pairing/codes

HTTP/1.1 201 Created
{"code":"K7Q2-M9XD-4T",
 "qr_uri":"pictunnel://pair?v=1&sid=01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f&code=K7Q2-M9XD-4T&fp=xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc&u=https%3A%2F%2F192.168.1.20%3A8443",
 "expires_at":"2026-10-03T12:10:00Z"}
```

#### `redeemPairingCode`

```http
POST /api/v1/pairing/redeem
Content-Type: application/json

{"code":"K7Q2-M9XD-4T","device":{"device_name":"Alice's iPhone","platform":"ios","app_version":"0.1.0"}}

HTTP/1.1 201 Created
{"server_id":"01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f","user":{…},"device":{…},"tokens":{…}}
```
An unknown, used or expired code returns `400` with `"code":"pairing_code_invalid"`.

#### `listDevices`

```http
GET /api/v1/devices

HTTP/1.1 200 OK
{"devices":[{"id":"01928f3f-1111-7000-8000-0000000d0001","name":"Pixel 9","platform":"android","app_version":"0.1.0","created_at":"2026-10-03T12:00:00Z","last_seen_at":"2026-10-03T12:05:00Z"}]}
```

#### `updateDevice`

```http
PATCH /api/v1/devices/01928f3f-1111-7000-8000-0000000d0001
Content-Type: application/json

{"name":"Alice's Pixel"}

HTTP/1.1 200 OK
{"id":"01928f3f-1111-7000-8000-0000000d0001","name":"Alice's Pixel","platform":"android","app_version":"0.1.0","created_at":"2026-10-03T12:00:00Z","last_seen_at":"2026-10-03T12:05:00Z"}
```

#### `revokeDevice`

```http
DELETE /api/v1/devices/01928f3f-1111-7000-8000-0000000d0001

HTTP/1.1 204 No Content
```

### 11.4 Sync

#### `checkContent`

```http
POST /api/v1/sync/check
Content-Type: application/json

{"items":[
  {"sha256":"fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83","size_bytes":1048576,"local_id":"a-1"},
  {"sha256":"18af9b054114c04a1eb836533a3e760dfa9dc53934ecb02fc059ff27150e77fb","size_bytes":1048576},
  {"sha256":"f6dd7fec8584ad00219a447071c1fa368a1caee4d9c146083d233713ddccd2c0","size_bytes":3145728}]}

HTTP/1.1 200 OK
{"results":[
  {"sha256":"fbbab289…7c83","verdict":"exists","asset_id":"01928f40-0000-7000-8000-000000000001","asset_state":"active","has_live_video":false},
  {"sha256":"18af9b05…77fb","verdict":"missing"},
  {"sha256":"f6dd7fec…d2c0","verdict":"partial","upload":{"id":"01928f40-1111-7aaa-8bbb-0123456789ab","url":"/api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab","offset":1048576,"length":3145728,"expires_at":"2026-10-04T12:00:00Z"}}]}
```

#### `getSnapshot`

```http
GET /api/v1/sync/snapshot?limit=1000

HTTP/1.1 200 OK
{"cursor":"c_00000000000003e9","assets":[{"id":"01928f40-0000-7000-8000-000000000001","sha256":"fbbab289…7c83","kind":"photo","state":"active",…}],
 "next_page_token":null,"has_more":false}
```

#### `getChanges`

```http
GET /api/v1/sync/changes?cursor=c_00000000000003e9&limit=500

HTTP/1.1 200 OK
{"changes":[
  {"seq":1002,"kind":"asset.upsert","asset":{"id":"01928f40-0000-7000-8000-000000000002","state":"active",…}},
  {"seq":1003,"kind":"asset.removed","asset_id":"01928f40-0000-7000-8000-000000000001"}],
 "next_cursor":"c_00000000000003eb","has_more":false}
```
A cursor older than 90 days returns `410` with `"code":"cursor_expired"`; omitting it returns `400` with `"code":"cursor_required"`.

### 11.5 Uploads (tus)

The metadata below encodes `sha256`, `filename` (`IMG_0001.JPG`), `mime` (`image/jpeg`) and `local_id` (`a-1`).

#### `optionsUploads`

```http
OPTIONS /api/v1/uploads

HTTP/1.1 204 No Content
Tus-Resumable: 1.0.0
Tus-Version: 1.0.0
Tus-Extension: creation,creation-with-upload,termination,expiration,checksum
Tus-Max-Size: 53687091200
Tus-Checksum-Algorithm: sha256
```

#### `createUpload`

Bodyless creation:
```http
POST /api/v1/uploads
Tus-Resumable: 1.0.0
Upload-Length: 1048576
Upload-Metadata: sha256 ZmJiYWIyODlmN2Y5NGIyNTczNmM1OGJlNDZhOTk0YzQ0MWZkMDI1NTJjYzYwMjIzNTJlM2Q4NmQyZmFiN2M4Mw==,filename SU1HXzAwMDEuSlBH,mime aW1hZ2UvanBlZw==,local_id YS0x

HTTP/1.1 201 Created
Tus-Resumable: 1.0.0
Location: /api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab
Upload-Expires: Sun, 04 Oct 2026 12:00:00 GMT
```
Creation with upload (iOS single shot) finalizes in the same request:
```http
POST /api/v1/uploads
Tus-Resumable: 1.0.0
Upload-Length: 1048576
Upload-Metadata: sha256 ZmJiYWIy…,filename SU1HXzAwMDEuSlBH,mime aW1hZ2UvanBlZw==
Content-Type: application/offset+octet-stream
Content-Length: 1048576

<1048576 bytes>

HTTP/1.1 201 Created
Location: /api/v1/uploads/01928f40-2222-7aaa-8bbb-0123456789ab
Upload-Offset: 1048576
PicTunnel-Asset-Id: 01928f40-0000-7000-8000-000000000001
PicTunnel-Asset-Created: true
```
Content the user already has resolves without storing bytes: `201` with `Upload-Offset` equal to `Upload-Length`, `PicTunnel-Asset-Id` of the existing asset and `PicTunnel-Asset-Created: false`. Tombstoned content returns `409` with `"code":"tombstoned"` unless metadata includes `override_tombstone MQ==` (base64 of `1`).

#### `getUploadOffset`

```http
HEAD /api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab
Tus-Resumable: 1.0.0

HTTP/1.1 200 OK
Upload-Offset: 524288
Upload-Length: 1048576
Upload-Expires: Sun, 04 Oct 2026 12:00:00 GMT
```

#### `appendUpload`

```http
PATCH /api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab
Tus-Resumable: 1.0.0
Upload-Offset: 524288
Content-Type: application/offset+octet-stream
Content-Length: 524288

<524288 bytes>

HTTP/1.1 204 No Content
Upload-Offset: 1048576
PicTunnel-Asset-Id: 01928f40-0000-7000-8000-000000000001
PicTunnel-Asset-Created: true
```
A wrong offset returns `409` with `"code":"offset_mismatch"` and the server's `Upload-Offset`; bytes that do not hash to the declared sha256 return `460` with `"code":"checksum_mismatch"` and the session is discarded.

#### `terminateUpload`

```http
DELETE /api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab
Tus-Resumable: 1.0.0

HTTP/1.1 204 No Content
```

### 11.6 Assets, trash and tombstones

#### `getAsset`

```http
GET /api/v1/assets/01928f40-0000-7000-8000-000000000001

HTTP/1.1 200 OK
{"id":"01928f40-0000-7000-8000-000000000001","sha256":"fbbab289…7c83","size_bytes":1048576,"mime":"image/jpeg","kind":"photo",
 "filename":"IMG_0001.JPG","taken_at":"2024-05-06T10:00:00Z","taken_at_offset_minutes":120,"taken_at_source":"exif",
 "width":4032,"height":3024,"duration_ms":null,"lat":38.7223,"lon":-9.1393,"state":"active","trashed_at":null,
 "stack_id":null,"thumbnails_ready":true,"created_at":"2026-10-03T12:00:02Z","updated_seq":1001}
```

#### `getAssetThumbnail`

```http
GET /api/v1/assets/01928f40-0000-7000-8000-000000000001/thumbnail?size=preview

HTTP/1.1 200 OK
Content-Type: image/jpeg
ETag: "3b1e…"

<jpeg bytes>
```
Before the thumbnail job has run: `404` with `"code":"not_ready"`.

#### `getAssetOriginal`

```http
GET /api/v1/assets/01928f40-0000-7000-8000-000000000001/original
Range: bytes=0-1023

HTTP/1.1 206 Partial Content
Content-Type: application/octet-stream
Content-Range: bytes 0-1023/1048576
ETag: "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83"

<1024 bytes>
```

#### `getAssetPlayback`

```http
GET /api/v1/assets/01928f40-0000-7000-8000-000000000003/playback
Range: bytes=0-

HTTP/1.1 206 Partial Content
Content-Type: video/mp4
Content-Range: bytes 0-3145727/3145728

<mp4 bytes>
```

#### `trashAssets`

```http
POST /api/v1/assets/trash
Content-Type: application/json

{"asset_ids":["01928f40-0000-7000-8000-000000000001","01928f40-0000-7000-8000-0000000000ff"]}

HTTP/1.1 200 OK
{"succeeded":["01928f40-0000-7000-8000-000000000001"],"failed":[{"asset_id":"01928f40-0000-7000-8000-0000000000ff","code":"not_found"}]}
```

#### `restoreAssets`

```http
POST /api/v1/assets/restore
Content-Type: application/json

{"asset_ids":["01928f40-0000-7000-8000-000000000001"]}

HTTP/1.1 200 OK
{"succeeded":["01928f40-0000-7000-8000-000000000001"],"failed":[]}
```

#### `purgeAssets`

```http
POST /api/v1/assets/purge
Content-Type: application/json

{"asset_ids":["01928f40-0000-7000-8000-000000000001","01928f40-0000-7000-8000-000000000002"]}

HTTP/1.1 200 OK
{"succeeded":["01928f40-0000-7000-8000-000000000001"],"failed":[{"asset_id":"01928f40-0000-7000-8000-000000000002","code":"not_trashed"}]}
```

#### `emptyTrash`

```http
POST /api/v1/trash/empty

HTTP/1.1 200 OK
{"purged_count":12}
```

#### `listTombstones`

```http
GET /api/v1/tombstones?limit=50

HTTP/1.1 200 OK
{"tombstones":[{"sha256":"fbbab289…7c83","filename":"IMG_0001.JPG","deleted_at":"2026-10-03T13:00:00Z"}],"next_cursor":null,"has_more":false}
```

#### `deleteTombstone`

```http
DELETE /api/v1/tombstones/fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83

HTTP/1.1 204 No Content
```
