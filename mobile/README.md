# PicTunnel mobile

The PicTunnel phone app: a Flutter UI on top of two native backup engines, Kotlin for Android
and Swift for iOS. The UI browses the server library and controls backup; the engines own
scanning, hashing, uploading, credentials and free-up-space. See
[docs/mobile/architecture.md](../docs/mobile/architecture.md) for how the pieces fit together,
and the design spec `docs/superpowers/specs/2026-10-17-mobile-app-design.md` for the details.

## Layout

| Path | What |
|---|---|
| `lib/` | Flutter app: `app/` (router, theme), `core/` (API client, engine wrapper, Drift, decisions), `features/` (screens) |
| `pigeons/engine.dart` | Pigeon source of the Flutter <-> engine bridge |
| `test/` | Unit, widget, vector and golden tests |
| `android/engine/` | Android engine module (`:engine`): Room, WorkManager, OkHttp, MediaStore, Keystore |
| `android/engine-api/` | Generated Kotlin OpenAPI client (do not edit) |
| `android/app/` | Flutter host app; registers `EngineHost` in `MainActivity` |
| `ios/Engine/` | Swift package `PicTunnelEngine` (engine core, Linux-testable) and `PicTunnelPlatform` (PhotoKit, background URLSession, BGTasks, Keychain) |
| `ios/EngineAPI/` | Generated Swift OpenAPI client (do not edit) |
| `ios/Runner/` | Flutter host app; `EngineHost`, `EventsRelay`, `PigeonMapping` |
| `packages/pictunnel_api/` | Generated Dart client (do not edit) |

## Running the tests

Every task runs in Docker by default (`TOOLS_MODE=docker`), so the only local requirements
are Docker and [Task](https://taskfile.dev). Pass `TOOLS_MODE=native` to use local Flutter,
Go, Java and Swift instead.

| Command | What it runs |
|---|---|
| `task test:mobile` | `flutter analyze` and `flutter test`, goldens included |
| `task test:engine:android` | Builds `pictunnel`, then the Android engine's JVM tests (Robolectric, vectors, real-server integration) |
| `task test:engine:android:instrumented` | Instrumented tests, the partial-access run and a bridge smoke launch. Needs local Flutter and a booted API 34+ emulator on adb |
| `task test:engine:ios` | Builds `pictunnel`, then `swift test` for the iOS engine. On macOS (`TOOLS_MODE=native`) the integration tests use pinned TLS; in Docker they use Linux Swift and the loopback listener, and the iOS adapters are not compiled |
| `task test:kotlin` / `task test:swift` | The generated engine clients and their vector tests |
| `task gen:pigeon` | Regenerates the Pigeon bridge (Dart, Kotlin, Swift) |

The iOS app itself (`flutter build ios`) only builds on macOS; CI does it in the `engine-ios`
job of `.github/workflows/ci-mobile.yml`.

## Generated code

Never edit generated files by hand. Regenerate them and commit the result; CI fails on drift.

- Pigeon outputs: `lib/core/engine/pigeon.g.dart`, `android/engine/src/main/kotlin/.../engine/bridge/Pigeon.g.kt`,
  `ios/Engine/Sources/PicTunnelEngine/Bridge/Pigeon.g.swift` (`task gen:pigeon`).
- OpenAPI clients: `packages/pictunnel_api/`, `android/engine-api/generated/`,
  `ios/EngineAPI/Sources/EngineAPI/Generated/` (`task gen:dart`, `task gen:kotlin`, `task gen:swift`).
