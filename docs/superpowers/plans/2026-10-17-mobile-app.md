# Mobile App and Backup Engines (3A + 3B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the PicTunnel phone app: a Darkroom-styled Flutter UI with a unified timeline, a Kotlin backup engine for Android and a Swift backup engine for iOS, bridged with Pigeon.

**Architecture:**
- Each native engine owns its backup queue, hash cache and phone index (Room / GRDB). It runs scan → hash → check → tus upload in the background and decides every transition through a pure `decide()` function that is tested against the shared client-decision vectors.
- Flutter owns a Drift mirror of the server library and merges it with the engine's phone index by SHA-256.
- Platform APIs sit behind interfaces, so the engine core is testable on the JVM and on Linux Swift. Device-only behaviour is verified on CI (Android emulator, macOS runner).

**Tech Stack:**
- Flutter 3.44.0 (Dart 3.12) with flutter_riverpod 3 + riverpod_generator, go_router, drift, mobile_scanner, video_player, photo_view, pigeon.
- Android:
  - Kotlin 2.3.20, AGP 9.0.1, minSdk 29 / targetSdk 36
  - Room, WorkManager, OkHttp 5, kotlinx-serialization, JUnit5 + Robolectric, androidx.test + UI Automator
- iOS:
  - Swift 6.2, iOS 16+, GRDB.swift, CryptoKit, XCTest
- Exact library versions are pinned by each task at the latest stable release that is at least two weeks old, and recorded in the lockfiles.

**Spec:** [`docs/superpowers/specs/2026-10-17-mobile-app-design.md`](../specs/2026-10-17-mobile-app-design.md), cited as `M§n`. Contract: [`api/protocol/sync-protocol.md`](../../../api/protocol/sync-protocol.md), cited as `P§n`, and [`api/openapi.yaml`](../../../api/openapi.yaml). Visual design: canvas https://claude.ai/artifact/6JG7i78NP1JSxJuwG7TKBx (direction A · Darkroom). Its markup is the visual reference; the exact tokens are in M§7.2.

## Global Constraints

- **Commits:** every commit uses `git commit -s` only. **No AI attribution trailers** (no Co-Authored-By: Claude, no Claude-Session, no "Generated with"). Stage explicit paths, never `git add -A`.
- **Branch:** `feat/mobile-app`. Pushing it runs CI on GitHub (workflows trigger on `feat/**`). Push only when a task says so.
- **Dev host:** Windows 11 (Git Bash + PowerShell). There is **no local Flutter, Java, Android SDK, Mac or iPhone.** Docker Desktop is running. Use these images, as the Taskfile does:
  - `ghcr.io/cirruslabs/flutter:3.44.0`: Flutter plus Android SDK and Java. Use it for `flutter`, `dart`, Gradle for `mobile/android/**` and Pigeon.
  - `gradle:9.3.0-jdk17`: for pure-JVM Gradle builds.
  - `swift:6.2`: Linux Swift. Use it for the iOS engine core; it can't use PhotoKit, background URLSession or the Keychain. Pass `-j 1` to swift builds, because the host ran out of memory before.
  - `golang:1.27`: to build `pictunnel` for integration tests.

  Run containers with `MSYS_NO_PATHCONV=1 docker run --rm -v "D:/Projects/PicTunnel:/repo" -w /repo/...`. **Never stop, remove or touch other running containers.**
- **Generated code is never edited by hand:** `mobile/packages/pictunnel_api/`, `mobile/android/engine-api/generated/`, `mobile/ios/EngineAPI/Sources/EngineAPI/Generated/`, and the Pigeon outputs (`mobile/lib/core/engine/pigeon.g.dart`, `mobile/android/engine/src/main/kotlin/.../engine/bridge/Pigeon.g.kt`, `mobile/ios/Engine/Sources/PicTunnelEngine/Bridge/Pigeon.g.swift`). Regenerate with the Taskfile task.
- **Theme tokens (exact, M§7.2):**
  - Colors: ground `#111111`, surface `#1C1C1C`, line `#2A2A2A`, text `#F2EFEA`, muted `#A8A39B`, accent `#F0A63A`, ok `#5BC88A`.
  - Fonts: display Bricolage Grotesque, body Figtree, bundled as assets.
  - Touch targets ≥ 48 dp. Text contrast ≥ 4.5:1.
- **Item states (exact):** `Discovered, Hashed, Queued, Uploading, Verifying, BackedUp, Skipped, Freed, NeedsAttention, Paused`.
- **Upload profiles:**
  - Android: single-shot ≤ `recommended_chunk_bytes` (8388608 by default); otherwise 8 MiB PATCH chunks.
  - iOS: single-shot ≤ 64 MiB; otherwise 64 MiB chunk files.
  - Upload concurrency defaults to 2, maximum 4.
- **Retry:**
  - Backoff starts at 2 s, doubles each time, caps at 15 min, with full jitter.
  - An item gets 10 retryable failures before `NeedsAttention`.
  - `offline` never counts as an attempt. `Retry-After` is honored.
- **Every engine request** sends `PicTunnel-Client: android/<version>` or `ios/<version>`.
- **Pinning (P§6.3):** a chain the system trusts that matches the host is accepted. Otherwise the leaf's SPKI SHA-256 must equal the stored pin, compared as unpadded base64url.
- **Vectors:** `api/protocol/vectors`.
  - Kotlin and Swift run the `backup`, `auth` and `free_up_space` client-decision cases.
  - Dart runs `browse`, `pairing`, `setup` and `auth`.
  - All three run the hashing and pairing vectors.
  - Never edit the vectors. A failing vector means an engine bug.

## Review Focus

