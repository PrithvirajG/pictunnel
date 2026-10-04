# 0006. tus 1.0 for resumable uploads

- Status: Accepted (2026-10-03)

## Context
Uploads must resume after drops and app kills, and iOS background sessions upload whole files from disk in a single request.

## Decision
Use the tus 1.0.0 protocol with the creation, creation-with-upload, termination, expiration and checksum extensions, served by `tusd` v2 behind our auth. Upload creation is idempotent per `(owner, sha256)`, and the server verifies the full-file hash before committing.

## Consequences
Standard client libraries exist for JavaScript, Kotlin and Swift. tus semantics live in the protocol document and vectors because OpenAPI cannot express them fully.
