# Contributing to PicTunnel

## Developer Certificate of Origin

Every commit must carry a sign-off certifying the [Developer Certificate of Origin](https://developercertificate.org/):

    git commit -s -m "your message"

This adds `Signed-off-by: Your Name <you@example.com>`. CI rejects pull requests with unsigned commits. There is no CLA.

## Toolchain

Install natively: Go (latest stable), Node 24 with pnpm 10, uv, Docker, and Task (https://taskfile.dev).
Everything else (openapi-generator, JDK/Gradle, Swift, Flutter, Dart) runs in pinned Docker images.
Linux contributors who prefer native Flutter/JDK/Swift can run any task with `TOOLS_MODE=native`.

    task doctor        # check local tools
    task gen           # regenerate all clients from api/openapi.yaml
    task lint          # contract lint + line-ending check
    task test          # every test suite
    task ci            # everything CI runs

## Rules

- `api/openapi.yaml` is the source of truth. Never edit generated code; change the contract and run `task gen`.
- Changes inside `/api/v1` must be additive. CI runs a breaking-change check on pull requests.
- Protocol behavior changes must update `api/protocol/sync-protocol.md` and the conformance vectors in the same pull request.
- Architecture decisions are recorded in `docs/adr/`.