1. **App killed mid-upload, then relaunched days later after the session expired.** Expect: HEAD returns 404, the engine restarts with POST, and the server ends with one asset, never two. Pinned by: Task 8 `resumesAfterSessionExpiry`; Task 13 `testResumeAfterSessionExpiry`.
2. **A photo edited on the phone after it was backed up.** Expect: the fingerprint changes, the photo is re-hashed and uploaded as a new asset, and the old one is never freed by mistake. Pinned by: Task 9 `editedPhotoRehashedAndNotFreed`; Task 14 `testEditedAssetRehashed`.
3. **Pairing with a server whose certificate changed (reinstall).** Expect: the pin mismatches, the connection is refused, and the UI offers "Pair again". Nothing is sent. Pinned by: Task 7 `rejectsChangedPin`; Task 12 `testRejectsChangedPin`; Task 15 widget test `pinMismatchShowsPairAgain`.
4. **The user denies photo access, or grants partial access.** Expect: no crash. A banner explains the situation, and only granted items are backed up. Pinned by: Task 9 `partialAccessBacksUpGrantedOnly`; Task 16 widget test `permissionBannerStates`.
5. **The library holds 100k items.** Expect: the timeline scrolls smoothly with paged months, and the first scan reports progress and can resume. Pinned by: Task 5 `mergeIsPerMonthAndPaged` (100k fake items, bounded work); Task 8 `hashingResumesFromCache`.

---

### Task 1: Branch, Flutter dependencies, Pigeon bridge definitions

**Files:**
- Create: `mobile/pigeons/engine.dart`, plus the Pigeon outputs listed in Global Constraints.
- Modify: `mobile/pubspec.yaml` (add deps), `Taskfile.yml` (`gen:pigeon`, including it in `gen`), `tools/ci/check-clean.mjs` if needed.
- Test: `mobile/test/pigeon_smoke_test.dart`.

**Interfaces (produces):** the Pigeon API exactly as M§3 specifies. Exact Dart definitions:
```dart
enum ItemState { discovered, hashed, queued, uploading, verifying, backedUp, skipped, freed, needsAttention, paused }
enum PauseReason { user, wifiRequired, chargingRequired, serverFull, quota, clientTooOld, permission }
class PairRequest { String? qrUri; String? serverUrl; String? code; String deviceName; String? pinnedFp; }
class PairResult { String serverId; String serverName; String userName; String deviceId; }
class ServerIdentity { String serverId; String name; String fp16; String fpFull; String url; }
class ServerConnection { String serverId; String name; String activeEndpoint; bool onLan; String fp16; }
class UploadProgress { String localId; String filename; int sentBytes; int totalBytes; double bytesPerSecond; }
class BackupStatus { int backedUp; int total; int queued; UploadProgress? uploading; int needsAttention; int skipped; int freeableBytes; bool paused; PauseReason? pauseReason; int? lastRunAtMs; int preparing; }
class EngineSettings { bool wifiOnly; bool chargingOnly; bool includeVideos; bool keepUneditedOriginals; bool allAlbums; List<String> albumIds; }
class PhoneItem { String localId; String? sha256; int takenAtMs; String mime; int size; int? width; int? height; int? durationMs; ItemState state; String? assetId; bool isLivePhoto; }
class PageRequest { String? afterKey; int limit; }
class PhoneItemPage { List<PhoneItem> items; String? nextKey; }
class AttentionItem { String localId; String filename; String code; String message; int attempts; }
class ActivityEntry { int atMs; String kind; String message; String? localId; }
class SkippedFree { String localId; String reason; }
class FreeUpResult { int freedCount; int freedBytes; List<SkippedFree> skipped; }
class AlbumInfo { String id; String name; int count; }
@HostApi() abstract class EngineHostApi {
  @async PairResult pair(PairRequest req);
  @async ServerIdentity trustOnFirstUse(String serverUrl);
  @async void unpair();
  @async String getAccessToken();
  @async ServerConnection? serverInfo();
  @async void start(); @async void pause(PauseReason reason); @async void runNow();
  @async BackupStatus getStatus();
  @async EngineSettings getSettings(); @async void setSettings(EngineSettings s);
  @async List<AlbumInfo> listAlbums();
  @async PhoneItemPage listPhoneItems(PageRequest req);
  @async Uint8List phoneThumbnail(String localId, int sizePx);
  @async List<AttentionItem> listAttention(); @async void retry(List<String> localIds);
  @async List<ActivityEntry> listActivity(int limit);
  @async FreeUpResult freeUpSpace(List<String>? localIds);
  @async void undoSkip(String sha256);
  @async String saveToGallery(String assetId, String filename, String mime);
  @async List<String> discoverServers(int timeoutMs); // mDNS, returns https URLs
}
@FlutterApi() abstract class EngineEventsApi {
  void onStatus(BackupStatus s); void onItemChanged(PhoneItem item); void onNeedsRepair();
}
```
- Kotlin package: `io.github.prithvirajg.pictunnel.engine.bridge`.
- Swift output: `mobile/ios/Engine/Sources/PicTunnelEngine/Bridge/Pigeon.g.swift`.
- Dart output: `mobile/lib/core/engine/pigeon.g.dart`.

- [ ] **Step 1:** Create branch `feat/mobile-app` from `main`.
- [ ] **Step 2:** Add the pubspec deps:
  - `flutter_riverpod`, `riverpod_annotation`, `go_router`, `drift`, `drift_flutter`, `sqlite3_flutter_libs`, `path_provider`, `mobile_scanner`, `photo_view`, `video_player`, `share_plus`, `intl`, `crypto`, `collection`
  - dev deps: `pigeon`, `build_runner`, `riverpod_generator`, `drift_dev`, `custom_lint`, `riverpod_lint`, `glados`, `mocktail`
  
  Pin each to an exact version and run `flutter pub get` in the Flutter image.
