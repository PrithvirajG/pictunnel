# Server Core (2A Sync Core + 2B Media Pipeline) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `pictunnel serve`: a crash-safe Go backup server implementing every API v1 operation (2A) plus metadata extraction, thumbnails and browser playback (2B).

**Architecture:** Layered Go monolith under `server/internal/`: `repository` (one type per table, sqlc queries) → `service` (orchestration, policy) → `httpapi` (strict handlers + hand-written tus). SQLite WAL with one writer and a reader pool. A durable job queue runs the background work, including all 2B media jobs. The behavior is normative in the contract; this plan says where each piece goes.

**Tech Stack:**
- Go 1.27 with `CGO_ENABLED=0`.
- `modernc.org/sqlite`, goose v3, sqlc v1.30.0 (as a `go tool`), oapi-codegen v2.8.0 (exists), `google/uuid` (v7).
- `golang.org/x/{crypto,text,time,sys,image}`, `pelletier/go-toml/v2`.
- `brutella/dnssd`, falling back to `hashicorp/mdns`.
- `evanoberholster/imagemeta`, ffmpeg/ffprobe (external binaries).
- Tests: `pgregory.net/rapid`, kin-openapi `openapi3filter`; `tus-js-client` for the interop test.

**Spec:**
- 2A: [`docs/superpowers/specs/2026-10-12-server-sync-core-design.md`](../specs/2026-10-12-server-sync-core-design.md). Its section numbers are cited as `S§n`.
- Contract: [`api/protocol/sync-protocol.md`](../../../api/protocol/sync-protocol.md), cited as `P§n`, and [`api/openapi.yaml`](../../../api/openapi.yaml).
- 2B: the "2B design" section in this plan. It derives from system design §5–§6.
- Implementers read the cited sections of the spec they need, not the whole document.

## Global Constraints

- Go module `github.com/PrithvirajG/pictunnel/server`; all Go work happens in `server/`. `CGO_ENABLED=0 go build ./...` must succeed for linux/amd64, linux/arm64, windows/amd64 and darwin/arm64.
- Every commit uses `git commit -s`. **No AI attribution trailers** (no Co-Authored-By: Claude, no Claude-Session, no "Generated with").
- Dev host is Windows 11 (Git Bash + PowerShell), with no C compiler and no Docker daemon. ffmpeg 9.0 is on PATH. Tests must pass on Windows, Linux and macOS.
- Never edit `server/internal/httpapi/gen/` or `server/internal/store/queries/` by hand. To regenerate: from `server/internal/httpapi`, run `go tool oapi-codegen -config oapi-codegen.yaml ../../../api/openapi.yaml`; for sqlc, `go tool sqlc generate -f internal/store/sqlc.yaml` from `server/`.
- Layering rules (S§2.1):
  - A repository touches exactly one table.
  - Service constructors take a deps struct naming exactly the repositories they use.
  - Handlers contain no business logic.
  - Every domain error comes from `apperr`.
  - `contenthash`, `tlsutil`, `storage` and `media/probe` import no domain package.
- Repository methods take `(ctx context.Context, db queries.DBTX, …)` so callers choose the reader pool or a write transaction. Repositories are stateless structs.
- Time storage: TEXT `2006-01-02T15:04:05.000Z` (UTC, ms). Domain time always comes from `clock.Clock`; never call `time.Now()` in `service/`, `repository/` or `jobs/`.
- IDs: `ids.New()` returns a UUIDv7 string.
- Tokens: prefixes `pt_at_`, `pt_rt_`, `pt_ws_`. Access TTL 15 min, refresh 90 days sliding, grace 30 s, web session 30 days sliding.
- Upload defaults: `max_file_bytes` 53687091200, `recommended_chunk_bytes` 8388608, session expiry 24 h, reserve 1 GiB.
- Payload constants A/B/C/V and every problem code/status: P§8 and P§10.1, verbatim.
- Test commands run from `server/`: `go test ./...`, plus `go test -race ./...` where the task says so. `go vet ./...` must stay clean.

## Review Focus

1. **Drop mid-PATCH on Windows.** The client disconnects after N bytes. Expect the offset to equal the bytes fsynced, and resume to work. Pinned: Task 12 `TestAppendDropKeepsBytes`, Task 15 vector `resume_after_drop`.
2. **Same file from two devices at once.** Concurrent create/append for one `(owner, sha256)`. Expect one session, the second PATCH to get `423`, and one asset. Pinned: Task 12 `TestConcurrentAppendLocked`, Task 17 property invariant 1.
3. **Crash between file move and catalog insert.** Expect recovery to insert exactly one asset and leave no orphan. Pinned: Task 16 matrix.
4. **Filenames that are hostile on Windows** (`CON.jpg`, `a:b.jpg`, 300-byte names, emoji, NFD input). Expect a sanitized, NFC, unique path under 240 bytes. Pinned: Task 6 `TestSanitizeFilename` table and `FuzzSanitizeFilename`.
5. **ffmpeg missing or a corrupt media file.** Expect the job to fail and retry up to max attempts, then `dead`; the server stays healthy and the asset stays browsable without a thumbnail. Pinned: Task 20 `TestThumbnailJobCorruptInput`, `TestThumbnailJobNoFFmpeg`.

## 2B design (rulings; no separate spec)

- **Fast date probe at finalize** (S§6.3 `DateProbe`). It reads the first 512 KiB of the staged file:
  - Images: imagemeta EXIF `DateTimeOriginal` + `OffsetTimeOriginal` → `taken_at_source=exif`.
  - Video (`video/*`): ISO-BMFF `mvhd` creation time parsed in pure Go → `container`. If `mvhd` is not in the first 512 KiB, return unknown.
  - It never errors the upload.
- **Date fallback order:** probe → client `created_at` (`client`) → client `modified_at` (`file`) → none (`taken_at` null, source `unknown`; the path uses receive time).
- **`extract_metadata` job:**
  - Images: imagemeta for width/height (orientation-corrected), GPS `lat`/`lon`, and the date if missing.
  - Video: `ffprobe -v error -print_format json -show_format -show_streams` for width, height, `duration_ms`, codecs, rotation and `creation_time`.
  - Updates the asset row and appends `asset.upsert`.
  - For video it then enqueues `transcode_video` when the file is not browser-playable.
  - The library path never changes.
- **`generate_thumbnails` job:**
  - Outputs `derived/<id[0:2]>/<id[2:4]>/<asset_id>/thumb.jpg` (long side 320 px, q 80) and `preview.jpg` (long side 1600 px, q 85).
  - Decoder choice:
    - Pure Go (`image/jpeg`, `image/png`, `image/gif`, `x/image/webp`) for jpeg/png/gif/webp, with EXIF orientation applied.
    - Everything else (HEIC, AVIF, TIFF, RAW, video): `ffmpeg -nostdin -v error -i <src> -frames:v 1 -vf "scale=w:h:force_original_aspect_ratio=decrease" -q:v 3 <tmp>.jpg`. Video seeks to `min(1s, duration/2)`.
  - Writes tmp → rename. Sets `thumbnails_ready=1` and appends `asset.upsert`.
  - Images never upscale.
- **Browser-playable:** container `mp4`/`mov` with codec `h264`, or `webm` with `vp8`/`vp9`/`av1`, and audio absent or `aac`/`opus`/`mp3`.
  - `transcode_video` runs `ffmpeg -nostdin -v error -i src -c:v libx264 -preset veryfast -crf 23 -c:a aac -b:a 128k -movflags +faststart -pix_fmt yuv420p tmp.mp4`, then renames to `web.mp4`.
  - `playback` serves the original if playable, else `web.mp4` if present, else `404 not_ready`. Photos return `404 not_found`.
  - Live-photo playback serves the live video component.
- **Locating ffmpeg/ffprobe:** config `media.ffmpeg_path` and `media.ffprobe_path`, else PATH. If one is missing, its jobs return a retryable error ("ffmpeg unavailable") and `server/info` still works. `readyz` is unaffected.
- **Thumbnail endpoint:** `ETag: "<sha256>-<size>"`, `Cache-Control: private, max-age=31536000, immutable`. Missing → `404 not_ready`.
- **Purge** deletes the derived directory.
- **Media job concurrency** is a separate runner pool sized `media.workers` (default `max(1, NumCPU/2)`).
- **Deferred (ruling):** `reverse_geocode` (needs the GeoNames dataset) moves to sub-project 5 (search). If wrong, it costs adding one job later; nothing in 2A/2B depends on it.

---

### Task 1: Contract amendments, ADRs, branch scaffolding

**Files:**
- Modify: `api/openapi.yaml`, `api/protocol/sync-protocol.md` (§6.3 note), `docs/adr/0006-tus-resumable-uploads.md`
- Create: `docs/adr/0012-deterministic-refresh-successors.md`
- Regenerate: `server/internal/httpapi/gen/api.gen.go`, plus other generated clients via `task gen:ts` if it runs without Docker (skip Dart, Kotlin and Swift; CI regenerates. Note this in the report).
- Modify: `docs/superpowers/specs/2026-10-03-pictunnel-system-design.md`: §6 Uploads row → "Own tus handler (ADR 0006)"; §14 server line → "see 2A spec S§2.1".

