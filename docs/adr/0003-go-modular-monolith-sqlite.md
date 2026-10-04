# 0003. Go modular monolith with embedded SQLite

- Status: Accepted (2026-10-03)

## Context
The server must ship both as a desktop tray app (no Docker) and as a Docker image for NAS users. Competing products require Postgres, Redis and several containers, which the research identifies as the main setup pain point.

## Decision
Build one Go binary containing all modules, using SQLite in WAL mode through the pure-Go `modernc.org/sqlite` driver, a table-backed job queue, and the web viewer embedded with `go:embed`. Modules communicate only through Go interfaces and never read each other's tables. ffmpeg/ffprobe ship as static binaries next to the server.

## Consequences
No external services to install and trivial cross-compilation. SQLite's single writer limits write concurrency, which is acceptable for household libraries. Modules can be split out later because their seams already exist.
