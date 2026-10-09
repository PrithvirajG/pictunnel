# PicTunnel

Self-hosted photo and video backup that installs like a desktop app, backs up phones reliably in the background, and never stores the same photo twice.

> **Status: pre-alpha.** Milestone M0 is complete: API contract, sync protocol, conformance vectors and repository foundation. Next: sub-project 2 (server core).

## Repository layout

| Path | What | License |
|---|---|---|
| `api/` | OpenAPI contract, sync protocol, conformance vectors | Apache-2.0 |
| `server/` | Go server (single binary: desktop tray app and Docker image) | AGPL-3.0 |
| `mobile/` | Flutter app with native Kotlin and Swift backup engines | Apache-2.0 |
| `web/` | SvelteKit web viewer, embedded in the server | AGPL-3.0 |
| `ml/` | Optional machine-learning worker | AGPL-3.0 |
| `docs/` | Design specs, plans, ADRs | AGPL-3.0 |

## Design

- System design: [`docs/superpowers/specs/2026-10-03-pictunnel-system-design.md`](docs/superpowers/specs/2026-10-03-pictunnel-system-design.md)
- Contract and sync protocol: [`docs/superpowers/specs/2026-10-03-contract-and-sync-protocol-design.md`](docs/superpowers/specs/2026-10-03-contract-and-sync-protocol-design.md)
- Decisions: [`docs/adr/`](docs/adr/)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Every commit needs a DCO sign-off (`git commit -s`).