**Interfaces:** Produces the gen types `SetupFirstAdminParams` with `PicTunnelSetupToken *string`, and `412` response objects for the five tus operations.

- [ ] **Step 1:** Add to `setupFirstAdmin` an optional header parameter `PicTunnel-Setup-Token` (string), described per S§4.1, and a `403` response referencing the existing Problem response.
- [ ] **Step 2:** Add a `412` response (Problem, `invalid_request`, header `Tus-Version`) to `createUpload`, `getUploadOffset`, `appendUpload` and `terminateUpload`. `optionsUploads` gets none, because tus exempts OPTIONS.
- [ ] **Step 3:** Run `pnpm --dir api run lint` and `pnpm --dir api run test`. Expect them to pass.
- [ ] **Step 4:** Regenerate the Go code and run `go build ./... && go test ./...` in `server/`. Expect a pass.
- [ ] **Step 5:** ADR 0006: change the Decision text to "served by PicTunnel's own tus handler (`server/internal/httpapi/tus`)". Add an "Amended 2026-10-13" note giving the rationale from S§12 row 1. ADR 0012: Context/Decision/Consequences per S§4.2 (HMAC successor derivation, `secret.key`).
- [ ] **Step 6:** Commit: `git commit -s -m "docs(api): setup token header, tus 412, ADR 0006 amendment and ADR 0012"`.

### Task 2: Foundations — clock, ids, config, apperr

**Files:**
- Create: `server/internal/clock/clock.go`, `server/internal/clock/clocktest/fake.go`, `server/internal/ids/ids.go`
- Create: `server/internal/config/config.go`, `config_test.go`
- Create: `server/internal/apperr/{error.go,catalogue.go,auth.go,pairing.go,upload.go,sync.go,assets.go,request.go,server.go}`, `apperr_test.go`

**Interfaces (produces):**
```go
package clock
type Clock interface{ Now() time.Time }      // always UTC
type Real struct{}                              // Now() = time.Now().UTC()
// clocktest
func NewFake(t time.Time) *Fake; func (f *Fake) Now() time.Time; func (f *Fake) Advance(d time.Duration); func (f *Fake) Set(t time.Time) // goroutine-safe

package ids
func New() string // uuid.Must(uuid.NewV7()).String()

package config
type Config struct {
  DataDir, LibraryDir string
  Server struct{ Name, HTTPSAddr, LocalAddr string; PublicURLs []string }
  TLS struct{ Mode, CertFile, KeyFile string }            // Mode: self-signed|files|off
  Discovery struct{ MDNS bool }
  Upload struct{ MaxFileBytes, RecommendedChunkBytes int64 }
  Storage struct{ ReserveBytes int64 }
  Trash struct{ RetentionDays int }
  Clients struct{ MinVersion map[string]string }        // android, ios, web
  RateLimit struct{ Enabled bool }
  Media struct{ FFmpegPath, FFprobePath string; Workers int }
  Jobs struct{ Workers int }
  Log struct{ Level, Format string }
}
func Default() Config
func Load(args []string, env []string) (Config, error) // flags > env PICTUNNEL_<SECTION>_<KEY> > <data_dir>/config.toml > defaults; validates
```
```go
package apperr
type Error struct{ Code string; Status int; Title, Detail string; Extra map[string]any; Headers http.Header }
func (e *Error) Error() string
func As(err error) (*Error, bool)
var Catalogue map[string]int // all 24 codes of P§8 → HTTP status
// one constructor per code, e.g.:
func InvalidRequest(detail string) *Error; func CursorRequired() *Error; func PairingCodeInvalid() *Error
func Unauthorized() *Error; func TokenExpired() *Error; func RefreshTokenReused() *Error; func Forbidden(detail string) *Error
func NotFound() *Error; func NotReady() *Error; func OffsetMismatch(current int64) *Error /* Headers Upload-Offset */
func LengthMismatch() *Error; func Tombstoned(deletedAt time.Time) *Error; func PairPrimaryMissing() *Error
func SetupAlreadyDone() *Error; func CursorExpired() *Error; func FileTooLarge(max int64) *Error; func QuotaExceeded() *Error
func UploadLocked() *Error; func ClientTooOld(min string) *Error; func RateLimited(retryAfter time.Duration) *Error /* Retry-After */
func ChecksumMismatch() *Error; func Internal() *Error; func ServerUnavailable(retryAfter time.Duration) *Error; func InsufficientStorage() *Error
func TusPrecondition() *Error // 412, Code "invalid_request", Headers Tus-Version: 1.0.0 (S§6.1)
```

Defaults are those in S§10.2. Additional defaults: `RateLimit.Enabled=true`, `Jobs.Workers=2`, `Media.Workers=max(1,NumCPU/2)`. The OS data dir is chosen with `runtime.GOOS`, and the Docker case is detected by `/.dockerenv`.

- [ ] **Step 1:** Write failing tests:
  - `TestFakeClockAdvance`.
  - `TestIDsAreV7Sortable`: 1000 ids, sorted order equals creation order, version nibble is `7`.
  - `TestConfigPrecedence`: a TOML file sets `trash.retention_days=10`, env `PICTUNNEL_TRASH_RETENTION_DAYS=20`, flag `--trash.retention-days=30` → 30; without the flag → 20.
  - `TestConfigValidation`: bad `tls.mode` errors; `max_file_bytes<=0` errors.
  - `TestCatalogueComplete`: parse the P§8 table from `../../../api/protocol/sync-protocol.md` (rows matching `` ^\| `([a-z_]+)` \| (\d{3}) ``) and assert it equals `Catalogue` exactly, both ways.
  - `TestConstructorsMatchCatalogue`: every constructor's `Status == Catalogue[Code]`, except `TusPrecondition`.
- [ ] **Step 2:** Run `go test ./internal/clock/... ./internal/ids/... ./internal/config/... ./internal/apperr/...`. Expect FAIL (undefined).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the tests again. Expect PASS.
- [ ] **Step 5:** `git commit -s -m "feat(server): clock, ids, config and apperr foundations"`.

### Task 3: Store, schema and sqlc setup

**Files:**
- Create: `server/internal/store/store.go`, `store_test.go`, `server/internal/store/migrations/0001_init.sql`, `server/internal/store/sqlc.yaml`, `server/internal/store/sql/` (query files, one per table, added in Tasks 4–5)
- Modify: `server/go.mod`: add `tool github.com/sqlc-dev/sqlc/cmd/sqlc` at v1.30.0, `modernc.org/sqlite`, `github.com/pressly/goose/v3`
- Modify: `Taskfile.yml`: `gen:sqlc` task (`go tool sqlc generate -f internal/store/sqlc.yaml`, dir `server`) and a `check:sqlc` task (`go tool sqlc diff -f internal/store/sqlc.yaml`)

**Interfaces (produces):**
```go
package store
type Store struct{ W *sql.DB; R *sql.DB; path string }
func Open(ctx context.Context, path string) (*Store, error)
// W: MaxOpenConns(1), DSN pragmas foreign_keys(1), journal_mode(WAL), synchronous(FULL), busy_timeout(5000), _txlock=immediate
// R: MaxOpenConns(4), pragmas foreign_keys(1), busy_timeout(5000), query_only(1)
func (s *Store) Close() error
func (s *Store) QuickCheck(ctx context.Context) error         // PRAGMA quick_check == "ok"
func (s *Store) PendingMigrations(ctx context.Context) (bool, error)
func (s *Store) Migrate(ctx context.Context) error             // goose, embedded FS, dialect sqlite3
func (s *Store) BackupTo(ctx context.Context, dst string) error // VACUUM INTO (dst must not exist)
func (s *Store) WithTx(ctx context.Context, fn func(tx *sql.Tx) error) error // on W; rollback on error/panic
```
`0001_init.sql` creates every table, column and index in the S§3 table, exactly as named there. Columns:
- `assets`: `id TEXT PK, owner_id TEXT NOT NULL REFERENCES users(id), sha256, size_bytes INTEGER, mime, kind, filename, original_path, taken_at NULL, taken_at_offset_minutes NULL, taken_at_source, width NULL, height NULL, duration_ms NULL, lat NULL, lon NULL, state DEFAULT 'active', trashed_at NULL, stack_key NULL, stack_id NULL, thumbnails_ready INTEGER DEFAULT 0, video_codec NULL, audio_codec NULL, container NULL, playable INTEGER NULL, created_at, updated_seq INTEGER NOT NULL DEFAULT 0`. The last four columns are added for 2B.
- `upload_sessions.meta_json` holds the parsed tus metadata as a JSON object.
- `jobs.state`: `pending|running|done|dead`.

`sqlc.yaml`: version 2, engine `sqlite`, schema `migrations`, queries `sql`, Go package `queries`, out `queries`, `emit_pointers_for_null_types: true`.

