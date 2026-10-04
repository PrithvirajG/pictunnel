# 0004. Flutter UI with native backup engines

- Status: Accepted (2026-10-03)

## Context
Reliable background backup is the top user complaint. iOS gives background tasks roughly 30 seconds and only background URLSession uploads survive app suspension; starting a Flutter engine in the background is slow and fragile.

## Decision
The app UI is Flutter. The entire backup pipeline (scan, hash, check, upload) is implemented natively: Kotlin with WorkManager on Android, Swift with BGTaskScheduler and background URLSession on iOS. Flutter talks to the engines through Pigeon. Both engines must pass the shared conformance vectors.

## Consequences
The backup state machine exists twice; shared vectors keep the two in agreement. Contributors need Kotlin or Swift to work on backup. A shared Rust core remains an option if the engines drift.
