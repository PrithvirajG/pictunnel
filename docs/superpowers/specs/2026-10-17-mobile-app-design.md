# PicTunnel — Sub-project 3: Mobile App and Backup Engines (3A Android + 3B iOS)

- Status: Draft for review · Date: 2026-10-17
- Parent: [System design](2026-10-03-pictunnel-system-design.md) §7, sub-project 3
- Contract: [`api/openapi.yaml`](../../../api/openapi.yaml), [`api/protocol/sync-protocol.md`](../../../api/protocol/sync-protocol.md) (cited as `P§n`; normative, not restated here). Server: [2A spec](2026-10-12-server-sync-core-design.md).
- Visual design: canvas https://claude.ai/artifact/6JG7i78NP1JSxJuwG7TKBx, direction **A · Darkroom** (chosen 2026-10-17).

## 1. Intent and scope

**Goal.** A phone app that backs up every photo and video to the user's PicTunnel server reliably and without duplicates, even in the background. It also lets the user browse, view and download the whole library, and free up phone space safely. Android and iOS ship from one Flutter UI. Each platform has its own native backup engine.

**Decisions taken in brainstorming.** These are fixed inputs for this spec:

| Topic | Decision |
|---|---|
| Visual direction | A · Darkroom (near-black ground, amber accent, Bricolage Grotesque + Figtree) |
| Photos tab | **Unified timeline**: phone + server merged by SHA-256, with per-item presence badges |
| Data ownership | Each side owns its store. The engine owns queue, hash cache and phone index (native SQLite). Flutter owns the server mirror and the timeline cache (Drift). |
| Delivery | 3A (Flutter + Android engine) and 3B (iOS engine) are built together in one plan |
| Navigation | Three tabs: Photos, Backup, Settings. Albums and search arrive with sub-project 5. |

**In scope.**
- The Flutter app: pairing, backup status, unified timeline, viewer (photo, video, Live Photo), download, trash and restore, free up space, settings, needs-attention list and activity log.
- The Android engine in Kotlin (MediaStore, WorkManager, Room, OkHttp).
- The iOS engine in Swift (PhotoKit, background `URLSession`, BGTaskScheduler, GRDB).
- The Pigeon bridge between them.
- Tests and CI for all three.

**Out of scope.**
- Albums, sharing, search and place names (sub-project 5), and the web viewer (sub-project 4).
- Store publishing, signing and release builds (sub-project 7).
- iOS on-device testing. iOS is built and tested on CI macOS runners only, and the decision point is v0.9 (locked decision).

**Exit criteria.** All must hold in CI:
1. **Engine decision functions.** Kotlin and Swift implementations pass every `backup`, `auth` and `free_up_space` client-decision vector. The Dart implementation passes every `browse`, `pairing`, `setup` and `auth` vector. Together that is all 51 cases. Hashing and pairing vectors pass in Kotlin, Swift and Dart.
2. **Engine integration against the real server.** On JVM (Kotlin) and macOS (Swift), the engine's upload path runs against a real `pictunnel serve`. It covers fresh upload, drop mid-PATCH then resume, the duplicate short-circuit, a tombstone, and refresh-token rotation. The server ends with exactly one asset per hash.
3. **Android instrumented tests.** On the emulator in CI, these cover the MediaStore scan, WorkManager scheduling, the Keystore credentials round trip, and the free-up-space delete request (with UI automation confirming the system dialog).
4. **Flutter tests.** Widget tests cover every screen state. Golden tests cover the Darkroom screens at 390×844. Timeline-merge property tests run against a fake engine and a fake server.
5. **Build and lint.** `flutter analyze`, ktlint/detekt, SwiftLint and existing codegen drift are clean. The debug APK and the iOS no-codesign build succeed.

## 2. Architecture

```mermaid
flowchart TB
  subgraph Flutter["Flutter UI (Dart)"]
    UI[screens · Riverpod] --> Repo[repositories]
    Repo --> Drift[(Drift: server mirror,\ntimeline cache, thumb index)]
    Repo --> Api[pictunnel_api client\nbrowse + account calls]
    Repo --> Bridge[Pigeon: EngineHostApi]
    Events[Pigeon: EngineEventsApi] --> Repo
  end
  subgraph Native["Native engine (Kotlin / Swift)"]
    Host[EngineHost] --> Ctrl[EngineController]
    Ctrl --> Store[(Engine DB: items, hash cache,\nphone index, activity, settings)]
    Ctrl --> Scan[Scanner\nMediaStore / PhotoKit]
    Ctrl --> Hash[Hasher]
    Ctrl --> Net[ServerClient: check, tus, refresh\npinning, endpoint selection]
    Ctrl --> Dec[decide(): pure decision function]
    Ctrl --> Sched[Scheduler\nWorkManager / BGTask + bg URLSession]
    Ctrl --> Cred[Credentials\nKeystore / Keychain]
  end
  Bridge --> Host
  Ctrl --> Events
  Net --> Server[(pictunnel server)]
  Api --> Server
```