- [ ] **Step 3:** Write `pigeons/engine.dart` from the block above. Add the Taskfile `gen:pigeon` task (`dart run pigeon --input pigeons/engine.dart` in the Flutter image), run it, and commit the three outputs.
- [ ] **Step 4:** Failing then passing `pigeon_smoke_test.dart`. It encodes and decodes `BackupStatus` and `PhoneItem` through the generated codec and checks the round-trip equality of every field.
- [ ] **Step 5:** `flutter analyze` and `flutter test` must be clean. Commit: `feat(mobile): pigeon engine bridge definitions and app dependencies`.

### Task 2: Darkroom theme, fonts, app shell

**Files:**
- Create: `mobile/lib/app/app.dart`, `router.dart`, `theme/tokens.dart`, `theme/theme.dart`, `theme/typography.dart`, `mobile/assets/fonts/` (Bricolage Grotesque and Figtree TTFs plus `OFL.txt`), and `mobile/lib/app/shell.dart` (bottom nav: Photos, Backup, Settings, styled like canvas `Main.dc.html`).
- Modify: `mobile/lib/main.dart`, `pubspec.yaml` (fonts, assets).
- Test: `mobile/test/app/shell_test.dart`, `mobile/test/goldens/shell_golden_test.dart`.

**Interfaces (produces):**
- `class Tokens { static const ground = Color(0xFF111111); surface=0xFF1C1C1C; line=0xFF2A2A2A; text=0xFFF2EFEA; muted=0xFFA8A39B; accent=0xFFF0A63A; ok=0xFF5BC88A; }`
- `ThemeData darkroomTheme()`
- `GoRouter buildRouter(Ref ref)` with routes `/photos`, `/photos/:assetKey`, `/backup`, `/backup/attention`, `/backup/activity`, `/settings`, `/settings/trash`, `/pair`.
- Redirect to `/pair` when `engine.serverInfo()` is null.

Steps:
- [ ] **Step 1:** Failing widget test: the shell renders three tabs with labels Photos, Backup and Settings. Tapping each changes the route. The active tab uses the accent color.
- [ ] **Step 2:** Implement. Set up goldens with fonts loaded from assets in `flutter_test_config.dart`, so the Linux runner gets deterministic text.
- [ ] **Step 3:** Pass. Commit: `feat(mobile): Darkroom theme, bundled fonts and app shell`.

### Task 3: Dart decisions and vectors

**Files:**
- Create: `mobile/lib/core/decisions/decide.dart`, `mobile/lib/core/pairing/pair_uri.dart`.
- Test: `mobile/test/vectors/vectors_test.dart` (loads `../api/protocol/vectors/**` via a relative path from `mobile/`).

**Interfaces (produces):**
```dart
class Given { String flow; String itemState; String lastAction; Map<String, Object?> item; }
class ServerOutcome { int? status; Map<String,String> headers; Object? body; String? transport; } // transport: timeout|reset|offline
class Decision { String nextState; String action; int attemptsDelta; }
Decision decide(Given g, ServerOutcome s);   // flows browse, pairing, setup, auth
PairUri parsePairUri(String uri);            // throws PairUriError(code) with codes per P§10.3
bool acceptConnection(PairUri u, {required bool systemTrusted, required String spkiSha256});
String sha256Hex(Stream<List<int>> bytes);   // Future<String>
```
`server.problem: "<code>"` expands per P§10.5.

- [ ] **Step 1:** Write the vector test. It iterates the client-decision cases with flow in {browse, pairing, setup, auth} and asserts `next_state`, `action` and `attempts_delta`. It also runs all pairing and hashing cases (generate the counter pattern per P§10.1).
- [ ] **Step 2:** Run it and confirm FAIL. Then implement and confirm PASS. Commit: `feat(mobile): Dart decision function, pair URI parser and hashing per vectors`.

### Task 4: Drift database, server mirror sync, thumbnail cache

**Files:**
- Create: `mobile/lib/core/db/app_db.dart` (+ `.g.dart`), `server_assets_dao.dart`, `thumb_cache.dart`, `mobile/lib/core/api/api_client.dart` (pictunnel_api with a `TokenProvider` interceptor), `mobile/lib/core/sync/mirror_sync.dart`.
- Test: `mobile/test/sync/mirror_sync_test.dart` (fake HTTP via a dio adapter mock), `mobile/test/db/thumb_cache_test.dart`.

**Interfaces (produces):**
- `abstract class TokenProvider { Future<String> accessToken(); }`. The real implementation calls `EngineHostApi.getAccessToken()`.
- `class MirrorSync { Future<void> syncOnce(); Stream<int> changes; }` follows P§7.6:
  - snapshot paging, then changes from the cursor
  - `410` → reset and re-snapshot
  - upsert only when `updated_seq` is newer
  - `asset.removed` deletes the row
- `ServerAssetsDao.watchMonth(int year, int month) → Stream<List<ServerAsset>>`
- `ServerAssetsDao.monthsWithCounts() → Stream<List<MonthCount>>`
- `ThumbCache.get(assetId, size) → Future<File?>`, an LRU with a 512 MiB budget that evicts by `lastUsedAt`.
- On `404 not_ready` it returns null and `decide()` schedules a retry.

- [ ] Tests:
  - `snapshotThenChanges` and `cursorExpiredResnapshots`.
  - `staleUpsertIgnored`: older `updated_seq` is not applied.
  - `removedDeletesRow`.
  - `thumbCacheEvictsLru`: a 3-file budget.
  - `notReadyReturnsNull`.
- [ ] Implement, pass. Commit: `feat(mobile): drift server mirror with change-feed sync and thumbnail LRU`.

### Task 5: Unified timeline merge

**Files:**
- Create: `mobile/lib/features/timeline/timeline_model.dart`, `timeline_merge.dart`, `timeline_providers.dart`.
- Test: `mobile/test/timeline/merge_test.dart` (glados property tests).

