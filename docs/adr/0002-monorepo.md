# 0002. Single monorepo

- Status: Accepted (2026-10-03)

## Context
The contract, server, mobile app, web viewer and ML worker change together; a protocol change touches all of them.

## Decision
Keep everything in one repository: `api/`, `server/`, `mobile/`, `web/`, `ml/`, `packaging/`, `docs/`, `tools/`. CI workflows are path-filtered per directory.

## Consequences
One pull request can change the contract, regenerate every client and update every implementation. CI must stay path-filtered so unrelated stacks do not run on every change.