**Who talks to the server.**
- **Engine:** everything in the backup pipeline. That is `/sync/check`, the tus upload operations, `/auth/refresh`, `/server/info`, `DELETE /tombstones/{sha}`, and the free-up-space confirmation check. These are the engine operation subset from M0.
- **Flutter:** browse and account calls only. That is snapshot and changes, assets, thumbnail, original, playback, trash, restore, purge, tombstones, devices, pairing redeem and login.
- **Tokens.** Flutter gets its access token from the engine (`getAccessToken`), so token rotation has exactly one owner. The engine single-flights `/auth/refresh` (P§6.2, R11).

### 2.1 Repository layout

```
mobile/
  lib/
    app/            app.dart, router.dart, theme/ (Darkroom tokens, typography)
    core/           api/ (pictunnel_api wiring, auth interceptor), engine/ (Pigeon wrappers),
                    db/ (Drift schema + DAOs), decisions/ (Dart decide() for browse/pairing/setup/auth)
    features/       pairing/ backup/ timeline/ viewer/ settings/ attention/ activity/
  pigeons/engine.dart             Pigeon definitions (source of generated Dart/Kotlin/Swift)
  test/                           widget, golden, unit, vectors
  integration_test/               Flutter integration (fake engine)
  android/
    engine/                       NEW Gradle module io.github.prithvirajg.pictunnel.engine
      src/main/kotlin/.../engine/ {controller, decide, store, scan, hash, net, sched, cred, freeup}
      src/test/ (JVM unit + vectors + server integration)
      src/androidTest/ (instrumented)
    engine-api/                   (exists) generated OpenAPI client: used by engine/net
    app/                          Flutter host; registers EngineHost and WorkManager
  ios/
    Engine/                       NEW Swift package PicTunnelEngine
      Sources/PicTunnelEngine/ {Controller, Decide, Store, Scan, Hash, Net, Sched, Cred, FreeUp}
      Tests/ (unit + vectors + server integration)
    EngineAPI/                    (exists) generated client + ContentHash.swift
    Runner/                       Flutter host; registers EngineHost, BGTask identifiers
```

**Layering inside each engine:**
- `Store` (one DAO per table) is used by `Controller` services.
- `decide()` is a pure function, `(given, serverOutcome) → (nextState, action, attemptsDelta)`. It has no I/O and is mirrored 1:1 from the vectors.
- `Net` wraps the generated client plus a hand-written tus client.
- Platform APIs live in `Scan`, `Sched`, `Cred` and `FreeUp`, behind interfaces so tests can fake them.

## 3. Bridge (Pigeon)

The source is `mobile/pigeons/engine.dart`. Generated code is committed and drift-checked like the other codegen.

**Host API, Flutter → engine (`EngineHostApi`, all async):**