**Interfaces (produces):**
- `enum Presence { both, serverOnly, phoneOnly }`
- `class TimelineItem { String key; /* sha256 if known else 'local:<localId>' */ Presence presence; ServerAsset? server; PhoneItem? phone; DateTime takenAt; bool isVideo; bool isLive; ItemState? phoneState; }`
- `List<TimelineSection> mergeMonth(List<ServerAsset> server, List<PhoneItem> phone, {required DateTime now})`
  - Sections: "This week" for items within the 7 days before now, then by month, newest first.
  - Ordering within a section: `takenAt` desc, then key.
- `final timelineMonthsProvider`, `final timelineMonthProvider(MonthKey)`.

- [ ] Property tests:
  1. Every server asset (active) and every phone item appears exactly once.
  2. Items with an equal sha → one `both`.
  3. A phone item without a sha → `phoneOnly`.
  4. Trashed server assets are excluded.
  5. Ordering is total and stable.
  6. `mergeIsPerMonthAndPaged`: a fake source of 100k items with a call counter; rendering one month touches only that month's items, at most 2 pages of the phone index.
- [ ] Implement, pass. Commit: `feat(mobile): unified phone and server timeline merge`.

### Task 6: Android engine module, store, decide, vectors

**Files:**
- Create: `mobile/android/engine/` (Android library module `:engine`, namespace `io.github.prithvirajg.pictunnel.engine`, minSdk 29, targetSdk 36) with:
  - `build.gradle.kts`
  - `src/main/kotlin/.../engine/model/` (`ItemState`, `Item`, `PauseReason`)
  - `store/` (Room `EngineDb`, entities and DAOs: `items`, `hash_cache`, `scan_state`, `activity`, `settings`)
  - `decide/Decide.kt`
  - `hash/Sha256.kt`
  - `pairing/PairUri.kt`
- Modify: `mobile/android/settings.gradle.kts` (include `:engine`), `mobile/android/app/build.gradle.kts` (`implementation(project(":engine"))`).
- Test: `src/test/kotlin/.../VectorsTest.kt` (JUnit5; reads `../../../api/protocol/vectors`), `store/ItemsDaoTest.kt` (Robolectric, in-memory Room).

**Interfaces (produces):**
```kotlin
data class Given(val flow: String, val itemState: String, val lastAction: String, val item: Map<String, Any?>)
data class ServerOutcome(val status: Int?, val headers: Map<String,String>, val body: JsonElement?, val transport: String?)
data class Decision(val nextState: ItemState, val action: Action, val attemptsDelta: Int)
enum class Action { MARK_BACKED_UP, QUEUE_UPLOAD, RESUME_UPLOAD, HEAD_THEN_RESUME, RESTART_UPLOAD, MARK_SKIPPED, REHASH_AND_REQUEUE, BACKOFF_RETRY, WAIT_RETRY_AFTER, WAIT_FOR_NETWORK, REFRESH_THEN_RETRY, RETRY_ORIGINAL_REQUEST, REQUIRE_REPAIR, PAUSE_ALL_UPLOADS, NOTIFY_QUOTA, PROMPT_UPDATE, MARK_NEEDS_ATTENTION, RUN_SNAPSHOT, RETRY_LATER, SKIP_THIS_RUN, UPLOAD_PRIMARY_FIRST, UPLOAD_LIVE_VIDEO, CHECK_THEN_RESOLVE, DELETE_LOCAL_ALLOWED, DELETE_LOCAL_DENIED, SHOW_ERROR, GO_TO_LOGIN }
object Decide { fun decide(g: Given, s: ServerOutcome): Decision }
fun backoffDelayMs(attempt: Int, random: java.util.Random): Long // full jitter, base 2000, cap 900_000
@Entity("items") data class ItemEntity(@PrimaryKey val localId: String, val sha256: String?, val size: Long, val modifiedAtMs: Long, val takenAtMs: Long, val mime: String, val kind: String, val pairRole: String, val pairLocalId: String?, val stackKey: String?, val state: ItemState, val attempts: Int, val nextAttemptAtMs: Long?, val uploadId: String?, val uploadUrl: String?, val uploadOffset: Long?, val assetId: String?, val lastError: String?, val filename: String)
interface ItemsDao { /* upsert, get, byState(states, limit), page(afterTakenAt, afterLocalId, limit), counts(): StateCounts, setState(...) */ }
```

- [ ] Steps:
  1. Write the vector test (FAIL).
  2. Implement `Decide`, `Sha256` (streaming `MessageDigest`), `PairUri` and the Room store.
  3. PASS: all backup, auth and free_up_space cases, plus all hashing and pairing cases.
  4. DAO tests: upsert idempotent, paging keyset, counts.
  5. Build with `./gradlew :engine:testDebugUnitTest` in the Flutter image (it has the Android SDK).
  6. Commit: `feat(android): engine module with room store and vector-tested decide()`.

### Task 7: Android network layer: client, pinning, auth, check, tus (REVIEW)

**Files:**
- Create in `mobile/android/engine/src/main/kotlin/.../engine/net/`:
  - `ServerClient.kt`
  - `PinningTrustManager.kt`
  - `Endpoints.kt`
  - `AuthManager.kt` (single-flight refresh, P§6.2)
  - `CheckApi.kt`
  - `TusClient.kt` (create with/without body, HEAD, PATCH from a seekable source, DELETE)
  - `Problem.kt` (problem+json parsing into `ServerOutcome`)
- Create: `cred/CredentialStore.kt`, the interface plus a Keystore implementation in Task 9.
- Test: `src/test/.../net/` with OkHttp `MockWebServer`.

