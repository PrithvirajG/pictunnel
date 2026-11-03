# Mobile architecture

A short map of the mobile app. The full design is in
`docs/superpowers/specs/2026-10-17-mobile-app-design.md` (cited as M§n) and the protocol in the
protocol spec (P§n).

## Two halves

```
Flutter UI (Dart)                         Native engine (Kotlin on Android, Swift on iOS)
  screens, Riverpod, Drift mirror           EngineHost -> EngineController
  pictunnel_api: browse + account calls     scanner, hasher, decide(), tus uploads,
          |                                 credentials, scheduler, free up space
          |   Pigeon EngineHostApi  ------>          |
          |   <------ EngineEventsApi                |
          v                                          v
                      pictunnel server (HTTPS, pinned)
```

The **Flutter UI** draws every screen. It talks to the server only for browsing and account
calls: snapshot and changes, assets, thumbnails, originals, playback, trash, devices and login.

The **native engine** owns the backup pipeline end to end. It scans the phone library, hashes,
runs `/sync/check` and the tus uploads, refreshes tokens, stores credentials, runs in the
background, and frees up space. The Kotlin and Swift engines follow the same state machine
(`Discovered`, `Hashed`, `Queued`, `Uploading`, `Verifying`, `BackedUp`, `Skipped`, `Freed`,
`NeedsAttention`, `Paused`) and the same pure `decide()` function, and both are checked against
the shared vectors in `api/protocol/vectors`.

## The bridge

`mobile/pigeons/engine.dart` is the single source of the bridge. `task gen:pigeon` generates the
Dart, Kotlin and Swift sides, which are committed; the `pigeon-drift` CI job fails if they differ
from a fresh generation.

- **`EngineHostApi` (Flutter to engine, all async):** pairing (QR or manual with
  trust-on-first-use), unpair, `getAccessToken`, server info, start, pause and run now, status,
  settings, the phone item index (keyset-paged), phone thumbnails, needs-attention and retry,
  activity, free up space, undo skip, and save to gallery.
- **`EngineEventsApi` (engine to Flutter):** `onStatus`, `onItemChanged` and `onNeedsRepair`.
  Events are throttled to at most 4 flushes a second; status collapses to the latest value and
  item changes collapse to one per item.
- Each platform maps between the generated types and its engine types in one place:
  `bridge/Convert.kt` on Android, `Runner/PigeonMapping.swift` on iOS. Errors cross the bridge as
  `PlatformException` codes (`pin_mismatch`, `unreachable`, `needs_repair`, server problem codes,
  and so on).

## Ownership rules

- **Tokens have one owner, the engine.** Flutter asks for an access token with
  `getAccessToken`; the engine refreshes it first if it expires within 60 s, and single-flights
  `/auth/refresh`. Refresh-token reuse or revocation fires `onNeedsRepair`, which sends the UI
  to pairing.
- **Credentials** live in the Android Keystore (an AES-GCM-wrapped blob) and the iOS Keychain
  (`AfterFirstUnlockThisDeviceOnly`), so background work can read them while the phone is locked.
- **Pinning (P§6.3):** a chain the system trusts for the host is accepted; otherwise the leaf's
  SPKI SHA-256 must equal the pin stored at pairing. A changed certificate pauses backup with
  the `serverCertificateChanged` reason instead of burning retries.
- **Gallery writes and deletes go through the engine** (save to gallery, free up space), so the
  engine's phone index stays the one source of truth for what is on the phone.
- **Unpair** logs out best-effort, stops scheduled work, wipes the credentials and clears the
  engine database. The hash cache is kept on Android so a re-pair does not re-hash.

## Background behaviour

### Android

- `SyncWorker` (WorkManager unique work, `KEEP`) runs scan, hash, check and upload. Its
  constraints follow the settings: unmetered network for Wi-Fi only, charging for charging only.
- While uploads remain, it promotes itself to a `dataSync` foreground service with a progress
  notification. "Back up now" uses `UploadForegroundService` directly.