- [ ] **Step 1:** Failing tests:
  - `TestOpenMigrateQuickCheck`: temp dir, `Open`, `PendingMigrations` true, `Migrate`, then false, `QuickCheck` nil, and `PRAGMA journal_mode` on W returns `wal`.
  - `TestReaderIsReadOnly`: an `INSERT` via R errors.
  - `TestWithTxRollback`: fn returns an error, so the row is absent.
  - `TestBackupTo`: the backup file opens and has the tables.
  - `TestPartialUniqueUploadSessions`: two `receiving` rows with the same `(owner, sha256)` → unique error; a `done` and a `receiving` row → ok.
  - `TestForeignKeysOn`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement and add one trivial query file (`sql/server_state.sql`: `-- name: GetServerState :one SELECT value FROM server_state WHERE key = ?;` and `UpsertServerState`) so sqlc generates. **Step 4:** Run `go tool sqlc generate -f internal/store/sqlc.yaml`, then the tests → PASS. `CGO_ENABLED=0 go build ./...` passes.
- [ ] **Step 5:** `git commit -s -m "feat(server): sqlite store, schema migration and sqlc"`.

### Task 4: Repositories — accounts and credentials

**Files:**
- Create: `server/internal/store/sql/{server_state,users,devices,access_tokens,refresh_tokens,web_sessions,pairing_codes,audit_log}.sql`
- Create: `server/internal/repository/{server_state,users,devices,access_tokens,refresh_tokens,web_sessions,pairing_codes,audit_log}_repository.go` and a `_test.go` for each
- Create: `server/internal/repository/repotest/repotest.go`: `func NewStore(t *testing.T) *store.Store` (temp dir, migrated)

**Interfaces (produces).** Domain row structs live in `repository`, with `time.Time` and `*T` for nullables. All methods are `(ctx, db queries.DBTX, …)`.
- `ServerStateRepository`: `Get(key) (string, bool, error)`, `Set(key, value)`.
- `UsersRepository`: `Insert(User)`, `GetByID`, `GetByUsername` (NOCASE), `Count`, `SetPasswordHash(id, hash)`, `List`. `User{ID, Username, Slug, DisplayName, Role, PasswordHash string; QuotaBytes *int64; CreatedAt time.Time; DisabledAt *time.Time}`.
- `DevicesRepository`: `Insert(Device)`, `Get(id)`, `ListByUser(userID)` (non-revoked), `Rename(id, name)`, `Revoke(id, at)`, `TouchLastSeen(id, at)`.
- `AccessTokensRepository`: `Insert(hash, deviceID, expiresAt)`, `Get(hash)`, `DeleteByDevice(deviceID)`, `DeleteExpired(now) (int64, error)`.
- `RefreshTokensRepository`: `Insert(RefreshToken)`, `Get(hash)`, `MarkRotated(hash, at) (bool, error)` (only from `active`), `RevokeFamily(familyID)`, `RevokeByDevice(deviceID)`, `DeleteExpired(now)`. `RefreshToken{Hash, DeviceID, FamilyID, State string; IssuedAt time.Time; RotatedAt *time.Time; ExpiresAt time.Time}`.
- `WebSessionsRepository`: `Insert`, `Get`, `Touch(hash, lastUsed, expires)`, `DeleteByDevice`, `DeleteExpired`.
- `PairingCodesRepository`: `Insert`, `Get(hash)`, `MarkRedeemed(hash, at) (bool, error)` (only if not redeemed, invalidated or expired), `InvalidateOutstanding(now)`, `DeleteExpired`.
- `AuditLogRepository`: `Append(AuditEvent)`, `List(limit)`.

- [ ] **Step 1:** Failing tests, one per repository:
  - Insert/get round trip, preserving times to the ms.
  - NOCASE username lookup.
  - `MarkRotated` is single-shot (the second call returns false).
  - `MarkRedeemed` is single-shot and refuses expired codes (`expires_at < now`).
  - `DeleteExpired` counts.
  - `ListByUser` excludes revoked devices.
- [ ] **Step 2:** FAIL. **Step 3:** Write the SQL and run sqlc generate; implement the repositories (row↔domain mapping, time parse/format helper in `repository/timefmt.go`). **Step 4:** PASS. **Step 5:** `git commit -s -m "feat(server): account and credential repositories"`.

### Task 5: Repositories — content, sync and jobs

**Files:**
- Create: `server/internal/store/sql/{assets,live_videos,library_paths,asset_sources,upload_sessions,tombstones,change_log,jobs}.sql`
- Create: `server/internal/repository/{assets,live_videos,library_paths,asset_sources,upload_sessions,tombstones,change_log,jobs}_repository.go` and their tests

**Interfaces (produces).** All `(ctx, db, …)`.
- `AssetsRepository`:
  - `Insert(Asset)` returns `ErrUniqueViolation` (exported in `repository/errors.go`, detected from the sqlite error code 2067 or 1555).
  - `Get(ownerID, id)`, `GetByID(id)` (unscoped, for jobs), `GetBySHA(ownerID, sha)`, `ListBySHAs(ownerID, []string)`.
  - `SetState(id, state, trashedAt *time.Time, seq)`, `SetUpdatedSeq(id, seq)`, `UpdateMetadata(id, MetadataUpdate, seq)`, `SetThumbnailsReady(id, seq)`, `Delete(id)`.
  - `ListTrashedBefore(ownerID string /*"" = all*/, before time.Time, limit)`, `ListTrashed(ownerID)`, `Page(ownerID, afterID string, limit)` (ordered by id).
  - `SumSizes(ownerID) int64`.
- `Asset` holds every column of Task 3.
- `LiveVideosRepository`: `Insert`, `GetByAsset(assetID)`, `ListByAssets([]id)`, `SumSizes(ownerID)` (join-free: `owner_id` stored on the row; add an `owner_id` column to `live_videos` in 0001 if Task 3 omitted it).
- `LibraryPathsRepository`: `Reserve(LibraryPath)` (`ErrUniqueViolation` on a collision), `Exists(pathKey)`, `PointToAsset(pathKey, assetID)`, `ReleaseByUpload(uploadID)`, `ReleaseByAsset(assetID)`, `ListAll()` (for the orphan sweep).
- `AssetSourcesRepository`: `Upsert(deviceID, localID, assetID, at)`, `ListByAsset(assetID) ([]AssetSource, error)`.
- `UploadSessionsRepository`:
  - `Insert`, `Get(id)`, `GetActive(ownerID, sha)` (receiving or finalizing), `ListActiveBySHAs(ownerID, []string)`.
  - `UpdateOffset(id, offset, updatedAt, expiresAt)`, `SetFinalizing(id, destPath, at)`, `SetDone(id, assetID, created bool, at)`, `SetFailed(id, code, at)`.
  - `ListByState(state)`, `ListExpired(now)`, `ListStuckFinalizing(before)`, `DeleteOlderThan(states []string, before)`, `Delete(id)`.
  - `SumActiveLengths(ownerID)`.
- `TombstonesRepository`: `Insert`, `Get(owner, sha)`, `ListBySHAs`, `Delete(owner, sha) (bool, error)`, `Page(owner, afterDeletedAt, afterSHA, limit)` (deleted_at desc, sha asc).
- `ChangeLogRepository`: `Append(ownerID, kind, assetID, at) (seq int64, error)` and `DeleteForAsset(assetID, exceptSeq)`. The service calls both in one tx; the repository does not orchestrate. Also `ListAfter(ownerID, cursor, limit)`, `Head()` (max seq from `sqlite_sequence`, else 0), `DeleteBefore(t time.Time) (maxDeleted int64, n int64, error)`.
- `JobsRepository`:
  - `Enqueue(Job)` is idempotent through the partial unique index: `INSERT … ON CONFLICT DO NOTHING`, returning `inserted bool`.
  - `LeaseNext(kinds []string, now, leaseUntil) (*Job, error)` is atomic: `UPDATE … WHERE id = (SELECT … LIMIT 1) RETURNING`.
  - `ExtendLease`, `Complete(id, at)`, `Fail(id, errText, runAfter, at)`, `Dead(id, errText, at)`, `ListPending(kind)`, `Counts()`.

- [ ] **Step 1:** Failing tests:
  - Unique `(owner, sha256)` returns `ErrUniqueViolation`; the same sha under a different owner is ok.
  - `Reserve` collision on equal `path_key`.
  - `GetActive` ignores done and failed sessions.
  - `LeaseNext` never returns the same job twice under 8 concurrent goroutines (run with `-race`).
  - `Enqueue` dedupe while pending; re-enqueue after `Complete` is allowed.
  - `ChangeLog` `Append` seqs strictly increase and are not reused after delete (AUTOINCREMENT).
  - `DeleteBefore` returns the max deleted seq.
  - `Tombstones.Page` ordering.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** `go test -race ./internal/repository/...` → PASS. **Step 5:** `git commit -s -m "feat(server): content, sync and job repositories"`.

### Task 6: storage — filesystem port, sanitizer, commit, free space