**Interfaces (produces):**
```kotlin
interface CredentialStore { fun load(): Credentials?; fun save(c: Credentials); fun wipe() }
data class Credentials(val serverId: String, val endpoints: List<String>, val pinSpki: String, val refreshToken: String, val deviceId: String)
class AuthManager(store: CredentialStore, client: OkHttpClient, clock: () -> Long) { suspend fun accessToken(): String; suspend fun onUnauthorized(): RefreshOutcome }
class ServerClient(endpoints: Endpoints, auth: AuthManager, http: OkHttpClient, clientHeader: String) {
  suspend fun serverInfo(): ServerInfo
  suspend fun check(items: List<CheckItem>, confirmOnDisk: Boolean = false): Outcome<List<CheckResult>>
  val tus: TusClient
}
class TusClient { suspend fun create(meta: UploadMeta, length: Long, body: UploadBody?): Outcome<TusCreated>; suspend fun head(url: String): Outcome<TusHead>; suspend fun patch(url: String, offset: Long, body: UploadBody): Outcome<TusPatched>; suspend fun terminate(url: String): Outcome<Unit> }
sealed interface Outcome<out T> { data class Ok<T>(val value: T, val raw: ServerOutcome): Outcome<T>; data class Fail(val raw: ServerOutcome): Outcome<Nothing> }
fun interface UploadBody { fun open(offset: Long, length: Long): okio.Source }
```
- `Upload-Metadata` is encoded per P§7.3 (key + standard base64, comma-separated).
- `Location` is resolved against the active endpoint.

- [ ] Tests:
  - `metadataEncoding` (golden header string).
  - `createSingleShotFinalizes`.
  - `chunkedPatchSequence`.
  - `offsetMismatchReturnsServerOffset`.
  - `refreshSingleFlight`: 10 concurrent 401s → 1 refresh call.
  - `refreshReusedWipesCredentials`.
  - `endpointFallbackLanThenRemote`: LAN connect timeout 3 s.
  - `acceptsSystemTrusted`.
  - `acceptsPinnedSelfSigned`.
  - `rejectsChangedPin` (Review Focus 3; no request body is ever sent).
  - `clientHeaderOnEveryRequest`.
  - `retryAfterParsed`.
- [ ] Implement, pass. Commit: `feat(android): engine network layer with pinning, single-flight refresh and tus client`.

### Task 8: Android engine controller pipeline and server integration (REVIEW)

**Files:**
- Create in `.../engine/core/`:
  - `EngineController.kt`
  - `Pipeline.kt` (hash → check batches ≤ 1000 → uploads with concurrency 2)
  - `Scanner.kt` (interface)
  - `MediaSource.kt` (interface: `open(localId): InputStream`, `fingerprint(localId)`)
  - `ActivityLog.kt` (ring buffer of 1000 in Room)
  - `StatusReporter.kt`
- Test:
  - `src/test/.../core/PipelineTest.kt`, with fakes and MockWebServer.
  - `src/test/.../it/ServerIntegrationTest.kt`. It starts a real `pictunnel` binary given by env `PICTUNNEL_BIN`: a temp data dir, `--server.https-addr 127.0.0.1:<free>`, `--server.local-addr 127.0.0.1:<free>`, and `--discovery.mdns=false`. It reads the setup token, sets up an admin, creates a pairing code, redeems it through the engine, and trusts the pin. It is skipped when `PICTUNNEL_BIN` is unset.

**Interfaces (produces):**
```kotlin
interface Scanner { suspend fun scan(since: ScanCursor?): ScanResult /* changed items + new cursor + fullRescan flag */ }
interface MediaSource { fun open(localId: String): java.io.InputStream; fun fingerprint(localId: String): Fingerprint? /* null if deleted */; fun openSeekable(localId: String): UploadBody }
class EngineController(db: EngineDb, scanner: Scanner, media: MediaSource, client: ServerClient, settings: SettingsRepo, clock: Clock, events: EngineEvents) {
  suspend fun runOnce(budget: RunBudget): RunReport   // scan→hash→check→upload until budget or idle
  suspend fun status(): BackupStatus; suspend fun freeUpSpace(ids: List<String>?, deleter: Deleter): FreeUpResult
}
interface EngineEvents { fun status(s: BackupStatus); fun itemChanged(i: ItemEntity); fun needsRepair() }
```
Every state write happens before its network call (R1). Every server response goes through `Decide.decide`.

- [ ] Unit tests:
  - `freshUploadToBackedUp`.
  - `existsVerdictNoUpload`.
  - `partialVerdictResumes`.
  - `tombstonedSkipped`.
  - `timeoutWithUploadIdHeads`, and `timeoutWithoutUploadIdChecks` (R2).
  - `tenFailuresNeedsAttention`.
  - `offlineDoesNotCountAttempt`.
  - `insufficientStoragePausesAll`.
  - `hashingResumesFromCache` (Review Focus 5: a killed run re-hashes nothing already cached).
  - `livePhotoPrimaryFirst`.
- [ ] Integration tests against the real server:
  - `uploadsAndDedupes`: same bytes twice gives 1 asset.
  - `dropMidPatchResumes`: OkHttp interceptor aborts after N bytes.
  - `resumesAfterSessionExpiry`: server-side expiry can't be triggered from outside, so simulate it by sending a tus `DELETE` for the in-flight session. The next `HEAD` returns `404`, and the test expects the engine to restart with `POST` and finish with exactly one asset (Review Focus 1).
  - `tombstoneSkipsThenUndo`: purge via the API, then `undoSkip`.
  - `refreshRotationSurvives`.
- [ ] Taskfile `test:engine:android` builds the Go server in `golang:1.27` (`CGO_ENABLED=0 GOOS=linux go build -o /repo/.cache/pictunnel ./cmd/pictunnel`), then runs Gradle in the Flutter image with `PICTUNNEL_BIN=/repo/.cache/pictunnel`.
- [ ] Commit: `feat(android): engine controller pipeline with real-server integration tests`.