- `ScanWorker` runs from a content-URI trigger on MediaStore images and video, plus a 6 h
  periodic job, and requests a sync when it finds work.
- Uploads stream from the `ContentResolver`: single-shot up to the server's
  `recommended_chunk_bytes` (8 MiB by default), PATCH chunks of 8 MiB above it.

### iOS

- Uploads go through a background `URLSession` (`io.github.prithvirajg.pictunnel.upload`) with
  file bodies, so the system keeps uploading while the app is suspended. Assets are exported
  from PhotoKit into `Application Support/staging`, hashed while exporting; files up to 64 MiB
  go single-shot, larger ones in 64 MiB chunk files.
- `AppDelegate` forwards `handleEventsForBackgroundURLSession` to the engine, which applies every
  completion before calling the system's completion handler. Each task carries its item and
  upload in `taskDescription`, so a relaunched app maps completions back to items.
- `BGAppRefreshTask` (about 25 s) and `BGProcessingTask` (needs external power when charging
  only is on) schedule further runs. On iOS 26, "Back up now" uses `BGContinuedProcessingTask`.
- iOS background behaviour cannot be verified without a device. It is covered by protocol-level
  fakes and the macOS integration tests, with a device gate before release (M§10).

## Tests and CI

| Layer | Android | iOS | Flutter |
|---|---|---|---|
| Unit and vectors | JVM + Robolectric (`task test:engine:android`) | XCTest (`task test:engine:ios`) | `task test:mobile` |
| Real-server integration | JVM tests against `pictunnel serve` (needs `PICTUNNEL_BIN`, set by the task) | same scenarios; pinned TLS on macOS | - |
| Device | API 34 emulator (`task test:engine:android:instrumented`) | none | goldens on Linux, bundled fonts |

### Running the tests in Docker

The dev host does not need Flutter, Java, Android SDK or Swift. Every task above except the
instrumented one runs in Docker by default (`TOOLS_MODE=docker`):

- `ghcr.io/cirruslabs/flutter:<mobile/.flutter-version>` for Flutter, Pigeon and Gradle.
- `swift:6.2` for the iOS engine core on Linux. It cannot compile PhotoKit, background
  URLSession or the Keychain; those are compiled only on macOS. Pass `-j 1` to keep memory down.
- `golang:1.27` to build `pictunnel` for the integration tests.

Run one container at a time on a small machine; Gradle and SwiftPM each want several GB of RAM.

### CI (`.github/workflows/ci-mobile.yml`)

| Job | Runner | What |
|---|---|---|
| `flutter` | ubuntu | analyze, tests with goldens, debug and release APKs (uploaded as `pictunnel-android-debug-apk` and `pictunnel-android-release-apk`) |
| `pigeon-drift` | ubuntu | regenerate the bridge, `git diff --exit-code` |
| `engine-kotlin` | ubuntu | generated Kotlin client and vectors |
| `engine-android-unit` | ubuntu | builds the server, `:engine:testDebugUnitTest` with `PICTUNNEL_BIN` |
| `engine-android-instrumented` | ubuntu + API 34 x86_64 emulator | `:engine:connectedDebugAndroidTest`, the partial-access run (`pm revoke`/`pm grant`, then `am instrument`), and a smoke launch of the app with the real bridge (`tools/ci/android-instrumented.sh`) |
| `android-e2e` | ubuntu + API 34 x86_64 emulator | the real backup end to end: `pictunnel serve` from the commit on the runner, reached at `10.0.2.2`; pairing, a MediaStore JPEG and a sync run through the real `EngineHost` (`RealServerBackupInstrumentedTest`), then the asset checked through the server API (`tools/ci/android-e2e.sh`) |
| `engine-ios` | macos | builds the server for darwin/arm64, `swift test` for the engine (pinned TLS integration included), EngineAPI tests, `flutter build ios --debug --no-codesign` |