**Files:**
- Create: `server/internal/storage/{fs.go,osfs.go,sanitize.go,commit.go,freespace_unix.go,freespace_windows.go,fsync_unix.go,fsync_windows.go}`, `storage_test.go`, `sanitize_test.go` (+ `FuzzSanitizeFilename`)
- Create: `server/internal/storage/storagetest/faultfs.go`

**Interfaces (produces):**
```go
package storage
type FS interface {
  Create(name string) (File, error); OpenFile(name string, flag int, perm os.FileMode) (File, error); Open(name string) (File, error)
  Rename(from, to string) error; Remove(name string) error; RemoveAll(path string) error; MkdirAll(path string, perm os.FileMode) error
  Stat(name string) (os.FileInfo, error); SyncDir(dir string) error; ReadDir(dir string) ([]os.DirEntry, error)
}
type File interface{ io.Reader; io.Writer; io.Seeker; io.Closer; Sync() error; Truncate(size int64) error; Stat() (os.FileInfo, error) }
func OS() FS
func SanitizeFilename(name string) string            // S§6.3 rules; result NFC; never empty ("file")
func SplitExt(name string) (stem, ext string)         // ext includes dot, last dot only, ".tar.gz" -> stem "x.tar", ext ".gz"
func PathKey(rel string) string                       // strings.ToLower(norm.NFC.String(filepath.ToSlash(rel)))
func FitPath(dir, stem, ext string, max int) string   // trims stem (rune-safe) so len(dir+"/"+stem+ext) < max bytes
func Commit(fs FS, staging, dest string) error        // S§6.2 step 3: MkdirAll(dest dir); Sync staging; Rename; on *LinkError with EXDEV (errors.Is(err, syscall.EXDEV) or windows ERROR_NOT_SAME_DEVICE=17) → copy to dest+".ptpart", Sync, Rename, SyncDir, Remove(staging)
type FreeSpaceFunc func(path string) (uint64, error)
func FreeSpace(path string) (uint64, error)           // x/sys statfs / GetDiskFreeSpaceEx
// storagetest
type FaultFS struct{ storage.FS; RenameErr func(from, to string) error; /* inject EXDEV */ }
```
`SyncDir` on Windows is best-effort: it opens the dir with `FILE_FLAG_BACKUP_SEMANTICS` and calls `FlushFileBuffers`, ignoring access-denied.

- [ ] **Step 1:** Failing tests. `TestSanitizeFilename` table:

| Input | Output |
|---|---|
| `a/b.jpg` | `a_b.jpg` |
| `a\b.jpg` | `a_b.jpg` |
| `a:b*?.jpg` | `a_b__.jpg` |
| `CON.jpg` | `_CON.jpg` |
| `com1.txt` | `_com1.txt` |
| `name. ` | `name` |
| `\x00x.jpg` | `_x.jpg` |
| `""` | `file` |
| NFD `é.jpg` | NFC `é.jpg` |
| `Photo 🙂.JPG` | unchanged |

  Other tests:
  - `TestFitPath`: a 300-byte stem fits under 240 bytes and keeps the extension, with no invalid UTF-8.
  - `TestCommitSameVolume`.
  - `TestCommitCrossVolume`: FaultFS returns EXDEV on the first rename. Expect the dest content equals the source, the staging file is gone and no `.ptpart` remains.
  - `TestPathKeyCaseAndNFC`.
  - `FuzzSanitizeFilename`: output contains none of ``/\:*?"<>|``, is valid UTF-8 and NFC, and is non-empty.
- [ ] **Step 2–4:** FAIL → implement → PASS (also `go test -run x -fuzz FuzzSanitizeFilename -fuzztime 20s ./internal/storage`).
- [ ] **Step 5:** `git commit -s -m "feat(server): storage port with sanitizer and durable commit"`.

### Task 7: tlsutil

**Files:** Create `server/internal/tlsutil/{tlsutil.go,tlsutil_test.go}`

**Interfaces (produces):**
```go
package tlsutil
type Material struct{ Cert tls.Certificate; Leaf *x509.Certificate; CAPEM []byte; SPKIFingerprint string /* b64url sha256 of leaf SPKI */ }
func EnsureSelfSigned(dir, serverID string, hosts []string, ips []net.IP, now time.Time) (*Material, error) // S§5.1
func LoadFiles(certFile, keyFile string) (*Material, error)
func SPKIFingerprint(cert *x509.Certificate) string
func LocalIPs() ([]net.IP, error) // non-loopback up interfaces
```
- [ ] **Step 1:** Failing tests:
  - First call creates `ca.crt`, `ca.key`, `server.crt` and `server.key`; the leaf verifies against the CA for `localhost` and `127.0.0.1`.
  - A second call with the same inputs does not rewrite (mtime unchanged).
  - A call with a new IP renews the leaf and **keeps the same SPKI fingerprint**.
  - A call at `now = notAfter - 29 days` renews with the same fingerprint.
  - The fingerprint equals the b64url (no padding) of `sha256(leaf.RawSubjectPublicKeyInfo)`.
  - On non-Windows, key files have mode 0600.
- [ ] **Step 2–4:** FAIL → implement (ECDSA P-256; CA 10 years; leaf 825 days; temp file + rename) → PASS.
- [ ] **Step 5:** `git commit -s -m "feat(server): self-signed TLS with stable SPKI pin"`.

### Task 8: Job runner

**Files:** Create `server/internal/jobs/{runner.go,scheduler.go,runner_test.go}`

**Interfaces (produces):**
```go
package jobs
type Handler func(ctx context.Context, payload []byte) error
type Permanent struct{ Err error } // returning *Permanent → dead immediately
type Pool struct{ Name string; Workers int; Kinds []string }
type Periodic struct{ Kind string; Every time.Duration }
type Runner struct{ /* store, jobs repo, clock, logger, handlers, pools */ }
func New(st *store.Store, repo repository.JobsRepository, clk clock.Clock, log *slog.Logger) *Runner
func (r *Runner) Register(kind string, h Handler, maxAttempts int)
func (r *Runner) Enqueue(ctx context.Context, db queries.DBTX, kind, dedupeKey string, payload []byte, runAfter time.Time) error
func (r *Runner) Start(ctx context.Context, pools []Pool, periodic []Periodic) // lease 5m, heartbeat every 1m, poll 1s or wake on Enqueue via channel
func (r *Runner) Stop()                                                      // waits for in-flight
func (r *Runner) RunNow(ctx context.Context, kind string) error              // run every pending job of kind synchronously; if kind is periodic also run handler once with nil payload
```
Backoff: `min(1h, 30s·2^(attempts-1))` with full jitter (`rand.N`). The default max attempts is 8. The scheduler enqueues `dedupe_key = kind + ":" + now.Truncate(Every).Format(RFC3339)`.

- [ ] **Step 1:** Failing tests (fake clock):
  - A handler error schedules a retry with `run_after` in `(now, now+30s]`.
  - After `maxAttempts` failures the job is `dead`.
  - `*Permanent` → `dead` on the first attempt.
  - `RunNow` executes a periodic handler once.
  - Enqueue dedupe.
  - `Stop` waits for a running handler.
  - Two pools never run kinds outside their list.
- [ ] **Step 2–4:** FAIL → implement → PASS with `-race`.
- [ ] **Step 5:** `git commit -s -m "feat(server): durable job runner and scheduler"`.

### Task 9: Account services — users, auth, devices, pairing

**Files:**
- Create: `server/internal/service/{principal.go,user_service.go,auth_service.go,device_service.go,pairing_service.go,password.go,tokens.go}` and their `_test.go`
- Create: `server/internal/conformance/pairing.go` (`ParsePairURI` per P§10.3) and `pairing_test.go` (runs every `vectors/pairing/qr.json` case)