### Task 9: Android platform adapters, workers, credentials, free up space (REVIEW)

**Files:**
- Create in `.../engine/platform/`:
  - `MediaStoreScanner.kt` (generation-based, album filter, include videos, partial-access aware)
  - `ContentMediaSource.kt`
  - `KeystoreCredentialStore.kt` (AES-GCM key in AndroidKeyStore; ciphertext in a `noBackupFilesDir` file)
  - `NsdDiscovery.kt`
  - `MediaStoreDeleter.kt` (`createDeleteRequest` launcher contract)
  - `GalleryWriter.kt` (`saveToGallery` via MediaStore insert with `IS_PENDING`)
- Create in `.../engine/sched/`:
  - `ScanWorker.kt`, `SyncWorker.kt`
  - `UploadForegroundService.kt` (type `dataSync`; notification with remaining count and Pause)
  - `Scheduling.kt` (constraints from settings, unique work KEEP, content-URI trigger, 6 h periodic)
- Modify: `engine/src/main/AndroidManifest.xml` (permissions per M§4.6, service declaration).
- Test:
  - `src/test/.../platform/` (Robolectric): scanner with a ShadowContentResolver fake cursor; `editedPhotoRehashedAndNotFreed` (Review Focus 2).
  - `src/androidTest/.../` (instrumented, emulator API 34):
    - `scanFindsInsertedImage` (inserts via MediaStore)
    - `workManagerRunsSyncWithTestDriver` (`WorkManagerTestInitHelper`)
    - `keystoreRoundTrip`
    - `deleteRequestShowsSystemDialog` (UI Automator clicks Allow)
    - `partialAccessBacksUpGrantedOnly` (Review Focus 4; `READ_MEDIA_VISUAL_USER_SELECTED` granted only)

- [ ] Implement with TDD on the Robolectric tests.
- [ ] The instrumented tests compile locally (`./gradlew :engine:assembleDebugAndroidTest`) and run in CI (Task 20).
- [ ] Commit: `feat(android): MediaStore scanner, workers, foreground uploads, keystore and free-up-space`.

### Task 10: Android EngineHost bridge wiring

**Files:**
- Create: `.../engine/bridge/EngineHost.kt` (implements the generated `EngineHostApi`, delegating to the controller, scheduling and platform), `.../engine/bridge/EventsRelay.kt` (throttles to 4 per second, `EngineEventsApi`).
- Modify: `mobile/android/app/src/main/kotlin/.../MainActivity.kt` (register the host, activity-result launchers for delete requests), `app/src/main/AndroidManifest.xml`.
- Test: `src/test/.../bridge/EngineHostTest.kt` (Robolectric, every host method called once through the generated binary messenger codec with a fake controller).

- [ ] Implement, pass. Run `flutter build apk --debug` in the Flutter image.
- [ ] Commit: `feat(android): pigeon EngineHost bridge and app registration`.

### Task 11: iOS engine package: store, decide, vectors

**Files:**
- Create: `mobile/ios/Engine/Package.swift` (product `PicTunnelEngine`, iOS 16 / macOS 13; GRDB dependency), with:
  - `Sources/PicTunnelEngine/Model/` (`ItemState`, `Item`, `PauseReason`)
  - `Store/` (GRDB `EngineDB` with migrations for `items`, `hash_cache`, `scan_state`, `activity`, `settings`)
  - `Decide/Decide.swift`
  - `Hash/SHA256Stream.swift` (CryptoKit on Apple, `swift-crypto` `Crypto` on Linux via `#if canImport(CryptoKit)`)
  - `Pairing/PairURI.swift`
- Test: `Tests/PicTunnelEngineTests/VectorsTests.swift` (reads `../../../api/protocol/vectors` relative to `#filePath`), `StoreTests.swift`.

**Interfaces (produces):** the Swift mirrors of Task 6:
- `struct Given`, `struct ServerOutcome`, `struct Decision`
- `enum Action: String` (same raw values as the vector action names)
- `enum Decide { static func decide(_ g: Given, _ s: ServerOutcome) -> Decision }`
- `func backoffDelay(attempt: Int, rng: inout some RandomNumberGenerator) -> TimeInterval`
- `final class EngineDB { init(path: String) throws; func upsert(_ item: Item) throws; func page(after: PageKey?, limit: Int) throws -> [Item]; func counts() throws -> StateCounts; ... }`

- [ ] Vector test FAIL → implement → PASS (backup, auth, free_up_space + hashing + pairing). Run in Docker `swift:6.2` with `swift test -j 1 --package-path mobile/ios/Engine`.
- [ ] Commit: `feat(ios): engine package with GRDB store and vector-tested decide()`.

### Task 12: iOS network layer: client, pinning, auth, check, tus (REVIEW)

**Files:**
- Create: `Sources/PicTunnelEngine/Net/` with:
  - `ServerClient.swift`
  - `PinningDelegate.swift` (SecTrust evaluation + SPKI hash; `#if canImport(Security)`)
  - `Endpoints.swift`
  - `AuthManager.swift` (actor; single-flight refresh)
  - `CheckAPI.swift`
  - `TusRequests.swift` (pure builders: create/HEAD/PATCH/DELETE `URLRequest`s and metadata encoding)
  - `ChunkSlicer.swift` (64 MiB slice files)
  - `Problem.swift`
- Create: `Cred/CredentialStore.swift` (protocol + in-memory fake).
- Test: `NetTests.swift`, using `URLProtocol` stubs, which work on Linux Foundation for the data-task paths. Pinning tests run on macOS only (`#if canImport(Security)`).

