# 0009. License split with DCO

- Status: Accepted (2026-10-03)

## Context
We want to stop closed hosted forks of the server, while app-store distribution of GPL-family apps is widely considered incompatible with store terms.

## Decision
`server/`, `web/`, `ml/` and docs are AGPL-3.0. `mobile/` and `api/` (contract, protocol, vectors, generated SDKs) are Apache-2.0. Contributions are accepted under the Developer Certificate of Origin (`git commit -s`); there is no CLA.

## Consequences
The valuable server stays protected; third-party clients can be built freely. Without a CLA, relicensing or a dual-licensed paid edition later would need every contributor's consent.