**Interfaces (produces):**
```go
package service
type Principal struct{ UserID, Username, Slug, Role, DeviceID, Platform string; Via string /* "bearer"|"cookie" */; SessionHash string }
type TokenPair struct{ AccessToken string; AccessExpiresAt time.Time; RefreshToken string; RefreshExpiresAt time.Time }
type DeviceInfo struct{ Name, Platform, AppVersion string }

type UserService struct{ /* UserServiceDeps{Store, Users, ServerState, Audit, Clock} */ }
func NewUserService(d UserServiceDeps) *UserService
func (s *UserService) Setup(ctx context.Context, username, password, displayName string) (repository.User, error) // tx: Count()==0 else SetupAlreadyDone; role admin
func (s *UserService) Create(ctx context.Context, username, password, displayName, role string) (repository.User, error)
func (s *UserService) ResetPassword(ctx context.Context, username string) (newPassword string, err error)
func (s *UserService) EnsureSetupToken(ctx context.Context) (token string, created bool, err error) // stored hashed in server_state "setup_token_hash"; token returned only when created
func (s *UserService) CheckSetupToken(ctx context.Context, token string) bool

type AuthService struct{ /* deps: Store, Users, Devices, AccessTokens, RefreshTokens, WebSessions, Audit, Clock, Secret []byte */ }
func (s *AuthService) Login(ctx, username, password string, dev DeviceInfo) (repository.User, repository.Device, TokenPair, error)
func (s *AuthService) LoginCookie(ctx, username, password string) (user repository.User, device repository.Device, sessionToken, csrfToken string, expires time.Time, err error)
func (s *AuthService) IssueForDevice(ctx context.Context, db queries.DBTX, deviceID string) (TokenPair, error) // used by pairing
func (s *AuthService) Refresh(ctx context.Context, refreshToken string) (TokenPair, error)   // S§4.2 HMAC successor + grace + reuse
func (s *AuthService) AuthenticateBearer(ctx context.Context, token string) (Principal, error)  // Unauthorized / TokenExpired
func (s *AuthService) AuthenticateCookie(ctx context.Context, token string) (Principal, error)
func (s *AuthService) CheckCSRF(ctx context.Context, p Principal, csrf string) bool
func (s *AuthService) Logout(ctx context.Context, p Principal) error
func (s *AuthService) RevokeDevice(ctx context.Context, db queries.DBTX, deviceID string) error

type DeviceService struct{ /* Store, Devices, Auth *AuthService */ }
func (s *DeviceService) List(ctx, p Principal) ([]repository.Device, error)
func (s *DeviceService) Rename(ctx, p Principal, id, name string) (repository.Device, error) // NotFound if not caller's
func (s *DeviceService) Revoke(ctx, p Principal, id string) error

type PairingService struct{ /* Store, PairingCodes, Devices, Users, Auth, Clock, ServerID, Fingerprint, Endpoints func() []string */ }
func (s *PairingService) Create(ctx, p Principal) (code, qrURI string, expiresAt time.Time, err error)
func (s *PairingService) Redeem(ctx, code string, dev DeviceInfo) (repository.User, repository.Device, TokenPair, error)
```
Token rules:
- Password hashing per S§4.1 (argon2id PHC string, with a constant-time compare).
- Refresh per S§4.2. Successor expiry is `issued_at + 90d`. On first rotation, insert the successor rows (access and refresh) with the derived hashes. On a grace replay, recompute the derived tokens, check that their hashes exist, and return them with the stored expiries.
- A wrong or garbled token gets `Unauthorized`, not reuse.
- Pairing failure handling: an in-memory counter guarded by a mutex; at 5 failures call `InvalidateOutstanding` and reset.
- QR building follows P§6.3; `u` is URL-encoded and repeated.

- [ ] **Step 1:** Failing tests:
  - Setup:
    - Setup twice returns `setup_already_done`.
    - A username outside `^[a-z0-9][a-z0-9._-]{1,31}$` or a password under 10 chars returns `invalid_request`.
  - Refresh:
    - `TestRefreshRotation`: refresh → new pair; the old access token still works until expiry.
    - `TestRefreshGraceIdempotent`: refresh twice within 30 s (fake clock +10 s) → identical pairs.
    - `TestRefreshReuseRevokesFamily`: +31 s → `refresh_token_reused`, the device is revoked and a bearer with the new access token → `unauthorized`.
    - `TestRefreshGraceSurvivesRestart`: new `AuthService` instance with the same secret and DB, inside the grace window → identical pair.
  - Access tokens:
    - `TestAccessExpiry`: +15 min +1 s → `token_expired`.
    - `TestRevokedDeviceUnauthorized`.
  - Cookie: `TestCookieLoginCSRF`.
  - Devices: `TestDeviceRenameOtherUserNotFound`.
  - Pairing:
    - `TestPairingSingleUse`.
    - `TestPairingExpired` (+10 min +1 s).
    - `TestPairingFiveFailuresInvalidate`.
    - `TestQRURIParsesPerVectors`: build a URI, then `conformance.ParsePairURI` succeeds and its `fp` equals the fingerprint.
    - `TestPairingVectors`: every qr.json case passes `ParsePairURI` expectations.
- [ ] **Step 2–4:** FAIL → implement → `go test -race ./internal/service/... ./internal/conformance/...` PASS.
- [ ] **Step 5:** `git commit -s -m "feat(server): users, tokens, devices and pairing services"`.

### Task 10: Library and finalize services, recovery, date probe

**Files:**
- Create: `server/internal/service/{library_service.go,finalize_service.go,failpoints.go}` and their tests
- Create: `server/internal/media/probe/{date.go,mvhd.go,date_test.go}` (pure Go; imagemeta for EXIF)
- Create: `server/internal/media/probe/testdata/`: small fixtures generated with ffmpeg and committed. `exif.jpg` is a 64×48 JPEG with `DateTimeOriginal 2024:05:06 10:00:00` and `OffsetTimeOriginal +02:00` (use ffmpeg and then write EXIF with a tiny Go test helper, or commit a hand-made file). `clip.mp4` is a 1 s 64×48 h264 clip with `creation_time=2023-01-02T03:04:05Z`.

**Interfaces (produces):**
```go
package probe
type DateResult struct{ Time time.Time; OffsetMinutes *int; Source string /* "exif"|"container" */ }
func FastDate(r io.ReaderAt, size int64, mime string) (DateResult, bool) // reads ≤512 KiB; never panics (recover)

package service
type Failpoints interface{ Hit(name string) error } // names: before_tx1, after_tx1, after_copy, after_rename, after_tx2, append_after_fsync, append_before_commit
type DateProbe func(r io.ReaderAt, size int64, mime string) (probe.DateResult, bool)

type LibraryService struct{ /* LibraryPaths repo, Clock, LibraryDir string */ }
func (s *LibraryService) Assign(ctx context.Context, tx queries.DBTX, in AssignInput) (rel string, err error) // S§6.3; reserves; returns slash-separated rel path "alice/2024/05/IMG.JPG"
type AssignInput struct{ UserSlug, Filename string; Date time.Time; UploadID string; SiblingOf string /* rel path of primary for live video */ }

type FinalizeService struct{ /* deps: Store, Assets, LiveVideos, LibraryPaths, AssetSources, UploadSessions, Tombstones, ChangeLog, Jobs (runner.Enqueue), Library, FS, Clock, Probe, Failpoints, DataDir, LibraryDir */ }
type FinalizeResult struct{ AssetID string; Created bool }
func (s *FinalizeService) Finalize(ctx context.Context, sess repository.UploadSession, digest string) (FinalizeResult, error) // S§6.2 steps 1–5 incl. live_video path (P§5 H4): primary must exist else PairPrimaryMissing; attached → Created=false
func (s *FinalizeService) Recover(ctx context.Context) error   // S§6.2 table + stray .ptpart/staging sweep; idempotent
func (s *FinalizeService) RecoverStuck(ctx context.Context, olderThan time.Duration) error
```
Asset fields at insert:
- `kind`: `image/*` → `photo`, `video/*` → `video`, else `photo`.
- `taken_at`/`source` from the date order in the 2B design.
- `stack_key` from metadata. `stack_id` = the id of the first asset with the same owner and `stack_key` (null if none).

A live video sets the primary's `kind=live_photo` and appends `asset.upsert` for the primary.

Change log in tx2: `seq := Append(owner, "asset.upsert", assetID)`; `DeleteForAsset(assetID, seq)`; `SetUpdatedSeq(assetID, seq)`. Jobs enqueued: `extract_metadata` and `generate_thumbnails` with payload `{"asset_id":…}` and dedupe key = asset id.

- [ ] **Step 1:** Failing tests:
  - `TestAssignCollisionCaseNFC`: `Photo 🙂.JPG` then `photo 🙂.jpg` → second is `photo 🙂~2.jpg`.
  - `TestAssignSanitizesAndFits`.
  - `TestFinalizeCreatesAsset`: file at `library/alice/2024/05/…`, row, change entry, two jobs, `asset_sources` when `local_id` is set.
  - `TestFinalizeDigestMismatch` → `checksum_mismatch`, staging removed, session failed.
  - `TestFinalizeExistingResolves` → `Created=false`, staging removed.
  - `TestFinalizeTombstoneOverride` → tombstone deleted.
  - `TestFinalizeLiveVideoNeedsPrimary`.
  - `TestFinalizeLiveVideoAttach`: kind becomes `live_photo` and the file is a sibling with the same stem.
  - `TestRecoverDestValid`, `TestRecoverStagingOnly`, `TestRecoverNeither` (one test per S§6.2 table row, built by setting rows and files directly); recovery run twice gives the same result.
  - `TestFastDateJPEG` → 2024-05-06T08:00:00Z, offset 120, `exif`.
  - `TestFastDateMP4` → `container`.
  - `TestFastDateGarbage` → `ok=false`, no panic.
  - Fuzz `FuzzFastDate` (10 s).
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** `git commit -s -m "feat(server): library paths, finalize journal and recovery"`.

### Task 11: Upload service (tus state machine)

**Files:** Create `server/internal/service/{upload_service.go,upload_meta.go,upload_locks.go}`, `upload_service_test.go`, and `upload_meta_test.go` (+ `FuzzParseMetadata`)

