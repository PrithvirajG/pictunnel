# 0011. Opaque tokens with rotating refresh tokens

- Status: Accepted (2026-10-03)

## Context
Devices must be revocable instantly, and a background engine and the foreground app may refresh at the same moment.

## Decision
Access tokens (`pt_at_`, 15 minutes) and refresh tokens (`pt_rt_`, 90 days since last use) are random opaque strings stored as SHA-256 hashes. Every refresh rotates the refresh token; presenting the previous token within 30 seconds returns the same successor pair, and later reuse revokes the device's whole token family.

## Consequences
Revocation is immediate and there are no signing keys to manage. Every request costs a token lookup, which an in-memory cache absorbs.