| Method | Purpose |
|---|---|
| `pair(PairRequest{qrUri?, serverUrl?, code, deviceName}) → PairResult` | Validate the URI (P§10.3), connect with pinning (P§6.3), redeem, store credentials and endpoints |
| `trustOnFirstUse(String serverUrl) → ServerIdentity{serverId, name, fp16, fpFull}` | Manual setup: fetch the certificate fingerprint for the user to compare |
| `unpair()` | Revoke locally (best-effort `logout`), wipe credentials and engine DB |
| `getAccessToken() → String` | Current access token, refreshing first if it expires within 60 s |
| `serverInfo() → ServerConnection{serverId, name, activeEndpoint, onLan, fp16}` | — |
| `start()` / `pause(PauseReason)` / `runNow()` | Control backup |
| `getStatus() → BackupStatus{backedUp, total, queued, uploading?, needsAttention, skipped, freeableBytes, paused?, pauseReason?, lastRunAt}` | Snapshot for the Backup screen |
| `getSettings() / setSettings(EngineSettings{wifiOnly, chargingOnly, includeVideos, keepUneditedOriginals, albumsMode: all\|selected, albumIds})` | — |
| `listPhoneItems(PageRequest{afterKey?, limit}) → PhoneItemPage{items: [PhoneItem{localId, sha256?, takenAt, mime, size, width?, height?, durationMs?, state, assetId?}], nextKey?}` | The phone index for the unified timeline, keyset-paged by (takenAt desc, localId) |
| `phoneThumbnail(localId, sizePx) → Uint8List` | Local thumbnail (MediaStore `loadThumbnail` / PHImageManager) |
| `listAttention() → [AttentionItem]` / `retry(localIds)` | Needs-attention list |
| `listActivity(limit) → [ActivityEntry{at, kind, message, localId?}]` | Activity log, a ring buffer of 1000 entries |
| `freeUpSpace(localIds?) → FreeUpResult{freedCount, freedBytes, skipped: [{localId, reason}]}` | P§7.8. Null means all eligible items |
| `undoSkip(sha256)` | "Back up again" for a tombstoned item: `DELETE /tombstones/{sha}`, then requeue |
| `saveToGallery(assetId, filename, mime) → String localId` | Download an original into the phone gallery (engine owns gallery writes) |

**Flutter API, engine → Flutter (`EngineEventsApi`):** `onStatus(BackupStatus)`, `onItemChanged(PhoneItem)`, `onNeedsRepair()`. The last one fires on refresh-token reuse or revocation and sends the UI to pairing. Events are throttled to at most 4 per second.

## 4. Engine behavior (shared by Kotlin and Swift)

### 4.1 Item state machine
- States are exactly the vector `item_state` enum: `Discovered, Hashed, Queued, Uploading, Verifying, BackedUp, Skipped, Freed, NeedsAttention, Paused`.
- Transitions are driven only by `decide()`. Every row change is persisted **before** the network call it governs (R1).
- Each item row holds:
  - `localId`, `sha256?`, `size`, `modifiedAt`, `mime`, `kind` (photo/video/live_photo)
  - `pairRole`, `pairLocalId?`, `stackKey?`
  - `state`, `attempts`, `nextAttemptAt?`
  - `uploadId?`, `uploadUrl?`, `uploadOffset?`
  - `assetId?`, `lastError?`

### 4.2 Pipeline
1. **Scan (incremental).**
   - Android: `MediaStore.getGeneration()` since the last stored generation; a full rescan when the volume version changes.
   - iOS: `PHPersistentChangeToken`; a full rescan if the token expires.
   - Respects the album selection and the include-videos setting. New and changed items become `Discovered`. Items deleted from the phone are dropped from the index only. The server is never told (one-way backup, R8).
2. **Hash.**
   - The hash cache is keyed by `(localId, modifiedAt, size)`, per R3.
   - Hashing is streaming SHA-256 using platform crypto (`MessageDigest`, `CryptoKit`).
   - On iOS the input is the current-rendition resource (H3). A Live Photo produces two hashes: still and paired video (H4).