**Interfaces (produces):**
```go
package service
type UploadMeta struct{ SHA256, Filename, Mime, LocalID, StackKey, PairRole, PairSHA256 string; CreatedAt, ModifiedAt *time.Time; OverrideTombstone bool }
func ParseUploadMetadata(header string) (UploadMeta, error) // P§7.3 keys; strict base64; required sha256 (^[0-9a-f]{64}$), filename, mime; pair_sha256 required iff pair_role=live_video → InvalidRequest
type CreateInput struct{ Length int64; Meta UploadMeta; Body io.Reader /* nil if none */; BodyChecksum []byte /* nil if none */ }
type UploadView struct{ ID string; Offset, Length int64; ExpiresAt time.Time; AssetID string; AssetCreated bool; Done bool }
type UploadService struct{ /* deps: Store, Sessions, Assets, LiveVideos, Tombstones, Users, Finalize *FinalizeService, FS, FreeSpace storage.FreeSpaceFunc, Clock, Failpoints, Cfg (max, reserve), StagingDir */ }
func (s *UploadService) Create(ctx context.Context, p Principal, in CreateInput) (UploadView, error) // P§7.3 precedence 1–7; outcome 3 inserts a done session row
func (s *UploadService) Head(ctx context.Context, p Principal, id string) (UploadView, error)       // NotFound for other owners/expired/failed
func (s *UploadService) Append(ctx context.Context, p Principal, id string, offset int64, body io.Reader, checksum []byte) (UploadView, error)
func (s *UploadService) Terminate(ctx context.Context, p Principal, id string) error
func (s *UploadService) ExpireSessions(ctx context.Context) error // job body for expire_uploads (calls Finalize.RecoverStuck(10m) too)
```
Append algorithm (S§6.1):
1. `TryLock` the session, else `UploadLocked`.
2. Load the row. If it is not `receiving` → `NotFound` (done → return its view).
3. If `offset != row.offset` → `OffsetMismatch(row.offset)`.
4. If the in-memory hasher is missing or behind, re-hash `[0, offset)` from staging. Truncate the staging file if it is longer; mark `failed` + `NotFound` if it is shorter.
5. Copy at most `length-offset` bytes, writing to file and hasher.
6. On body EOF or error: `Sync`, failpoint `append_after_fsync`, then `UpdateOffset(newOffset, now, now+24h)`, then failpoint `append_before_commit` (placed between the fsync and the DB commit for the crash test).
7. If `checksum` is set and the body hash mismatches, truncate back and return `ChecksumMismatch`.
8. If `newOffset == length`, call `Finalize`.
9. A body read error after a partial write still commits the partial offset and returns the read error, so the handler can tell the client went away.

The lock is held through finalize.

- [ ] **Step 1:** Failing tests (fake clock, real store, temp dirs, fake free space):
  - One test per precedence outcome 1–7, including the live-video `pair_primary_missing` path.
  - `TestCreateWithBodyFinalizes`.
  - `TestCreateDuplicateReturnsSameSession`.
  - `TestCreateDuplicateLengthMismatch`.
  - `TestAppendOffsetMismatch` reports the current offset.
  - `TestAppendDropKeepsBytes`: the body reader errors after 1,000,000 bytes, so `Head` reports 1000000.
  - `TestAppendResumeAfterRestart`: a new `UploadService` (no in-memory hasher) on the same dirs finishes and finalizes with the correct digest.
  - `TestConcurrentAppendLocked`: the second goroutine's call returns `UploadLocked` while the first blocks on a pipe.
  - `TestQuotaExceeded`, `TestInsufficientStorage`.
  - `TestExpireSessions`: +24 h +1 s → failed and staging deleted; done rows +7 d → deleted.
  - `TestTerminate`.
  - `TestOtherOwnerNotFound`.
  - `TestCooperativeDevices`: device B appends to device A's session.
  - `FuzzParseMetadata` (no panics; round-trips valid headers).
- [ ] **Step 2–4:** FAIL → implement → `go test -race` PASS.
- [ ] **Step 5:** `git commit -s -m "feat(server): tus upload state machine with resumable hashing"`.

### Task 12: Sync, asset and trash services plus periodic jobs

**Files:** Create `server/internal/service/{check_service.go,feed_service.go,asset_service.go,trash_service.go,maintenance_service.go,cursor.go}` and their tests

**Interfaces (produces):**
```go
type CheckItem struct{ SHA256 string; SizeBytes int64; LocalID string; ConfirmOnDisk bool }
type CheckOutcome struct{ SHA256, Verdict string; Asset *repository.Asset; HasLiveVideo bool; OnDisk *bool; Upload *UploadView; DeletedAt *time.Time }
func (s *CheckService) Check(ctx, p Principal, items []CheckItem) ([]CheckOutcome, error) // S§7 precedence; 1–1000 items else InvalidRequest
type AssetView struct{ repository.Asset; Live *repository.LiveVideo }
func (s *FeedService) Snapshot(ctx, p Principal, pageToken string, limit int) (cursor string, assets []AssetView, next string, hasMore bool, err error)
type Change struct{ Seq int64; Kind string; Asset *AssetView; AssetID string }
func (s *FeedService) Changes(ctx, p Principal, cursor string, limit int) ([]Change, string /*next*/, bool, error) // CursorRequired / InvalidRequest / CursorExpired (S§7 rule: floor key "change_log_floor" exists && c ≤ floor)
func EncodeCursor(seq int64) string; func DecodeCursor(s string) (int64, error) // "c_%016x"
func (s *AssetService) Get(ctx, p Principal, id string) (AssetView, error)
func (s *AssetService) OpenOriginal(ctx, p Principal, id string) (f storage.File, a repository.Asset, err error)
func (s *AssetService) OpenThumbnail(ctx, p Principal, id, size string) (storage.File, repository.Asset, error) // 2B: derived file or NotReady
func (s *AssetService) OpenPlayback(ctx, p Principal, id string) (storage.File, string /*mime*/, error)            // 2B rules
type BulkResult struct{ Succeeded []string; Failed []BulkFailure }; type BulkFailure struct{ AssetID, Code string }
func (s *TrashService) Trash(ctx, p, ids []string) (BulkResult, error)
func (s *TrashService) Restore(ctx, p, ids []string) (BulkResult, error)
func (s *TrashService) Purge(ctx, p, ids []string) (BulkResult, error) // not_trashed / not_found
func (s *TrashService) Empty(ctx, p) (int, error)
func (s *TrashService) ListTombstones(ctx, p, cursor string, limit int) ([]repository.Tombstone, string, bool, error)
func (s *TrashService) DeleteTombstone(ctx, p, sha string) error
func (s *TrashService) PurgeExpired(ctx context.Context) error            // purge_trash job body, retention from cfg, + orphan sweep of library and derived dirs
func (s *MaintenanceService) CompactChangeLog(ctx context.Context) error   // 90d; raise floor
func (s *MaintenanceService) ExpireTokens(ctx context.Context) error
func (s *MaintenanceService) BackupDatabase(ctx context.Context) error     // <data>/backups/pictunnel-YYYYMMDD.db, keep 7
```
Every state change appends the change log (`Append` + `DeleteForAsset` + `SetUpdatedSeq`) in the same tx. Purge writes `asset.removed`.

- [ ] **Step 1:** Failing tests:
  - `TestCheckVerdicts`: all four verdicts, input order kept, duplicates answered.
  - `TestCheckLinksSourcesIdempotent`.
  - `TestCheckConfirmOnDisk`: delete the file → `on_disk=false`.
  - `TestCheckNoCrossUserLeak`.
  - `TestSnapshotPagination`: 2,500 assets, limit 1000 → 3 pages, no gaps.
  - `TestChangesAfterSnapshot`: the vector `snapshot_changes_overlap` sequence at service level.
  - `TestCursorExpired`: +91 d, compact, 410.
  - `TestCursorEmptyServerNotExpired`.
  - `TestChangesOneRowPerAsset`.
  - `TestPurgeRequiresTrashed`.
  - `TestPurgeTombstonesAndRemovesFiles`.
  - `TestRestore`.
  - `TestPurgeExpiredAfter30Days`.
  - `TestBackupKeepsSeven`.
  - `TestOriginalOwnerScoped`.
- [ ] **Step 2–4:** FAIL → implement → PASS with `-race`.
- [ ] **Step 5:** `git commit -s -m "feat(server): check, feed, assets, trash and maintenance services"`.

### Task 13: HTTP layer — problems, middleware, strict handlers

**Files:**
- Create: `server/internal/httpapi/{server.go,problem.go,middleware.go,auth_middleware.go,ratelimit.go,mapping.go,handlers_auth.go,handlers_devices.go,handlers_sync.go,handlers_assets.go,handlers_server.go}` and their `_test.go`
- Modify: `server/internal/httpapi/contract_test.go` (keep the existing tests)