**Interfaces (produces):**
- `protocol CredentialStore { func load() throws -> Credentials?; func save(_ c: Credentials) throws; func wipe() throws }`
- `actor AuthManager { func accessToken() async throws -> String; func onUnauthorized() async -> RefreshOutcome }`
- `struct ServerClient { func serverInfo() async throws -> ServerInfo; func check(_ items: [CheckItem], confirmOnDisk: Bool) async -> Outcome<[CheckResult]> }`
- `enum TusRequests { static func create(base: URL, meta: UploadMeta, length: Int64, bodyFile: URL?) -> URLRequest; static func head(_ url: URL) -> URLRequest; static func patch(_ url: URL, offset: Int64) -> URLRequest; static func encodeMetadata(_ m: UploadMeta) -> String }`
- `struct ChunkSlicer { func slice(source: URL, offset: Int64, length: Int64, into dir: URL) throws -> URL }`

- [ ] Tests mirror Task 7:
  - `testMetadataEncoding`, `testRefreshSingleFlight`, `testRefreshReusedWipes`.
  - `testEndpointFallback`, `testRejectsChangedPin` (macOS), `testClientHeader`.
  - `testChunkSlicerExactBytes`, which checks the slice contents against the counter-pattern payload C.
- [ ] Commit: `feat(ios): engine network layer with pinning, single-flight refresh and tus request builders`.

### Task 13: iOS engine controller, background uploader abstraction, server integration (REVIEW)

**Files:**
- Create: `Sources/PicTunnelEngine/Core/` with:
  - `EngineController.swift`
  - `Pipeline.swift`
  - `PhotoLibrary.swift` (protocol: scan with a change token; `exportResource(localId, role) -> URL` with hashing during export)
  - `BackgroundUploader.swift` (protocol: `enqueue(request:file:taskDescription:)`, plus a completion callback mapping `taskDescription "<itemId>|<uploadId>|<offset>"` back to items)
  - `ActivityLog.swift`
  - `StatusReporter.swift`
  - `ForegroundUploader.swift` (a URLSession data-task implementation of `BackgroundUploader`, used in tests and on Linux)
- Test:
  - `PipelineTests.swift` (fakes).
  - `ServerIntegrationTests.swift`. It runs a real `pictunnel` via env `PICTUNNEL_BIN`: setup, pair, upload, drop and resume (a stub uploader cancels mid-chunk), duplicate, tombstone with `undoSkip`, refresh rotation, and `testResumeAfterSessionExpiry` (Review Focus 1). It is skipped when `PICTUNNEL_BIN` is unset.

**Interfaces (produces):** `final class EngineController { init(db: EngineDB, library: PhotoLibrary, uploader: BackgroundUploader, client: ServerClient, settings: SettingsRepo, clock: Clock, events: EngineEvents); func runOnce(budget: RunBudget) async -> RunReport; func handleUploadCompletion(taskDescription: String, status: Int?, headers: [String:String], error: Error?) async; func status() async -> BackupStatus; func freeUpSpace(_ ids: [String]?, deleter: Deleter) async -> FreeUpResult }`. Live Photos follow H4 and edits follow H3, via `PhotoLibrary` resource roles: `primary`, `liveVideo`, `original`.

- [ ] Unit tests mirror Task 8, plus:
  - `testChunkedViaBackgroundUploaderCompletionMapping`.
  - `testRelaunchRestoresInFlightFromTaskDescription`.
  - `testUneditedOriginalStackKey`.
  - `testEditedAssetRehashed` (Review Focus 2).
- [ ] The Linux run covers everything except the macOS-only pinning. The integration test runs on Linux too, against a `pictunnel` built for Linux.
- [ ] Commit: `feat(ios): engine controller with background-uploader mapping and real-server integration`.

### Task 14: iOS platform adapters and Runner wiring

**Files:**
- Create: `Sources/PicTunnelEngine/Platform/` (`#if os(iOS)`) with:
  - `PhotoKitLibrary.swift` (`PHPersistentChangeToken`, limited access, H3/H4 resources, export with `PHAssetResourceManager`)
  - `BackgroundSessionUploader.swift` (identifier `io.github.prithvirajg.pictunnel.upload`, `sessionSendsLaunchEvents`, `handleEventsForBackgroundURLSession` hook)
  - `BGTasks.swift` (register `io.github.prithvirajg.pictunnel.refresh`, `.process`; `BGContinuedProcessingTask` behind `if #available(iOS 26, *)`)
  - `KeychainCredentialStore.swift` (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)
  - `BonjourDiscovery.swift` (`NWBrowser`)
  - `PhotoKitDeleter.swift`
  - `GalleryWriter.swift`
  - `Bridge/EngineHost.swift` (implements the generated `EngineHostApi`)
  - `Bridge/EventsRelay.swift`
- Modify:
  - `mobile/ios/Runner/AppDelegate.swift`: register the host and BG tasks; forward background session events.
  - `mobile/ios/Runner/Info.plist`: `NSPhotoLibraryUsageDescription`, `NSPhotoLibraryAddUsageDescription`, `NSCameraUsageDescription` (QR), `NSLocalNetworkUsageDescription`, `NSBonjourServices` = `_pictunnel._tcp`, `BGTaskSchedulerPermittedIdentifiers`, `UIBackgroundModes` = fetch, processing.
  - The Xcode project, to link the local `Engine` package (Swift Package reference).
- Test: `Tests/PicTunnelEngineTests/PlatformTests.swift`, macOS/iOS-simulator only and skipped on Linux. It checks the PhotoKit resource-role selection logic through an injected `PHAssetResource` adapter.

- [ ] This cannot be built locally (no Mac). Make the Linux `swift build` still pass by guarding with `#if os(iOS)`. Push the branch so CI's `ios` job (`flutter build ios --no-codesign` + `swift test` on macOS) verifies it. Fix until green.
- [ ] Commit: `feat(ios): PhotoKit, background session, BG tasks, keychain and Runner wiring`.

