# 0010. OpenAPI-first contract with committed generated code

- Status: Accepted (2026-10-03)

## Context
Five codebases (Go, Dart, Kotlin, Swift, TypeScript) must agree on the wire format.

## Decision
`api/openapi.yaml` (OpenAPI 3.0.3) is the single source of truth. Clients and server interfaces are generated: oapi-codegen (Go), openapi-generator dart-dio (Dart), openapi-generator kotlin (engine subset), swift-openapi-generator (engine subset), openapi-typescript (web). Generated code is committed; CI regenerates twice and fails on any diff. Response value sets that may grow are strings with `x-known-values` so generated clients tolerate new values.

## Consequences
Drift is impossible to merge. Generator upgrades are explicit commits. OpenAPI 3.0.3 is used because 3.1 support in oapi-codegen and openapi-generator is incomplete; migrating later is mechanical.