3. **Check.** Batches of up to 1000 go to `POST /sync/check` with `local_id`. The verdict maps through `decide()`:
   - `exists` → `BackedUp` (with `assetId`)
   - `missing` → `Queued`
   - `partial` → `Uploading` (keeping the server's session and offset)
   - `tombstoned` → `Skipped`
4. **Upload (tus profile, P§7.3).** Every request sends `PicTunnel-Client: <platform>/<version>`.
   - **Profile:**
     - Android: single-shot creation-with-upload up to `recommended_chunk_bytes` (8 MiB), otherwise create then 8 MiB PATCH chunks.
     - iOS: single-shot from file up to 64 MiB, otherwise 64 MiB chunk files, each sent as a background `uploadTask(with:fromFile:)`.
   - **Metadata:** `sha256, filename, mime, local_id, created_at, modified_at`, plus `pair_role`/`pair_sha256` for Live Photo videos (primary first, per H4) and `stack_key` for "also keep unedited originals" on iOS (H3).
   - **Upload concurrency:** 2 by default, 4 at most (R6).
5. **Confirm.** An item becomes `BackedUp` only with a server `asset_id` (R4).

### 4.3 Retry, attempts, ambiguity
- **Retry and backoff.** `decide()` encodes R2, R5 and R7. Backoff starts at 2 s, doubles each time, caps at 15 min, and uses full jitter. An item gets 10 retryable failures before `NeedsAttention`. `offline` never counts as an attempt. `Retry-After` is honored.
- **Ambiguity.** A timeout or reset with a known upload id leads to `HEAD`. Without one, it leads to `check`. The engine never assumes success.
- **Pausing.** `Paused` applies to the whole run for `insufficient_storage` and `quota_exceeded` (with a notification) and for `client_too_old` (prompting an update).

### 4.4 Auth, endpoints, pinning
- **Credentials.** The refresh token, the TLS pin (full SPKI SHA-256), the endpoint list (LAN first, then remote) and the server id are stored in Keystore-encrypted storage (Android) or the Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (iOS).
- **Refresh.** One refresh at a time, shared by the engine and `getAccessToken`. Concurrent refreshes from both platforms' processes rely on the server's 30 s grace window (P§6.2).
  - `refresh_token_reused` or a revoked device → wipe credentials and fire `onNeedsRepair`.
  - Network failure → keep the tokens and retry later.
- **Endpoints and pinning.** Try endpoints in stored order (R9), with a short connect timeout for LAN (3 s).
  - **Pinning rule (P§6.3):** a chain the system trusts that matches the host is accepted. Otherwise the leaf's SPKI SHA-256 must equal the stored pin.
  - **Android:** a custom `X509TrustManager` plus `HostnameVerifier` on OkHttp.
  - **iOS:** `URLSessionDelegate` `urlSession(_:didReceive:completionHandler:)` evaluating `SecTrust` and comparing the SPKI hash.
- **LAN discovery for manual setup.** mDNS `_pictunnel._tcp`: `NsdManager` on Android, `NWBrowser` on iOS (the `NSLocalNetworkUsageDescription` and `NSBonjourServices` plist keys).

### 4.5 Free up space (P§7.8)
1. **Candidates.** Items in `BackedUp` whose local file fingerprint `(modifiedAt, size)` still matches the hashed one.
2. **Re-check, immediately before deleting.** `POST /sync/check` with `confirm_on_disk=true` for exactly those hashes. An item stays a candidate only if the server answers `exists`, `asset_state=active` and `on_disk=true`. For a Live Photo, both components must pass.
3. **Delete with system confirmation.**
   - Android: `MediaStore.createDeleteRequest` (API 30+) or a `RecoverableSecurityException` flow (API 29).
   - iOS: `PHAssetChangeRequest.deleteAssets`.
   - The OS dialog is always shown.
4. **Record.** Confirmed deletes become `Freed`. Items the user cancels stay `BackedUp`. Items dropped by the re-check are reported in `skipped` with a reason.

### 4.6 Notifications and permissions
- **Android permissions:**
  - `READ_MEDIA_IMAGES` and `READ_MEDIA_VIDEO` (API 33+), `READ_EXTERNAL_STORAGE` on API 29–32, and `ACCESS_MEDIA_LOCATION` for EXIF GPS.
  - API 34+ partial media access: back up only what is granted, with a banner offering full access.
  - `POST_NOTIFICATIONS`.
- **Android background work:**
  - A foreground `dataSync` service while uploading. On API 34+, user-initiated data transfer jobs when the user taps "Back up now".
  - Its notification shows the remaining count and bytes, with Pause.
- **iOS permissions and background work:**
  - PhotoKit read/write authorization. With limited access, only selected items are backed up, and there is an "Allow full access" entry point.
  - Background `URLSession` (`sessionSendsLaunchEvents`).
  - `BGAppRefreshTask` for scan and check, `BGProcessingTask` (requires power when charging-only is on) for hashing large videos, and `BGContinuedProcessingTask` on iOS 26 for user-started backups.
  - Local notification when backup pauses for storage or quota.

## 5. Android engine specifics (3A)
- **Module.** `:engine` (Android library, minSdk 29, targetSdk 36).
- **Libraries.** Room, WorkManager, OkHttp 5, kotlinx-serialization, the existing generated `engine-api` client, Tink/Keystore (`EncryptedSharedPreferences` successor via Keystore-wrapped AES-GCM).
- **Workers.**
  - `ScanWorker`, triggered by a content-URI observer on `MediaStore.Images/Video` (`setTriggerContentUris`) plus a 6 h periodic job.
  - `SyncWorker`, which runs hash, check and upload. It is unique work with `ExistingWorkPolicy.KEEP`, so only one pipeline runs at a time. Its constraints follow the settings: network type (unmetered when Wi-Fi only) and charging.
  - Uploads run in the foreground service while the queue is non-empty.
- **Upload I/O.** It streams from `ContentResolver.openInputStream`. For PATCH chunks it uses a bounded `Source` that seeks to the offset. Files that cannot seek (rare providers) are copied to a cache file first.
- **Motion photos.** Android motion photos with an embedded video are a single file, so no pairing is needed (H4).

## 6. iOS engine specifics (3B)
- **Package.** `PicTunnelEngine` Swift package (iOS 16+), embedded in Runner.
- **Libraries.** GRDB.swift for SQLite, CryptoKit, and the existing `EngineAPI` generated client for JSON calls.
- **Uploads use `URLSession` directly.** Background tasks need file-based bodies and delegate callbacks, so tus calls are built by hand.
- **Resource export.** `PHAssetResourceManager.writeData(for:toFile:)` writes each resource to `Application Support/staging/<localId>-<role>`. Hashing happens while exporting, so the file is read once.
  - Single-shot uploads send the file as is.
  - Chunked uploads cut 64 MiB slices into separate files. The slice for the next chunk is created only after the previous chunk is accepted.
  - Staging files are deleted when the item is `BackedUp` or `NeedsAttention`, and swept at launch.
- **Background session.**
  - Identifier `io.github.prithvirajg.pictunnel.upload`.
  - Each task carries `taskDescription = "<itemId>|<uploadId>|<offset>"`, so relaunch handling can map completions back to item rows.
  - `application(_:handleEventsForBackgroundURLSession:)` is forwarded to the engine from AppDelegate.
- **Edits and Live Photos.**
  - Current rendition: `fullSizePhoto`/`fullSizeVideo` if present, else `photo`/`video` (H3).
  - With "also keep unedited originals" on, the `photo`/`video` original is uploaded as a second asset with the same `stack_key = localIdentifier`.
  - Live Photos follow H4. The primary is uploaded first. A `has_live_video=false` on check triggers the component upload.
- **No device available.** Platform services sit behind protocols (`PhotoLibrary`, `BackgroundUploader`, `Keychain`). Tests use fakes on the macOS runner. The `swift test` server integration test runs a real `pictunnel serve` on macOS.

## 7. Flutter app

### 7.1 State and data
- **State management.** Riverpod (code-gen providers) and go_router. The shell route hosts three tabs plus detail routes: `/photos/:id`, `/backup/attention`, `/backup/activity`, `/pair`.
- **Drift DB `app.db`:**
  - `server_assets`: the asset mirror, every field of P§4.1 plus `live_video` JSON.
  - `sync_state` (`cursor`, `snapshot_done`).
  - `thumb_cache` (`assetId`, `size`, `path`, `bytes`, `lastUsedAt`), with an LRU budget of 512 MiB on disk (configurable).
- **Mirror sync.** First run: a paged snapshot, then `changes` from its cursor (P§7.6). `410` → reset and re-snapshot. Upserts are applied only when `updated_seq` is newer (P§7.6). Syncs run on app foreground, on pull-to-refresh, and every 60 s while the Photos tab is visible.
- **Unified timeline.** A merge, keyed by sha256, of `server_assets` (state `active`) and the engine phone index (`listPhoneItems`, cached in an in-memory map rebuilt on `onItemChanged`).
  - **Presence:** `both` (sha matches), `serverOnly`, `phoneOnly` (not yet hashed, or hashed and not on the server).
  - **Ordering:** by `taken_at`, falling back to `created_at`, newest first. Month sections show local-time month and year. A section of the current week is labeled "This week".
  - **Badges:** amber up-arrow for queued or uploading, cloud for `serverOnly`, a small dot for `NeedsAttention`, the duration for videos, "LIVE" for Live Photos.
  - **Thumbnails:** `phoneOnly` and `both` use the local thumbnail (no network). `serverOnly` uses the server `thumb` size, cached. A `404 not_ready` shows a tonal placeholder and retries later (`browse` vectors).
- **Trash.** A Trash view under Settings lists trashed server assets, with Restore, Delete forever (purge) and Empty trash. The trash and purge buttons on the viewer act only on the server copy, and the copy says so.

### 7.2 Screens (Darkroom, per canvas)
| Screen | Contents |
|---|---|
| Pair | QR scanner (`mobile_scanner`), the "Server found" card (name, LAN status, URL, security code), "Connect and start backup", and an "Enter a server address instead" fallback (mDNS suggestions, URL field, then a fingerprint comparison with `fp16`) |
| Backup | Server chip (name, LAN or remote), progress ring with backed-up count, remaining count and ETA, current upload card, "Up next" queue, rule chips, entries to "Needs attention (n)" and "Activity", and a banner for pause reasons and partial media access |
| Photos | Unified timeline grid (3 columns; pinch switches to 5), month headers, presence badges, filter "Not on this phone", multi-select (download, trash, free up space) |
| Viewer | Pinch-zoom photo (server `preview` then the original on zoom), video playback (`playback` endpoint, range streaming), Live Photo press-to-play, info panel (date and offset, file, size, coordinates, presence), actions: Share, Original (save to gallery), Free up, Trash |
| Settings | Backup toggles (mobile data, charging only, include videos, unedited originals on iOS only, album selection), phone storage "Free up N GB", Server (name, connection, this device, Pair again, Unpair), Trash, About (versions, server version, licenses) |
| Needs attention | Items with their reason (from the problem code), Retry, "Back up again" for skipped (tombstoned) items |
| Activity | The engine's activity log, newest first |

**Theme tokens (exact).**
- Colors: ground `#111111`, surface `#1C1C1C`, line `#2A2A2A`, text `#F2EFEA`, muted `#A8A39B`, accent `#F0A63A`, ok `#5BC88A`.
- Type: Bricolage Grotesque (display), Figtree (body). Both are bundled as assets with OFL licenses; no runtime font fetching.
- Accessibility: touch targets ≥ 48 dp, text contrast ≥ 4.5:1, Dynamic Type and font scaling supported up to 200%.

### 7.3 Dart decisions
`core/decisions/decide.dart` implements the `browse`, `pairing`, `setup` and `auth` client-decision flows (thumbnail retries, changes 410 → snapshot, pairing errors, refresh outcomes as seen by the UI). It is tested against those vectors.

## 8. Error handling summary
- Every problem code (P§8) maps through `decide()` to one of the vector actions. Unknown codes follow R7.
- User-facing copy lives in one table per platform, keyed by problem code (e.g. `insufficient_storage` → "Your server is out of space. Backup is paused.").
- The engine never crashes the app on a server error. Each failure is recorded in the activity log, and the item's `lastError` holds the code.

## 9. Testing and CI
| Layer | Android | iOS | Flutter |
|---|---|---|---|
| Vectors | JUnit over `api/protocol/vectors` (hashing, pairing, client-decision subsets) | XCTest over the same files | `flutter test` over the browse/pairing/setup/auth subsets + hashing |
| Unit | Store DAOs (Room in-memory), decide, tus client, pinning, scheduler policy | GRDB in-memory, decide, tus request building, pinning, chunk slicing | providers, merge logic (property tests with `glados`), formatters |
| Integration | JVM test starts `pictunnel serve` (built in CI) and runs the engine `Net`+`Controller` with a fake scanner: upload, drop/resume, duplicate, tombstone, refresh rotation | `swift test` on macOS with the same scenarios against `pictunnel serve` built for darwin/arm64 | integration_test with a fake engine + a real server mirror |
| Device | Instrumented on emulator (API 34): scan, WorkManager, Keystore, delete request via UI Automator | — (no device; recorded as a v0.9 risk) | golden screenshots (Linux runner, bundled fonts) |

**CI changes in `ci-mobile`:**
- New jobs `engine-android-unit`, `engine-android-instrumented` (reactivecircus/android-emulator-runner, API 34) and `engine-ios` (macos-latest).
- The integration jobs build the Go server first (`go build ./cmd/pictunnel`).
- Pigeon drift check, `flutter analyze`, golden tests.

## 10. Risks
| Risk | Mitigation |
|---|---|
| iOS background behaviour can't be verified without a device | Protocol-level fakes plus macOS integration. An explicit v0.9 device test gate. Design keeps every upload resumable via HEAD/check, so OS-killed tasks are safe. |
| OEM battery killers on Android delay WorkManager | Foreground service while uploading. A "Battery optimisation" hint in Settings when work is repeatedly deferred (detected via run timestamps). |
| Large libraries (100k items) make the first scan and hash slow | Incremental and resumable hashing (the hash cache is persisted per item). Status shows "Preparing n of N". Hashing runs concurrently with checking in batches of 1000. |
| Unified timeline memory with 100k items | Drift paged queries by month. The phone index is paged over Pigeon (keyset). The merge happens per visible month, not for the whole library. |
| Pigeon codegen differs between platforms | Generated code is committed with a drift check, and one integration test calls every host method through the real Android binding. |