### Task 15: Engine wrapper providers and the pairing flow (Flutter)

**Files:**
- Create:
  - `mobile/lib/core/engine/engine.dart`: wrapper `Engine` over `EngineHostApi`, plus `EngineEventsApi` setup exposing streams.
  - `mobile/lib/core/engine/fake_engine.dart`: an in-memory fake for tests and the debug "demo" flavor.
  - `mobile/lib/features/pairing/`: `pair_screen.dart`, `qr_scanner_view.dart`, `manual_server_screen.dart`, `pairing_controller.dart`.
- Test: `mobile/test/pairing/pairing_test.dart` and goldens: pair screen, server-found card, manual entry with fingerprint comparison, and `pinMismatchShowsPairAgain` (Review Focus 3).

**Interfaces (produces):**
- `final engineProvider = Provider<Engine>`
- `Engine.status$` (`Stream<BackupStatus>`), `Engine.items$` (`Stream<PhoneItem>`), `Engine.needsRepair$`.
- The pairing controller maps `PairUriError` codes and engine errors to copy (M§8).
- The layout matches canvas `A-Pair.dc.html`.

- [ ] Widget tests first, then implement. Commit: `feat(mobile): pairing flow with QR, manual server and fingerprint check`.

### Task 16: Backup screen, needs attention, activity (Flutter)

**Files:**
- Create: `mobile/lib/features/backup/` (`backup_screen.dart`, `progress_ring.dart`, `upload_card.dart`, `queue_list.dart`, `rule_chips.dart`, `banners.dart`), `mobile/lib/features/attention/attention_screen.dart`, `mobile/lib/features/activity/activity_screen.dart`.
- Test: widget tests for every `BackupStatus` shape (idle, uploading, paused for each `PauseReason`, preparing n of N, needs attention > 0), `permissionBannerStates` (Review Focus 4), and goldens matching canvas `Main.dc.html`.

- [ ] Implement against `FakeEngine`. Commit: `feat(mobile): backup status, needs-attention and activity screens`.

### Task 17: Photos timeline screen (Flutter)

**Files:**
- Create: `mobile/lib/features/timeline/` (`timeline_screen.dart`, `month_section.dart`, `tile.dart` with presence badges, `selection_bar.dart`), `mobile/lib/core/thumbs/thumb_image.dart` (phone thumbnail via engine or server thumbnail via `ThumbCache`).
- Test:
  - Widget tests: badges per presence and state, "Not on this phone" filter, multi-select actions, pinch from 3 to 5 columns.
  - Goldens matching canvas `A-Timeline.dc.html`.
  - A scroll performance smoke test: 10k fake items, frame build count bounded.

- [ ] Implement. Commit: `feat(mobile): unified photos timeline with presence badges and selection`.

### Task 18: Viewer, download, trash (Flutter)

**Files:**
- Create: `mobile/lib/features/viewer/` (`viewer_screen.dart`, `photo_page.dart` (photo_view, preview → original on zoom), `video_page.dart` (video_player over the `playback` URL with an auth header), `live_photo.dart`, `info_panel.dart`, `viewer_actions.dart`), `mobile/lib/features/trash/trash_screen.dart` (restore, delete forever, empty).
- Test:
  - Widget tests: actions per presence (Free up only when `both` and BackedUp; Original download calls `engine.saveToGallery`; Trash confirms "Removes it from your server", then calls the API).
  - Video uses an auth header.
  - Golden matching canvas `A-Viewer.dc.html`.

- [ ] Implement. Commit: `feat(mobile): photo/video viewer, save to gallery and server trash`.

### Task 19: Settings and free-up-space flow (Flutter)

**Files:**
- Create: `mobile/lib/features/settings/` (`settings_screen.dart`, `album_picker.dart`, `free_up_sheet.dart`, `server_section.dart`, `about_screen.dart` with `LicenseRegistry` entries for the bundled fonts).
- Test:
  - Toggles call `setSettings`.
  - "Unedited originals" is shown only on iOS (`defaultTargetPlatform`).
  - The free-up sheet shows the count and bytes, calls `freeUpSpace`, and reports skipped reasons.
  - Unpair confirms first.
  - Golden matching canvas `A-Settings.dc.html`.

- [ ] Implement. Commit: `feat(mobile): settings, album selection and free-up-space flow`.

### Task 20: CI, docs, end-to-end verification

**Files:**
- Modify: `.github/workflows/ci-mobile.yml`, `Taskfile.yml` (`test:engine:android`, `test:engine:ios`, `gen:pigeon`), `mobile/README.md`.
- Create: `docs/mobile/architecture.md` (short: bridge, ownership, background behaviour per platform, how to run tests in Docker).

**CI jobs:**
- `flutter`: pub get, `flutter analyze`, `flutter test` including goldens, `flutter build apk --debug`.
- `engine-android-unit`: build the Go server, then `./gradlew :engine:testDebugUnitTest` with `PICTUNNEL_BIN`.
- `engine-android-instrumented`: `reactivecircus/android-emulator-runner@v2`, API 34, x86_64, `./gradlew :engine:connectedDebugAndroidTest`.
- `engine-ios` (macos-latest):
  - build the Go server for darwin/arm64
  - `swift test --package-path mobile/ios/Engine` with `PICTUNNEL_BIN`
  - `flutter build ios --debug --no-codesign`
- `pigeon-drift`: regenerate, then `git diff --exit-code`.

- [ ] Push `feat/mobile-app`, watch CI (`gh run watch` is read-only and works), and fix until all mobile jobs are green on Linux, macOS and the emulator.
- [ ] Commit: `ci(mobile): engine unit, emulator and iOS jobs; pigeon drift; docs`.