**Interfaces (produces):**
```go
package httpapi
type Deps struct{ Users *service.UserService; Auth *service.AuthService; Devices *service.DeviceService; Pairing *service.PairingService
  Check *service.CheckService; Feed *service.FeedService; Assets *service.AssetService; Trash *service.TrashService
  Tus http.Handler; Info func() gen.ServerInfo; Ready func(ctx context.Context) error; Cfg config.Config; Clock clock.Clock; Log *slog.Logger }
func NewHandler(d Deps, local bool) http.Handler // local=true for the loopback listener (setup without token, cookie without Secure)
func WriteProblem(w http.ResponseWriter, r *http.Request, err error)
func PrincipalFrom(ctx context.Context) (service.Principal, bool)
```
Routing:
- `http.ServeMux`. `/api/v1/uploads` and `/api/v1/uploads/{id}` go to `d.Tus`. Everything else goes to `gen.HandlerWithOptions(gen.NewStrictHandlerWithOptions(srv, nil, opts), …)`, with Request/ResponseErrorHandlerFunc mapped to problems.
- Middleware order: request-id (`X-Request-Id` echo or `ids.New()`) → recover → access log (slog) → version gate (S§4.4) → auth (public ops: healthz, readyz, server info, setup, login, refresh, redeem, OPTIONS uploads) → CSRF for cookie + non-GET/HEAD/OPTIONS → rate limit.
- `setupFirstAdmin`: when not `local`, require `CheckSetupToken`, else `Forbidden`.
- Cookies: `pt_session`, Path `/`, HttpOnly, SameSite=Lax, Secure unless `local`.
- `getAssetOriginal`, `getAssetThumbnail` and `getAssetPlayback` bypass the strict wrapper response body: register them as explicit mux routes that use `http.ServeContent`, so `Range`, `If-None-Match`, `ETag`, `Content-Disposition` (`attachment; filename*=UTF-8''<pct-encoded>`) and Cache-Control work. Their strict methods return `Internal()`; a test asserts they are unreachable.
- `mapping.go` converts repository/service views to gen models: `nil` → omitted, UUID parse, `x-known-values` strings.

- [ ] **Step 1:** Failing tests (`httptest` with a test app constructor in `httpapi/httpapitest` that wires the real services on temp dirs and a fake clock; it may import `service` and `repository`):
  - One test per non-tus operation for the 2xx case.
  - Each documented error: `setup_already_done`, `forbidden` (setup token), `unauthorized`, `token_expired`, `refresh_token_reused`, `pairing_code_invalid`, `cursor_required`, `cursor_expired`, `invalid_request` (bad JSON), `not_found`, `not_ready` (thumbnail before job), `client_too_old` (`PicTunnel-Client: android/0.0.1` with min 0.1.0), `rate_limited` (11 logins/min), `internal` (a panicking handler gives a problem body with `request_id` and no stack).
  - `TestRangeOriginal` → 206 with Content-Range.
  - `TestETagNotModified` → 304.
  - `TestCookieCSRFRequired` → 403 without the header.
  - `TestRequestIDEcho`.
- Every response is validated with `openapi3filter.ValidateResponse` against `gen.GetSwagger()` in a shared helper `assertContract(t, req, resp)`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** `git commit -s -m "feat(server): HTTP layer with problem+json, auth and strict handlers"`.

### Task 14: tus handler

**Files:** Create `server/internal/httpapi/tus/{handler.go,handler_test.go}`

**Interfaces (produces):** `func New(up *service.UploadService, auth func(*http.Request) (service.Principal, error), cfg config.Config, log *slog.Logger) http.Handler`. The handler writes problems through an injected `func(w, r, err)` (pass `httpapi.WriteProblem`) to avoid an import cycle.

Header behavior is exact per P§7.3 and S§6.1:
- Every response carries `Tus-Resumable: 1.0.0`.
- `OPTIONS` → 204 with the `Tus-Version`, `Tus-Extension`, `Tus-Max-Size` and `Tus-Checksum-Algorithm` headers.
- `POST` requires `Upload-Length`. A body is accepted only with `Content-Type: application/offset+octet-stream`. The response is `201` with `Location`, `Upload-Expires` (RFC 7231 date), `Upload-Offset` when it is non-zero or the upload is done, and `PicTunnel-Asset-Id` / `PicTunnel-Asset-Created` when done.
- `HEAD` → 200 with `Upload-Offset`, `Upload-Length`, `Upload-Expires`, `Cache-Control: no-store`, plus the asset id when done.
- `PATCH` requires the content type and `Upload-Offset` → 204 with `Upload-Offset` (+ asset headers when done).
- `DELETE` → 204.
- Idle body timeout of 60 s: wrap the body in a reader that uses `http.ResponseController.SetReadDeadline` and extends it per read.
- If the client went away, the handler writes nothing more.

- [ ] **Step 1:** Failing tests:
  - Each header case above.
  - Missing `Tus-Resumable` → 412 + `Tus-Version`.
  - Wrong content type → `400 invalid_request` (415 is not in the catalogue).
  - `TestDropMidPatchRealConn`: a raw TCP client sends headers and 1,000,000 of 1,048,576 bytes, then closes; `HEAD` → 1000000; `PATCH` the rest → 204 with the asset id.
  - `TestUploadChecksumHeader` mismatch → 460.
  - `TestOptionsNoAuth`.
- [ ] **Step 2–4:** FAIL → implement → PASS (`-race`).
- [ ] **Step 5:** `git commit -s -m "feat(server): tus 1.0 upload handler"`.

### Task 15: Discovery, app wiring, `serve` command, conformance runner

**Files:**
- Create: `server/internal/discovery/{discovery.go,discovery_test.go}`, `server/internal/app/{app.go,boot.go,app_test.go}`
- Modify: `server/cmd/pictunnel/main.go`, `main_test.go`
- Create: `server/internal/conformance/{scenario.go,matchers.go,scenario_test.go}`

**Interfaces (produces):**
```go
package discovery
type Responder interface{ Start(ctx context.Context) error; Stop() }
func New(name string, port int, txt map[string]string, log *slog.Logger) Responder // brutella/dnssd; verify module license (MIT/BSD/Apache) & Windows build; else hashicorp/mdns. Bind failure → warn, nil error

package app
type Options struct{ Config config.Config; Clock clock.Clock; Failpoints service.Failpoints; FreeSpace storage.FreeSpaceFunc; FS storage.FS; Log *slog.Logger; DisableScheduler bool }
type App struct{ /* exported accessors below */ }
func New(ctx context.Context, o Options) (*App, error) // boot S§10.1 steps 1–6 (lock file, quick_check, backup+migrate, secret/server_id/TLS, recovery)
func (a *App) Handler() http.Handler; func (a *App) LocalHandler() http.Handler; func (a *App) TLSConfig() *tls.Config
func (a *App) Users() *service.UserService; func (a *App) Jobs() *jobs.Runner; func (a *App) Store() *store.Store; func (a *App) Fingerprint() string
func (a *App) Run(ctx context.Context) error // start jobs (+media pool), listeners, mDNS; block until ctx done; graceful 30s shutdown
func (a *App) Close() error
```
CLI:
- `pictunnel serve [flags]`.
- `pictunnel version`.
- `pictunnel reset-password <user>`.
- On first boot, `serve` prints the setup token and the local setup URL.

Server info:
- `name` comes from config.
- `capabilities`: `["tus"]` (the known values have no thumbnails entry).
- Upload limits come from config.

Conformance runner (P§10.4, S§11.2):
- Load every `vectors/server-scenarios/*.json` and run each case as a `t.Run` subtest on a fresh App with a fake clock, scheduler disabled, `FreeSpace` returning 1 TiB, and `httptest.NewUnstartedServer(app.Handler())` with `TLS = app.TLSConfig()` + `StartTLS`. The client trusts the CA.
- Users are created with `app.Users().Create`.
- Actors: a login via `/auth/login` (tokens) gives the runner device; then `/pairing/codes` and `/pairing/redeem` with the actor's platform.
- Implement every matcher and control step.
- Validate every response with `openapi3filter`.
- After each case, check the S§11.2 invariants.

- [ ] **Step 1:** Failing tests:
  - `TestAppBootTwiceSameServerIDAndFingerprint`.
  - `TestSecondInstanceLocked`.
  - `TestBootRecoversFinalizing`: seed a finalizing session, then `New` runs recovery.
  - `TestServeVersionCLI`.
  - `TestDiscoveryTXT`: TXT map contents; responder start/stop with no error even when bind fails.
  - `TestScenarios`: all 17 cases.
- [ ] **Step 2–4:** FAIL → implement → `go test -race ./...` PASS. Manually smoke-test: `go run ./cmd/pictunnel serve --data-dir <tmp>`, then `curl -k https://127.0.0.1:8443/api/v1/server/info`.
- [ ] **Step 5:** `git commit -s -m "feat(server): app wiring, serve command, mDNS and conformance runner"`.

### Task 16: Crash matrix

**Files:** Create `server/internal/app/crash_test.go` and `server/internal/app/crashhelper_test.go` (`TestMain` re-exec mode controlled by env `PICTUNNEL_CRASH_CHILD`, test-binary only).

- [ ] **Step 1:** Write the tests:
  - **In-process:** `TestCrashMatrix`: for each `{sameVolume, crossVolume (FaultFS EXDEV)} × {before_tx1, after_tx1, after_copy, after_rename, after_tx2, append_after_fsync, append_before_commit}`:
    1. Failpoints return `errCrash` at the named point. Abort the upload (the handler returns 500 or the connection is dropped).
    2. Close the app (no cleanup), then `New` on the same dirs.
    3. Run the client convergence loop: check → HEAD/POST → PATCH remaining.
    4. Assert exactly one asset with the correct bytes, no staging, no `.ptpart`, no unowned reservation, and the `asset_sources` link present.
    5. Run recovery twice and assert it is idempotent.
  - **Process kill:** `TestCrashProcessKill` (skipped with `-short`): the child serves on a random port and Failpoints call `os.Exit(137)`. The parent uploads A, waits for the child to exit, starts a new child, converges and asserts. Do this for `after_rename` and `append_before_commit`.
- [ ] **Step 2:** Run `go test -race ./internal/app -run Crash -v`. Expect PASS. Fix any real bug in the services (a crash test failure is a product bug, not a test bug).
- [ ] **Step 3:** `git commit -s -m "test(server): crash recovery matrix with process kill"`.

### Task 17: Property, chaos, contract coverage and fuzz

**Files:** Create `server/internal/app/property_test.go`, `server/internal/httpapi/coverage_test.go`, and fuzz targets in their packages: `DecodeCursor`, page token, Range via `http.ServeContent` (skip; stdlib), Crockford code parse.

- [ ] **Step 1:** `TestPropertySync` uses rapid with 1–3 users and 1–4 devices each, payloads from A/B/C/V plus random 1 B–200 KiB. Operations:
  - create (with or without body)
  - PATCH chunk
  - drop mid-PATCH
  - duplicate request
  - concurrent PATCH pair
  - HEAD
  - terminate
  - check
  - trash, restore, purge
  - tombstone delete
  - `advance clock`
  - `RunNow` of each periodic job

  Invariants 1–7 of S§11.5 are checked after every step. The default check count comes from `-rapid.checks` (500 in CI via the flag; the default 100 locally).
- [ ] **Step 2:** `TestContractCoverage`: a recording middleware in `httpapitest` collects the `(operationId, status)` pairs seen across `go test ./...` of the `httpapi` package. It is implemented as a package-level recorder that the test suite's `TestMain` checks after `m.Run()`. Every documented status 2A/2B can produce must be hit. Maintain an explicit exclusion list with reasons, e.g. 507 is only produced through the fake free space.
- [ ] **Step 3:** Run `go test -race ./...` → PASS; `go test ./internal/app -run Property -rapid.checks=2000` → PASS.
- [ ] **Step 4:** `git commit -s -m "test(server): property/chaos invariants, contract coverage and fuzz targets"`.

### Task 18: Media pipeline jobs (2B)

**Files:**
- Create: `server/internal/media/{ffmpeg.go,thumbs.go,metadata.go,playable.go}` and tests
- Create: `server/internal/service/media_service.go` and its test; wire into `app` (register `extract_metadata`, `generate_thumbnails`, `transcode_video` on the media pool)
- Create: `server/internal/media/testdata/`: commit tiny fixtures (≤ 50 KB each): `exif_rot6.jpg` (EXIF orientation 6, GPS 38.7223/-9.1393), `plain.png`, `anim.gif`, `small.webp`, `clip_h264.mp4` (1 s, 64×48, aac), `clip_hevc.mov` (1 s hevc, generated with ffmpeg `-c:v libx265`), `still.heic` if ffmpeg can produce it (else skip HEIC with `t.Skip` when the encoder is unavailable), `corrupt.jpg` (random bytes).

**Interfaces (produces):**
```go
package media
type Tools struct{ FFmpeg, FFprobe string } // resolved paths or ""
func FindTools(cfg config.Config) Tools
type Probe struct{ Width, Height int; DurationMS *int64; VideoCodec, AudioCodec, Container string; Rotation int; CreationTime *time.Time }
func FFprobe(ctx context.Context, t Tools, path string) (Probe, error)
type ImageMeta struct{ Width, Height int; Lat, Lon *float64; Taken *probe.DateResult; Orientation int }
func ReadImageMeta(path string) (ImageMeta, error)
func Playable(p Probe) bool // 2B design rule
func MakeThumbnails(ctx context.Context, t Tools, src, mime string, isVideo bool, outDir string) error // thumb.jpg + preview.jpg, tmp+rename
func Transcode(ctx context.Context, t Tools, src, dst string) error
var ErrToolMissing = errors.New("ffmpeg unavailable")

package service
type MediaService struct{ /* Store, Assets, LiveVideos, ChangeLog, Jobs runner, Tools, Clock, DataDir, LibraryDir */ }
func (s *MediaService) ExtractMetadata(ctx context.Context, payload []byte) error
func (s *MediaService) GenerateThumbnails(ctx context.Context, payload []byte) error
func (s *MediaService) TranscodeVideo(ctx context.Context, payload []byte) error
```
Handlers treat an asset that no longer exists (purged) as success. A corrupt input returns a normal error, and `max_attempts` (3 for media kinds) bounds the retries.

- [ ] **Step 1:** Failing tests. Tests needing ffmpeg skip when `FindTools` finds none; CI installs it.
  - `TestReadImageMetaRotGPS`: width and height swapped for orientation 6, lat/lon within 1e-4.
  - `TestThumbnailsJPEGOriented`: `thumb.jpg` long side 320 and portrait.
  - `TestThumbnailsPNGNoUpscale` (a 64×48 source stays 64×48).
  - `TestThumbnailsVideo`.
  - `TestPlayable` table.
  - `TestExtractMetadataUpdatesAssetAndFeed`: the change feed shows the new width.
  - `TestTranscodeHEVCProducesPlayable`.
  - `TestThumbnailJobCorruptInput` → `dead` after 3 attempts; the asset is still served.
  - `TestThumbnailJobNoFFmpeg`: tools are empty and a HEIC input fails retryably with `ErrToolMissing`.
  - `TestPlaybackRules` through HTTP: mp4 original, mov hevc → `not_ready`, then `web.mp4` after the job, photo → `not_found`.
  - `TestThumbnailEndpointAfterJob`: ETag and immutable cache headers.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** `git commit -s -m "feat(server): media pipeline — metadata, thumbnails, transcode"`.

### Task 19: Interop test, CI and docs

**Files:**
- Create: `server/test/interop/tus-js/{package.json,pnpm-lock.yaml,upload.mjs,README.md}`
- Modify: `.github/workflows/ci-server.yml`; create `.github/workflows/nightly-server.yml`
- Modify: `Taskfile.yml` (`test:server:race`, `test:interop`, `gen:sqlc`, `check:sqlc`)
- Create: `server/.golangci.yml` with the depguard rules of S§2.1
- Create: `docs/server/running.md` (serve, first-run setup token, TLS fingerprint, mDNS caveats from S§5.3, ffmpeg requirement)

Steps:
- [ ] **Step 1:** `upload.mjs` (tus-js-client pinned at exact version, Node 24):
  1. Spawn `go run ./cmd/pictunnel serve` with a temp `--data-dir` and random ports (`--server.https-addr 127.0.0.1:0` is not printable, so use fixed ports 18443/18080 passed by flag).
  2. Read the setup token from stdout, set up the admin over HTTP loopback, log in, and get a bearer token.
  3. `NODE_EXTRA_CA_CERTS=<data>/tls/ca.crt`.
  4. Upload payload C with `chunkSize: 1048576`, metadata sha256/filename/mime; abort after the second `onChunkComplete`.
  5. Create a new Upload with `findPreviousUploads` + `resumeFromPreviousUpload`, then finish.
  6. `POST /sync/check` → `exists`. Exit 0.
- [ ] **Step 2:** `ci-server.yml`:
  - The test job becomes an OS matrix `[ubuntu-latest, windows-latest, macos-latest]` running `go test -race ./...`.
  - Ubuntu installs ffmpeg (`sudo apt-get install -y ffmpeg`) and macOS uses `brew install ffmpeg`; Windows skips the media tests through tool detection.
  - Ubuntu also runs:
    - lint;
    - the coverage gate: `go test -coverprofile` over `./internal/service/... ./internal/repository/... ./internal/httpapi/...`, then a Go one-liner script `tools/ci/covergate.go` failing below 85%;
    - fuzz smoke, 20 s per target;
    - `go tool sqlc diff`;
    - oapi-codegen drift;
    - the interop job (pnpm install + `node upload.mjs`).
  - Nightly: `-rapid.checks=20000` and fuzz 5 min per target.
- [ ] **Step 3:** Run locally: `go vet ./... && go test -race ./...` (Windows), `node server/test/interop/tus-js/upload.mjs` → PASS.
- [ ] **Step 4:** `git commit -s -m "ci(server): OS matrix, coverage gate, fuzz, interop; docs"`.
