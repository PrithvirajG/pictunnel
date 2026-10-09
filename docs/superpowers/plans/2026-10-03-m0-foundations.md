# M0 Foundations — Contract, Sync Protocol & Repository Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the PicTunnel monorepo with a linted OpenAPI 3.0.3 contract, the normative sync-protocol document, executable conformance vectors, committed code generation for Go/Dart/Kotlin/Swift/TypeScript, cross-language hashing runners, and green CI for every stack.

**Architecture:** `api/` is the single source of truth (OpenAPI + protocol doc + vectors). A root `Taskfile.yml` drives everything; heavy toolchains (openapi-generator, JDK/Gradle, Swift, Flutter, Dart) run in pinned Docker images locally and natively in CI (`TOOLS_MODE=native`). Generated code is committed and CI fails on drift.

**Tech Stack:** OpenAPI 3.0.3 · Redocly CLI · Node 24 + pnpm 10 (tooling, SvelteKit) · Go (oapi-codegen) · openapi-generator v7.24.0 (Dart dio, Kotlin) · swift-openapi-generator 1.13.0 on Swift 6.2 · Kotlin 2.3.20 / Gradle 9.3.0 / JDK 17 · Flutter stable · uv (Python ≥3.12) · Task · GitHub Actions.

**Spec:** [`docs/superpowers/specs/2026-10-03-contract-and-sync-protocol-design.md`](../specs/2026-10-03-contract-and-sync-protocol-design.md) (parent: [`2026-10-03-pictunnel-system-design.md`](../specs/2026-10-03-pictunnel-system-design.md)). Read both before starting any task.

## Global Constraints

- Contract is **OpenAPI 3.0.3**, base path `/api/v1` (health at `/healthz`, `/readyz`), JSON `snake_case`, errors are `application/problem+json` with `type: urn:pictunnel:problem:<code>`.
- Response fields whose value set may grow are `type: string` with `x-known-values`; only request-only fields may use `enum`. Never put sibling keys next to `$ref` (OpenAPI 3.0).
- Identifiers: Go module `github.com/PrithvirajG/pictunnel/server`; Android applicationId and iOS bundle id `io.github.prithvirajg.pictunnel`; Kotlin package `io.github.prithvirajg.pictunnel.engineapi`; Dart package `pictunnel_api`; Docker image `ghcr.io/prithvirajg/pictunnel`.
- Licenses: root `LICENSE` AGPL-3.0 (covers `server/`, `web/`, `ml/`); `api/LICENSE` and `mobile/LICENSE` Apache-2.0.
- Every commit: `git commit -s` (DCO sign-off only; no AI attribution trailers).
- All text files LF (`.gitattributes`); `.bat/.cmd/.ps1` CRLF.
- Generated directories are never edited by hand: `server/internal/httpapi/gen/`, `web/src/lib/api/schema.d.ts`, `mobile/packages/pictunnel_api/`, `mobile/android/engine-api/generated/`, `mobile/ios/EngineAPI/Sources/EngineAPI/Generated/`. Fix the contract and regenerate.
- Pinned images (Taskfile vars): `openapitools/openapi-generator-cli:v7.24.0`, `gradle:9.3.0-jdk17`, `swift:6.2`, `ghcr.io/cirruslabs/flutter:<mobile/.flutter-version>`, `dart:<pinned in Task 19>`.
- Engine operation set (exact): `getServerInfo, refreshTokens, checkContent, optionsUploads, createUpload, getUploadOffset, appendUpload, terminateUpload, deleteTombstone`.
- Vector minimum case counts: hashing ≥ 8, server-scenario ≥ 14, client-decision ≥ 25, pairing ≥ 8.
- Payload constants used across vectors (counter pattern: byte *i* = (*i* + seed) mod 256):

| Name | seed | length | sha256 |
|---|---|---|---|
| A | 0 | 1048576 | `fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83` |
| B | 1 | 1048576 | `18af9b054114c04a1eb836533a3e760dfa9dc53934ecb02fc059ff27150e77fb` |
| C | 0 | 3145728 | `f6dd7fec8584ad00219a447071c1fa368a1caee4d9c146083d233713ddccd2c0` |
| V | 2 | 1048576 | `c11788fa01aebe9ddeadf2d6fd661693d75a0ca28dc957a6042b5ff6d8a08e66` |

## Review Focus

1. **CRLF on the Windows dev machine** — generated files or scripts committed with CRLF make the CI drift check fail on Linux. Expect: `.gitattributes` normalizes, and `task check:eol` fails on any CRLF text file. Pinned by the `crlfViolations` tests in Task 2.
2. **Generator nondeterminism** — timestamps or unordered output in generated code make the drift check flap. Expect: running `task gen` twice yields no diff. Pinned by the double-run step in Task 22 (`ci-api` codegen job) and the local check in Task 23.
3. **Engine subset silently drifting** — someone retags an operation and the Kotlin/Swift engines lose `refreshTokens` or gain admin calls. Expect: bundle check fails unless the operation set equals the Global Constraints list exactly. Pinned by `engineOperationIds` tests in Task 17.
4. **Root-owned files from Docker on Linux CI** — generators running as root leave files the runner cannot rewrite. Expect: Docker runs with the caller's uid/gid on non-Windows hosts. Pinned by the ownership check step in Task 22.
5. **Unicode and case-only filename collisions** — `Photo 🙂.JPG` vs `photo 🙂.jpg` on case-insensitive filesystems. Expect: both stored, second gets `~2`, original names preserved in UTF-8 through tus metadata. Pinned by server-scenario `unicode_and_case_collision_paths` in Task 12 (executed by sub-project 2).

## File Map

```
.gitattributes .editorconfig .gitignore LICENSE README.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md
.github/{ISSUE_TEMPLATE/*,PULL_REQUEST_TEMPLATE.md,workflows/*.yml}
Taskfile.yml
tools/ci/{check-eol.mjs,check-dco.mjs,*.test.mjs}      # repo checks (Node, portable)
tools/dev/{rmrf.mjs,docker-user.mjs,read-version.mjs}  # Taskfile helpers
docs/adr/0001…0011-*.md
api/{LICENSE,package.json,redocly.yaml,openapi.yaml}
api/tools/{contract-rules.mjs,check-engine-bundle.mjs,validate-vectors.mjs,make_fixtures.py,*.test.mjs}
api/protocol/{sync-protocol.md,fixtures/*,vectors/{vectors.schema.json,hashing,pairing,server-scenarios,client-decisions}/*.json}
server/{go.mod,cmd/pictunnel/{main.go,main_test.go}}
server/internal/contenthash/{contenthash.go,contenthash_test.go}
server/internal/conformance/{vectors.go,generate.go,generate_test.go,hashing_test.go}
server/internal/httpapi/{oapi-codegen.yaml,gen/api.gen.go,contract_test.go}
web/{package.json,svelte.config.js,vite.config.ts,tsconfig.json,src/...}
mobile/{LICENSE,.flutter-version,pubspec.yaml,lib/,test/,android/,ios/}
mobile/packages/pictunnel_api/                         # generated Dart package
mobile/android/engine-api/{settings.gradle.kts,build.gradle.kts,gradlew*,generated/,src/}
mobile/ios/EngineAPI/{Package.swift,openapi-generator-config.yaml,Sources/EngineAPI/{ContentHash.swift,Generated/},Tests/}
ml/{pyproject.toml,.python-version,src/pictunnel_ml/__init__.py,tests/test_version.py}
```

## Execution Order and Parallel Lanes

```
T1 → T2 ─┬─ T3 (ADRs)                         [parallel with everything after T2]
         ├─ T4 → T5 → T6 → T7 → T8 ─┬─ T15 (Go codegen)      ─┐
         │                          ├─ T16 (web + TS)          │
         │                          ├─ T17 (bundle + Kotlin) → T18 (Swift)
         │                          ├─ T19 (Dart + Flutter)    │
         │                          └─ T21 (protocol doc) ←T13,T17
         ├─ T9 → T10 → T14 (Go runner) ──────────────────────┤
         │         ├─ T11, T12, T13 (vectors)                 │
         └─ T20 (ml)                                          │
                                         T22 (CI) → T23 (verify + publish)
```
Tasks in the same lane must run in order; different lanes may run in parallel once their prerequisites are committed.

---

### Task 1: Repository hygiene, licenses and contributor docs

**Files:**
- Create: `.gitattributes`, `.editorconfig`, `.gitignore`, `LICENSE`, `api/LICENSE`, `mobile/LICENSE`, `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, `.github/ISSUE_TEMPLATE/bug_report.md`, `.github/ISSUE_TEMPLATE/feature_request.md`, `.github/PULL_REQUEST_TEMPLATE.md`

**Interfaces:**
- Consumes: nothing (repo already initialized on `main`, one commit `fc10ac2`).
- Produces: line-ending policy relied on by every later task; license layout.

- [ ] **Step 1: Create `.gitattributes`**

```gitattributes
* text=auto eol=lf
*.bat text eol=crlf
*.cmd text eol=crlf
*.ps1 text eol=crlf
*.png binary
*.jpg binary
*.jpeg binary
*.heic binary
*.mp4 binary
*.jar binary
server/internal/httpapi/gen/** linguist-generated=true
web/src/lib/api/schema.d.ts linguist-generated=true
mobile/packages/pictunnel_api/** linguist-generated=true
mobile/android/engine-api/generated/** linguist-generated=true
mobile/ios/EngineAPI/Sources/EngineAPI/Generated/** linguist-generated=true
```

- [ ] **Step 2: Create `.editorconfig`**

```ini
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
indent_style = space
indent_size = 2
trim_trailing_whitespace = true

[*.go]
indent_style = tab

[*.{kt,kts,swift,py}]
indent_size = 4

[*.{bat,cmd,ps1}]
end_of_line = crlf

[*.md]
trim_trailing_whitespace = false
```

- [ ] **Step 3: Create `.gitignore`**

```gitignore
# OS / editors
.DS_Store
Thumbs.db
.idea/
.vscode/
*.iml

# Tooling caches
.cache/
.task/
node_modules/
api/build/

# Go
server/bin/
server/dist/

# Web
web/.svelte-kit/
web/build/

# Kotlin / Gradle
.gradle/
**/build/

# Swift
.build/
.swiftpm/

# Python
.venv/
__pycache__/
*.pyc
.pytest_cache/
.ruff_cache/

# Dart / Flutter (flutter create adds mobile/.gitignore for the rest)
.dart_tool/
```

- [ ] **Step 4: Download license texts and Code of Conduct**

```bash
curl -sSfL https://www.gnu.org/licenses/agpl-3.0.txt -o LICENSE
mkdir -p api mobile
curl -sSfL https://www.apache.org/licenses/LICENSE-2.0.txt -o api/LICENSE
cp api/LICENSE mobile/LICENSE
curl -sSfL https://www.contributor-covenant.org/version/2/1/code_of_conduct/code_of_conduct.md -o CODE_OF_CONDUCT.md
```
Then replace the placeholder `[INSERT CONTACT METHOD]` in `CODE_OF_CONDUCT.md` with:
`the project maintainer, @PrithvirajG on GitHub (https://github.com/PrithvirajG)`.

Verify: `head -3 LICENSE` shows `GNU AFFERO GENERAL PUBLIC LICENSE`; `head -3 api/LICENSE` shows `Apache License`; `grep -c "INSERT CONTACT" CODE_OF_CONDUCT.md` prints `0`.

- [ ] **Step 5: Create `README.md`**

```markdown
# PicTunnel

Self-hosted photo and video backup that installs like a desktop app, backs up phones reliably in the background, and never stores the same photo twice.

> **Status: pre-alpha.** Nothing is usable yet. Milestone M0 (contract, sync protocol, repository foundation) is in progress.

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
```

- [ ] **Step 6: Create `CONTRIBUTING.md`**

```markdown
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
```

- [ ] **Step 7: Create `SECURITY.md`**

```markdown
# Security Policy

PicTunnel is pre-alpha and has no supported releases yet.

Please report vulnerabilities privately through GitHub's private vulnerability reporting
("Security" tab → "Report a vulnerability") on this repository. Do not open public issues for security problems.

We aim to acknowledge reports within 7 days.
```

- [ ] **Step 8: Create issue and PR templates**

`.github/ISSUE_TEMPLATE/bug_report.md`:
```markdown
---
name: Bug report
about: Something does not work as described
labels: bug
---

**What happened**

**What you expected**

**Steps to reproduce**

**Versions** (server, app, OS, phone model)
```

`.github/ISSUE_TEMPLATE/feature_request.md`:
```markdown
---
name: Feature request
about: Suggest an improvement
labels: enhancement
---

**Problem you want solved**

**Proposed behavior**

**Alternatives considered**
```

`.github/PULL_REQUEST_TEMPLATE.md`:
```markdown
## What and why

## Checklist
- [ ] Commits are signed off (`git commit -s`)
- [ ] `task ci` passes locally (or the relevant subset)
- [ ] Contract changes are additive and `task gen` output is committed
- [ ] Protocol behavior changes update `api/protocol/sync-protocol.md` and vectors
```

- [ ] **Step 9: Renormalize existing files and verify line endings**

```bash
git add --renormalize .
git add -A
git ls-files --eol | grep -v "i/lf" | grep -v "i/none" || echo "all LF"
```
Expected: `all LF` (binary/none entries filtered).

- [ ] **Step 10: Commit**

```bash
git commit -s -m "chore: add repository hygiene, licenses and contributor docs"
```

---

### Task 2: Toolchain, Taskfile base and repo check scripts

**Files:**
- Create: `Taskfile.yml`, `tools/dev/rmrf.mjs`, `tools/dev/docker-user.mjs`, `tools/dev/read-version.mjs`, `tools/ci/check-eol.mjs`, `tools/ci/check-eol.test.mjs`, `tools/ci/check-dco.mjs`, `tools/ci/check-dco.test.mjs`

**Interfaces:**
- Consumes: Task 1 `.gitattributes`.
- Produces: Taskfile vars `TOOLS_MODE`, `DOCKER_RUN`, `OPENAPI_GENERATOR_IMAGE`, `GRADLE_IMAGE`, `SWIFT_IMAGE`, `SWIFT_OPENAPI_GENERATOR_VERSION`, `FLUTTER_VERSION`, `DART_IMAGE`; tasks `doctor`, `check:eol`, `test:tools`. Later tasks **append** their tasks to the end of `Taskfile.yml` (the `tasks:` map is the last key). Exported functions `crlfViolations(eolOutput: string): string[]` and `missingSignoff(commits: {sha: string, body: string}[]): string[]`.

- [ ] **Step 1: Install local tools (Windows)**

```powershell
winget install --id GoLang.Go -e --accept-source-agreements --accept-package-agreements
winget install --id Task.Task -e --accept-source-agreements --accept-package-agreements
npm install -g pnpm@10
```
Open a new shell, then verify: `go version` (must be ≥ go1.25), `task --version`, `pnpm --version` (10.x), `uv --version`, `docker version`.

- [ ] **Step 2: Write the failing tests for the repo checks**

`tools/ci/check-eol.test.mjs`:
```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { crlfViolations } from "./check-eol.mjs";

test("accepts LF text files and binaries", () => {
  const out = "i/lf    w/lf    attr/text=auto eol=lf \tREADME.md\0i/-text w/-text attr/binary \tfixtures/a.jpg\0";
  assert.deepEqual(crlfViolations(out), []);
});

test("flags CRLF text files in the index", () => {
  const out = "i/crlf  w/crlf  attr/text=auto eol=lf \tserver/main.go\0";
  assert.deepEqual(crlfViolations(out), ["server/main.go"]);
});

test("allows CRLF for Windows scripts", () => {
  const out = "i/crlf  w/crlf  attr/text eol=crlf    \tmobile/android/engine-api/gradlew.bat\0";
  assert.deepEqual(crlfViolations(out), []);
});

test("flags mixed line endings", () => {
  const out = "i/mixed w/mixed attr/                 \tnotes.txt\0";
  assert.deepEqual(crlfViolations(out), ["notes.txt"]);
});
```

`tools/ci/check-dco.test.mjs`:
```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { missingSignoff } from "./check-dco.mjs";

test("passes signed-off commits", () => {
  const commits = [{ sha: "a1", body: "feat: x\n\nSigned-off-by: Jane Doe <jane@example.com>\n" }];
  assert.deepEqual(missingSignoff(commits), []);
});

test("reports commits without sign-off", () => {
  const commits = [
    { sha: "a1", body: "feat: x\n\nSigned-off-by: Jane Doe <jane@example.com>" },
    { sha: "b2", body: "fix: y\n\nCo-Authored-By: Someone <s@example.com>" },
  ];
  assert.deepEqual(missingSignoff(commits), ["b2"]);
});

test("rejects a sign-off without an email", () => {
  assert.deepEqual(missingSignoff([{ sha: "c3", body: "x\n\nSigned-off-by: Jane" }]), ["c3"]);
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `node --test "tools/ci/*.test.mjs"`
Expected: FAIL — `Cannot find module '.../check-eol.mjs'`.

- [ ] **Step 4: Implement the checks**

`tools/ci/check-eol.mjs`:
```js
// Fails when a text file is stored in the git index with CRLF or mixed line endings.
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const WINDOWS_SCRIPT = /\.(bat|cmd|ps1)$/i;

export function crlfViolations(eolOutput) {
  const bad = [];
  for (const entry of eolOutput.split("\0")) {
    if (!entry.trim()) continue;
    const tab = entry.indexOf("\t");
    const meta = entry.slice(0, tab);
    const path = entry.slice(tab + 1);
    const index = meta.trim().split(/\s+/)[0];
    if ((index === "i/crlf" || index === "i/mixed") && !WINDOWS_SCRIPT.test(path)) bad.push(path);
  }
  return bad;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const out = execFileSync("git", ["ls-files", "--eol", "-z"], { encoding: "utf8" });
  const bad = crlfViolations(out);
  if (bad.length) {
    console.error("Files with CRLF/mixed line endings in the index:\n" + bad.join("\n"));
    process.exit(1);
  }
  console.log("eol: ok");
}
```

`tools/ci/check-dco.mjs`:
```js
// Usage: node tools/ci/check-dco.mjs <base-ref> <head-ref>
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const SIGNOFF = /^Signed-off-by: .+ <[^<>\s]+@[^<>\s]+>\s*$/m;

export function missingSignoff(commits) {
  return commits.filter((c) => !SIGNOFF.test(c.body)).map((c) => c.sha);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [base, head] = process.argv.slice(2);
  if (!base || !head) {
    console.error("usage: check-dco.mjs <base> <head>");
    process.exit(2);
  }
  const raw = execFileSync("git", ["log", "--no-merges", "--format=%H%x00%B%x1e", `${base}..${head}`], { encoding: "utf8" });
  const commits = raw.split("\x1e").map((r) => r.trim()).filter(Boolean).map((r) => {
    const [sha, body] = r.split("\0");
    return { sha, body };
  });
  const bad = missingSignoff(commits);
  if (bad.length) {
    console.error("Commits missing a DCO sign-off (use git commit -s):\n" + bad.join("\n"));
    process.exit(1);
  }
  console.log(`dco: ${commits.length} commit(s) signed off`);
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `node --test "tools/ci/*.test.mjs"`
Expected: PASS, 7 tests.

- [ ] **Step 6: Create Taskfile helpers**

`tools/dev/rmrf.mjs`:
```js
// Portable `rm -rf` for Taskfile commands: node tools/dev/rmrf.mjs <path>...
import { rmSync } from "node:fs";
for (const p of process.argv.slice(2)) rmSync(p, { recursive: true, force: true });
```

`tools/dev/docker-user.mjs`:
```js
// Prints `--user uid:gid` on Linux/macOS so containers do not create root-owned files; nothing on Windows.
process.stdout.write(process.platform === "win32" ? "" : `--user ${process.getuid()}:${process.getgid()}`);
```

`tools/dev/read-version.mjs`:
```js
// Prints the trimmed contents of a version file, or a fallback when it does not exist yet.
import { readFileSync } from "node:fs";
const [file, fallback = ""] = process.argv.slice(2);
try {
  process.stdout.write(readFileSync(file, "utf8").trim());
} catch {
  process.stdout.write(fallback);
}
```

- [ ] **Step 7: Create `Taskfile.yml`**

```yaml
version: "3"

vars:
  TOOLS_MODE: '{{.TOOLS_MODE | default "docker"}}'
  OPENAPI_GENERATOR_IMAGE: openapitools/openapi-generator-cli:v7.24.0
  GRADLE_IMAGE: gradle:9.3.0-jdk17
  SWIFT_IMAGE: swift:6.2
  SWIFT_OPENAPI_GENERATOR_VERSION: 1.13.0
  FLUTTER_VERSION:
    sh: node tools/dev/read-version.mjs mobile/.flutter-version stable
  DART_IMAGE:
    sh: node tools/dev/read-version.mjs tools/dev/dart-image.txt dart:stable
  DOCKER_USER:
    sh: node tools/dev/docker-user.mjs
  DOCKER_RUN: docker run --rm {{.DOCKER_USER}} -e HOME=/tmp -v "{{.ROOT_DIR}}:/repo" -w /repo

tasks:
  doctor:
    desc: Verify required local tools are installed
    cmds:
      - go version
      - node --version
      - pnpm --version
      - uv --version
      - docker version

  check:eol:
    desc: Fail if a text file is committed with CRLF line endings
    cmds:
      - node tools/ci/check-eol.mjs

  test:tools:
    desc: Tests for repository check scripts
    cmds:
      - node --test "tools/ci/*.test.mjs"
```

- [ ] **Step 8: Verify the Taskfile**

Run: `task doctor` → prints all five tool versions, exit 0.
Run: `task test:tools` → 7 passing tests.
Run: `git add -A && task check:eol` → `eol: ok`.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -s -m "build: add Taskfile, Docker helpers and repo check scripts"
```

---

### Task 3: Architecture Decision Records 0001–0011

**Files:**
- Create: `docs/adr/0001-record-architecture-decisions.md` … `docs/adr/0011-opaque-tokens-rotating-refresh.md` (contents below)

**Interfaces:**
- Consumes: the two specs.
- Produces: ADR numbers referenced by the spec (§13) and the protocol doc.

Each ADR uses this exact structure: title line, `- Status: Accepted (2026-10-03)`, then `## Context`, `## Decision`, `## Consequences`.

- [ ] **Step 1: Write ADR 0001**

`docs/adr/0001-record-architecture-decisions.md`:
```markdown
# 0001. Record architecture decisions

- Status: Accepted (2026-10-03)

## Context
PicTunnel is built by a solo maintainer with AI assistance and is meant to attract contributors. Decisions made in chat are lost unless written down.

## Decision
Record each significant architecture decision as a short Markdown ADR in `docs/adr/`, numbered sequentially, never renumbered. Superseded ADRs stay and link to their replacement.

## Consequences
New contributors can learn why things are the way they are. Changing a recorded decision requires a new ADR.
```

- [ ] **Step 2: Write ADR 0002**

`docs/adr/0002-monorepo.md`:
```markdown
# 0002. Single monorepo

- Status: Accepted (2026-10-03)

## Context
The contract, server, mobile app, web viewer and ML worker change together; a protocol change touches all of them.

## Decision
Keep everything in one repository: `api/`, `server/`, `mobile/`, `web/`, `ml/`, `packaging/`, `docs/`, `tools/`. CI workflows are path-filtered per directory.

## Consequences
One pull request can change the contract, regenerate every client and update every implementation. CI must stay path-filtered so unrelated stacks do not run on every change.
```

- [ ] **Step 3: Write ADR 0003**

`docs/adr/0003-go-modular-monolith-sqlite.md`:
```markdown
# 0003. Go modular monolith with embedded SQLite

- Status: Accepted (2026-10-03)

## Context
The server must ship both as a desktop tray app (no Docker) and as a Docker image for NAS users. Competing products require Postgres, Redis and several containers, which the research identifies as the main setup pain point.

## Decision
Build one Go binary containing all modules, using SQLite in WAL mode through the pure-Go `modernc.org/sqlite` driver, a table-backed job queue, and the web viewer embedded with `go:embed`. Modules communicate only through Go interfaces and never read each other's tables. ffmpeg/ffprobe ship as static binaries next to the server.

## Consequences
No external services to install and trivial cross-compilation. SQLite's single writer limits write concurrency, which is acceptable for household libraries. Modules can be split out later because their seams already exist.
```

- [ ] **Step 4: Write ADR 0004**

`docs/adr/0004-flutter-ui-native-backup-engines.md`:
```markdown
# 0004. Flutter UI with native backup engines

- Status: Accepted (2026-10-03)

## Context
Reliable background backup is the top user complaint. iOS gives background tasks roughly 30 seconds and only background URLSession uploads survive app suspension; starting a Flutter engine in the background is slow and fragile.

## Decision
The app UI is Flutter. The entire backup pipeline (scan, hash, check, upload) is implemented natively: Kotlin with WorkManager on Android, Swift with BGTaskScheduler and background URLSession on iOS. Flutter talks to the engines through Pigeon. Both engines must pass the shared conformance vectors.

## Consequences
The backup state machine exists twice; shared vectors keep the two in agreement. Contributors need Kotlin or Swift to work on backup. A shared Rust core remains an option if the engines drift.
```

- [ ] **Step 5: Write ADR 0005**

`docs/adr/0005-sha256-content-identity.md`:
```markdown
# 0005. SHA-256 content identity with per-user dedup

- Status: Accepted (2026-10-03)

## Context
Users must never get duplicates from retries, reinstalls or second phones, and the server must not leak whether another user owns a file.

## Decision
An asset's identity is the SHA-256 of its original bytes, lowercase hex. The database enforces `UNIQUE(owner_id, sha256)`. The check endpoint only reports on the caller's own content. Edited renditions are separate assets grouped in a stack.

## Consequences
Dedup is exact and cheap to verify on every platform with hardware-accelerated SHA-256. Identical files owned by two users are stored twice; this is the price of not leaking existence across accounts.
```

- [ ] **Step 6: Write ADR 0006**

`docs/adr/0006-tus-resumable-uploads.md`:
```markdown
# 0006. tus 1.0 for resumable uploads

- Status: Accepted (2026-10-03)

## Context
Uploads must resume after drops and app kills, and iOS background sessions upload whole files from disk in a single request.

## Decision
Use the tus 1.0.0 protocol with the creation, creation-with-upload, termination, expiration and checksum extensions, served by `tusd` v2 behind our auth. Upload creation is idempotent per `(owner, sha256)`, and the server verifies the full-file hash before committing.

## Consequences
Standard client libraries exist for JavaScript, Kotlin and Swift. tus semantics live in the protocol document and vectors because OpenAPI cannot express them fully.
```

- [ ] **Step 7: Write ADR 0007**

`docs/adr/0007-readable-library-layout.md`:
```markdown
# 0007. Human-readable library layout

- Status: Accepted (2026-10-03)

## Context
Self-hosters distrust opaque storage; competitors added readable "storage templates" after user demand.

## Decision
Store originals at `<library>/<user>/<YYYY>/<MM>/<filename>`. The path is fixed at ingest and never moved. Collisions are detected case-insensitively after NFC normalization and resolved with `~2`, `~3`. The library is documented as read-only from outside; a weekly fsck reports drift and `import_library` can rebuild the catalog.

## Consequences
No lock-in: photos are plain files. Path sanitization and collision handling need careful tests. End-to-end encryption, if ever added, will need a different layout.
```

- [ ] **Step 8: Write ADR 0008**

`docs/adr/0008-one-way-backup-trash-tombstones.md`:
```markdown
# 0008. One-way backup with trash and tombstones

- Status: Accepted (2026-10-03)

## Context
Two-way sync lets a phone mishap delete the backup. Pure append-only storage gives users no way to remove things.

## Decision
Phone deletions never propagate. Server deletions move assets to a 30-day Trash. Purging an asset records a tombstone `(owner_id, sha256)` so phones do not upload it again unless the user chooses "back up again". "Free up space" on the phone is opt-in and requires a fresh on-disk confirmation from the server.

## Consequences
The server is a safe archive. Tombstones must be visible and reversible so users are not confused when a photo stops backing up.
```

- [ ] **Step 9: Write ADR 0009**

`docs/adr/0009-license-split-dco.md`:
```markdown
# 0009. License split with DCO

- Status: Accepted (2026-10-03)

## Context
We want to stop closed hosted forks of the server, while app-store distribution of GPL-family apps is widely considered incompatible with store terms.

## Decision
`server/`, `web/`, `ml/` and docs are AGPL-3.0. `mobile/` and `api/` (contract, protocol, vectors, generated SDKs) are Apache-2.0. Contributions are accepted under the Developer Certificate of Origin (`git commit -s`); there is no CLA.

## Consequences
The valuable server stays protected; third-party clients can be built freely. Without a CLA, relicensing or a dual-licensed paid edition later would need every contributor's consent.
```

- [ ] **Step 10: Write ADR 0010**

`docs/adr/0010-openapi-first-committed-codegen.md`:
```markdown
# 0010. OpenAPI-first contract with committed generated code

- Status: Accepted (2026-10-03)

## Context
Five codebases (Go, Dart, Kotlin, Swift, TypeScript) must agree on the wire format.

## Decision
`api/openapi.yaml` (OpenAPI 3.0.3) is the single source of truth. Clients and server interfaces are generated: oapi-codegen (Go), openapi-generator dart-dio (Dart), openapi-generator kotlin (engine subset), swift-openapi-generator (engine subset), openapi-typescript (web). Generated code is committed; CI regenerates twice and fails on any diff. Response value sets that may grow are strings with `x-known-values` so generated clients tolerate new values.

## Consequences
Drift is impossible to merge. Generator upgrades are explicit commits. OpenAPI 3.0.3 is used because 3.1 support in oapi-codegen and openapi-generator is incomplete; migrating later is mechanical.
```

- [ ] **Step 11: Write ADR 0011**

`docs/adr/0011-opaque-tokens-rotating-refresh.md`:
```markdown
# 0011. Opaque tokens with rotating refresh tokens

- Status: Accepted (2026-10-03)

## Context
Devices must be revocable instantly, and a background engine and the foreground app may refresh at the same moment.

## Decision
Access tokens (`pt_at_`, 15 minutes) and refresh tokens (`pt_rt_`, 90 days since last use) are random opaque strings stored as SHA-256 hashes. Every refresh rotates the refresh token; presenting the previous token within 30 seconds returns the same successor pair, and later reuse revokes the device's whole token family.

## Consequences
Revocation is immediate and there are no signing keys to manage. Every request costs a token lookup, which an in-memory cache absorbs.
```

- [ ] **Step 12: Verify and commit**

Run: `ls docs/adr | wc -l` → `11`.
```bash
git add docs/adr
git commit -s -m "docs: add ADRs 0001-0011"
```

---

### Task 4: API tooling and project contract rules

**Files:**
- Create: `api/package.json` (via pnpm), `api/redocly.yaml`, `api/tools/contract-rules.mjs`, `api/tools/contract-rules.test.mjs`
- Modify: `Taskfile.yml` (append tasks)

**Interfaces:**
- Consumes: Task 2 Taskfile.
- Produces: `checkContract(doc: object): string[]` (errors; empty means valid); pnpm scripts `lint`, `bundle:engine`, `vectors`, `test`; Redocly API aliases `pictunnel@v1` and `engine@v1`; tasks `api:install`, `lint:api`, `test:api`.

- [ ] **Step 1: Create the tooling package**

```bash
mkdir -p api/tools
cd api
pnpm init
pnpm add -D @redocly/cli yaml ajv ajv-formats
cd ..
```
Then edit `api/package.json`: set `"name": "pictunnel-api-tooling"`, add `"private": true` and `"type": "module"`, and replace the `scripts` object with the block below. Leave the `devDependencies` object exactly as pnpm wrote it.
```json
"scripts": {
  "lint": "redocly lint pictunnel@v1 && node tools/contract-rules.mjs openapi.yaml",
  "bundle:engine": "redocly bundle engine@v1 --remove-unused-components -o build/engine-openapi.yaml && node tools/check-engine-bundle.mjs build/engine-openapi.yaml",
  "vectors": "node tools/validate-vectors.mjs",
  "test": "node --test \"tools/*.test.mjs\""
}
```
Note: the `lint` script needs `openapi.yaml` (Task 5) and `bundle:engine` needs `check-engine-bundle.mjs` (Task 17); only `test` is used in this task.

- [ ] **Step 2: Create `api/redocly.yaml`**

```yaml
apis:
  pictunnel@v1:
    root: openapi.yaml
  engine@v1:
    root: openapi.yaml
    decorators:
      filter-in:
        property: tags
        value: engine
        matchStrategy: any
extends:
  - recommended
rules:
  operation-operationId: error
  operation-summary: error
  operation-tag-defined: error
  security-defined: error
```

- [ ] **Step 3: Write the failing tests**

`api/tools/contract-rules.test.mjs`:
```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkContract } from "./contract-rules.mjs";

const problem = {
  description: "error",
  content: { "application/problem+json": { schema: { $ref: "#/components/schemas/Problem" } } },
};
const P = "/api/v1/things/{thing_id}";

function validDoc() {
  return {
    openapi: "3.0.3",
    info: { title: "t", version: "1" },
    paths: {
      [P]: {
        get: {
          operationId: "getThing",
          tags: ["assets"],
          parameters: [
            { name: "thing_id", in: "path", required: true, schema: { type: "string" } },
            { name: "page_token", in: "query", schema: { type: "string" } },
            { name: "Upload-Offset", in: "header", schema: { type: "integer" } },
          ],
          responses: {
            "200": { description: "ok", content: { "application/json": { schema: { $ref: "#/components/schemas/Thing" } } } },
            "404": { $ref: "#/components/responses/NotFound" },
          },
        },
        head: { operationId: "headThing", tags: ["assets"], responses: { "200": { description: "ok" }, "404": { description: "missing" } } },
      },
    },
    components: {
      schemas: {
        Problem: { type: "object", properties: { code: { type: "string" }, request_id: { type: "string" } } },
        Thing: {
          type: "object",
          properties: { size_bytes: { type: "integer" }, live_video: { type: "object", properties: { sha256: { type: "string" } } } },
        },
      },
      responses: { NotFound: problem },
    },
  };
}

test("a valid contract has no errors", () => {
  assert.deepEqual(checkContract(validDoc()), []);
});

test("rejects OpenAPI versions other than 3.0.3", () => {
  const doc = validDoc();
  doc.openapi = "3.1.0";
  assert.match(checkContract(doc).join("\n"), /must be "3\.0\.3"/);
});

test("rejects camelCase schema properties, including nested ones", () => {
  const doc = validDoc();
  doc.components.schemas.Thing.properties.live_video.properties.pairSha = { type: "string" };
  assert.match(checkContract(doc).join("\n"), /"pairSha" is not snake_case/);
});

test("rejects camelCase inline request body properties", () => {
  const doc = validDoc();
  doc.paths[P].post = {
    operationId: "postThing",
    tags: ["assets"],
    requestBody: { content: { "application/json": { schema: { type: "object", properties: { assetIds: { type: "array" } } } } } },
    responses: { "400": { $ref: "#/components/responses/NotFound" } },
  };
  assert.match(checkContract(doc).join("\n"), /"assetIds" is not snake_case/);
});

test("rejects camelCase query parameters but allows HTTP header names", () => {
  const doc = validDoc();
  doc.paths[P].get.parameters.push({ name: "pageToken", in: "query", schema: { type: "string" } });
  const errors = checkContract(doc);
  assert.equal(errors.length, 1);
  assert.match(errors[0], /parameter "pageToken"/);
});

test("requires a problem+json error response except on HEAD and OPTIONS", () => {
  const doc = validDoc();
  doc.paths[P].get.responses = { "200": { description: "ok" } };
  assert.match(checkContract(doc).join("\n"), /GET \/api\/v1\/things\/\{thing_id\}: no 4xx\/5xx application\/problem\+json response/);
});

test("rejects paths outside /api/v1 except health probes", () => {
  const doc = validDoc();
  doc.paths["/healthz"] = { get: { operationId: "getHealthz", tags: ["server"], responses: { "503": { $ref: "#/components/responses/NotFound" } } } };
  doc.paths["/v2/things"] = { get: { operationId: "listThings", tags: ["assets"], responses: { "500": { $ref: "#/components/responses/NotFound" } } } };
  const errors = checkContract(doc);
  assert.equal(errors.length, 1);
  assert.match(errors[0], /\/v2\/things: must start with \/api\/v1\//);
});

test("rejects unknown tags and missing operationIds", () => {
  const doc = validDoc();
  doc.paths[P].get.tags = ["misc"];
  delete doc.paths[P].get.operationId;
  const text = checkContract(doc).join("\n");
  assert.match(text, /unknown tag "misc"/);
  assert.match(text, /missing operationId/);
});

test("rejects sibling keys next to $ref", () => {
  const doc = validDoc();
  doc.components.schemas.Thing.properties.owner = { $ref: "#/components/schemas/Problem", description: "x" };
  assert.match(checkContract(doc).join("\n"), /sibling keys next to \$ref/);
});

test("rejects closed enums reachable from responses", () => {
  const doc = validDoc();
  doc.components.schemas.Thing.properties.state = { type: "string", enum: ["active", "trashed"] };
  assert.match(checkContract(doc).join("\n"), /closed enum reachable from a response/);
});

test("allows enums in request-only schemas", () => {
  const doc = validDoc();
  doc.paths[P].post = {
    operationId: "postThing",
    tags: ["assets"],
    requestBody: { content: { "application/json": { schema: { type: "object", properties: { mode: { type: "string", enum: ["tokens", "cookie"] } } } } } },
    responses: { "400": { $ref: "#/components/responses/NotFound" } },
  };
  assert.deepEqual(checkContract(doc), []);
});
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `pnpm --dir api run test`
Expected: FAIL — cannot find module `./contract-rules.mjs`.

- [ ] **Step 5: Implement `api/tools/contract-rules.mjs`**

```js
// Project-specific contract rules that Redocly does not cover.
// Usage: node tools/contract-rules.mjs openapi.yaml
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { parse } from "yaml";

const SNAKE = /^[a-z][a-z0-9]*(_[a-z0-9]+)*$/;
const ALLOWED_TAGS = new Set(["server", "auth", "pairing", "devices", "sync", "uploads", "assets", "engine"]);
const METHODS = ["get", "put", "post", "delete", "options", "head", "patch"];
const NO_BODY = new Set(["head", "options"]);
const HEALTH = new Set(["/healthz", "/readyz"]);

function deref(doc, node) {
  let cur = node;
  for (let i = 0; cur && typeof cur.$ref === "string"; i++) {
    if (i > 20) throw new Error(`$ref cycle at ${node.$ref}`);
    if (!cur.$ref.startsWith("#/")) throw new Error(`external $ref not allowed: ${cur.$ref}`);
    cur = cur.$ref
      .slice(2)
      .split("/")
      .reduce((o, k) => o?.[k.replaceAll("~1", "/").replaceAll("~0", "~")], doc);
  }
  return cur;
}

function children(schema) {
  const out = [];
  for (const [name, sub] of Object.entries(schema.properties ?? {})) out.push([`.${name}`, sub]);
  for (const key of ["items", "additionalProperties", "not"]) {
    if (schema[key] && typeof schema[key] === "object") out.push([`.${key}`, schema[key]]);
  }
  for (const key of ["allOf", "oneOf", "anyOf"]) (schema[key] ?? []).forEach((s, i) => out.push([`.${key}[${i}]`, s]));
  return out;
}

// Property naming and $ref siblings. Does not follow $refs: components are checked on their own.
function checkNaming(schema, where, errors) {
  if (!schema || typeof schema !== "object") return;
  if (schema.$ref) {
    if (Object.keys(schema).length > 1) errors.push(`${where}: sibling keys next to $ref are ignored in OpenAPI 3.0`);
    return;
  }
  for (const name of Object.keys(schema.properties ?? {})) {
    if (!SNAKE.test(name)) errors.push(`${where}: property "${name}" is not snake_case`);
  }
  for (const [suffix, sub] of children(schema)) checkNaming(sub, where + suffix, errors);
}

// Follows $refs from response bodies and flags closed enums: clients must tolerate new values.
function checkResponseEnums(doc, schema, where, errors, seen) {
  if (!schema || typeof schema !== "object") return;
  const resolved = deref(doc, schema);
  if (!resolved || seen.has(resolved)) return;
  seen.add(resolved);
  if (Array.isArray(resolved.enum)) errors.push(`${where}: closed enum reachable from a response (use type: string + x-known-values)`);
  for (const [suffix, sub] of children(resolved)) checkResponseEnums(doc, sub, where + suffix, errors, seen);
}

export function checkContract(doc) {
  const errors = [];
  if (doc.openapi !== "3.0.3") errors.push(`openapi must be "3.0.3", found "${doc.openapi}"`);
  for (const [name, schema] of Object.entries(doc.components?.schemas ?? {})) {
    checkNaming(schema, `components.schemas.${name}`, errors);
  }
  const enumSeen = new Set();
  for (const [path, item] of Object.entries(doc.paths ?? {})) {
    if (!path.startsWith("/api/v1/") && !HEALTH.has(path)) errors.push(`${path}: must start with /api/v1/`);
    for (const method of METHODS) {
      const op = item[method];
      if (!op) continue;
      const id = `${method.toUpperCase()} ${path}`;
      if (!op.operationId) errors.push(`${id}: missing operationId`);
      if (!op.tags?.length) errors.push(`${id}: missing tags`);
      for (const tag of op.tags ?? []) if (!ALLOWED_TAGS.has(tag)) errors.push(`${id}: unknown tag "${tag}"`);
      for (const param of [...(item.parameters ?? []), ...(op.parameters ?? [])].map((p) => deref(doc, p))) {
        if ((param.in === "query" || param.in === "path") && !SNAKE.test(param.name)) {
          errors.push(`${id}: parameter "${param.name}" is not snake_case`);
        }
      }
      const body = deref(doc, op.requestBody);
      for (const media of Object.values(body?.content ?? {})) checkNaming(media.schema, `${id} requestBody`, errors);
      let hasProblem = false;
      for (const [status, ref] of Object.entries(op.responses ?? {})) {
        const res = deref(doc, ref);
        for (const [type, media] of Object.entries(res?.content ?? {})) {
          checkNaming(media.schema, `${id} ${status}`, errors);
          checkResponseEnums(doc, media.schema, `${id} ${status}`, errors, enumSeen);
          if (/^[45]/.test(status) && type === "application/problem+json") hasProblem = true;
        }
      }
      if (!NO_BODY.has(method) && !hasProblem) errors.push(`${id}: no 4xx/5xx application/problem+json response`);
    }
  }
  return errors;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const file = process.argv[2] ?? "openapi.yaml";
  const errors = checkContract(parse(readFileSync(file, "utf8")));
  if (errors.length) {
    console.error(errors.join("\n"));
    process.exit(1);
  }
  console.log(`contract rules: ok (${file})`);
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `pnpm --dir api run test`
Expected: PASS, 11 tests.

- [ ] **Step 7: Append Taskfile tasks**

Append to the end of `Taskfile.yml`:
```yaml

  api:install:
    desc: Install API tooling dependencies
    cmds:
      - pnpm --dir api install --frozen-lockfile

  lint:api:
    desc: Lint the OpenAPI contract (Redocly + project rules)
    cmds:
      - pnpm --dir api run lint

  test:api:
    desc: Unit tests for API tooling
    cmds:
      - pnpm --dir api run test
```

- [ ] **Step 8: Commit**

```bash
git add api/package.json api/pnpm-lock.yaml api/redocly.yaml api/tools Taskfile.yml
git commit -s -m "build(api): add contract tooling and project lint rules"
```

---

### Task 5: OpenAPI contract — foundation, shared components, server endpoints

**Files:**
- Create: `api/openapi.yaml`

**Interfaces:**
- Consumes: Task 4 lint pipeline.
- Produces: shared components used by Tasks 6–8: parameters `Cursor`, `Limit`, `PageToken`, `AssetId`, `DeviceId`, `UploadId`, `Sha256Path`, `TusResumable`, `UploadOffset`, `UploadLength`, `UploadMetadata`, `UploadChecksum`, `Range`; headers `TusResumable`, `UploadOffset`, `UploadLength`, `UploadExpires`, `Location`, `AssetId`, `AssetCreated`, `RetryAfter`, `ETag`; responses `BadRequest`, `Unauthorized`, `Forbidden`, `NotFound`, `Conflict`, `Gone`, `PayloadTooLarge`, `RangeNotSatisfiable`, `Locked`, `UpgradeRequired`, `TooManyRequests`, `ChecksumMismatch`, `InternalError`, `ServiceUnavailable`, `InsufficientStorage`; schemas `Problem`, `Sha256`, `ServerInfo`, `ClientVersions`, `UploadLimits`. Marker comments `# @paths-auth`, `# @paths-sync`, `# @paths-uploads`, `# @paths-assets` (2-space indent, inside `paths:`) and `# @schemas-auth`, `# @schemas-sync`, `# @schemas-assets` (4-space indent, inside `components.schemas:`) that Tasks 6–8 replace.

- [ ] **Step 1: Confirm lint fails without a contract**

Run: `task lint:api`
Expected: FAIL — Redocly cannot find `openapi.yaml`.

- [ ] **Step 2: Create `api/openapi.yaml`**

```yaml
openapi: 3.0.3
info:
  title: PicTunnel API
  version: 1.0.0
  description: |
    Wire contract for the PicTunnel server, API version 1.

    * Normative sync behavior is specified in `protocol/sync-protocol.md`.
    * Errors are RFC 9457 problem details (`application/problem+json`) with a stable `code`.
    * Response fields whose value set may grow are strings; their known values are listed
      in `x-known-values`. Clients must tolerate values they do not know.
    * Apps send `PicTunnel-Client: <platform>/<version>`. Below `min_client_version` the
      server answers `426` with code `client_too_old`.
  license:
    name: Apache-2.0
    url: https://www.apache.org/licenses/LICENSE-2.0
servers:
  - url: https://{host}:{port}
    description: A PicTunnel server reached over the LAN or a user-supplied remote URL.
    variables:
      host:
        default: localhost
      port:
        default: "8443"
tags:
  - name: server
    description: Server identity and health.
  - name: auth
    description: First-run setup, login, token refresh and logout.
  - name: pairing
    description: One-time codes that pair a device with an account.
  - name: devices
    description: Devices paired with the caller's account.
  - name: sync
    description: Content check, change feed and snapshot.
  - name: uploads
    description: Resumable uploads (tus 1.0.0 profile, see sync-protocol.md).
  - name: assets
    description: Asset metadata, media, trash and tombstones.
  - name: engine
    description: Operations used by the native backup engines; generated for Kotlin and Swift.
security:
  - bearerAuth: []
  - cookieAuth: []
paths:
  /healthz:
    get:
      operationId: getHealthz
      summary: Liveness probe
      tags: [server]
      security: []
      responses:
        "200":
          description: The process is running.
          content:
            text/plain:
              schema:
                type: string
                example: ok
        "503":
          $ref: "#/components/responses/ServiceUnavailable"
  /readyz:
    get:
      operationId: getReadyz
      summary: Readiness probe
      tags: [server]
      security: []
      responses:
        "200":
          description: The database is open and storage is writable.
          content:
            text/plain:
              schema:
                type: string
                example: ready
        "503":
          $ref: "#/components/responses/ServiceUnavailable"
  /api/v1/server/info:
    get:
      operationId: getServerInfo
      summary: Server identity, versions, capabilities and upload limits
      tags: [server, engine]
      security: []
      responses:
        "200":
          description: Server information.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/ServerInfo"
        "429":
          $ref: "#/components/responses/TooManyRequests"
        "503":
          $ref: "#/components/responses/ServiceUnavailable"
  # @paths-auth
  # @paths-sync
  # @paths-uploads
  # @paths-assets
components:
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      description: Access token (`pt_at_…`) issued by login, pairing or refresh.
    cookieAuth:
      type: apiKey
      in: cookie
      name: pt_session
      description: Web viewer session cookie. State-changing requests also send `X-CSRF-Token`.
  parameters:
    Cursor:
      name: cursor
      in: query
      required: false
      description: Opaque cursor returned by a previous call.
      schema:
        type: string
    Limit:
      name: limit
      in: query
      required: false
      description: Maximum number of items to return. The server may return fewer.
      schema:
        type: integer
        minimum: 1
        maximum: 1000
        default: 200
    PageToken:
      name: page_token
      in: query
      required: false
      description: Opaque token for the next snapshot page.
      schema:
        type: string
    AssetId:
      name: asset_id
      in: path
      required: true
      schema:
        type: string
        format: uuid
    DeviceId:
      name: device_id
      in: path
      required: true
      schema:
        type: string
        format: uuid
    UploadId:
      name: upload_id
      in: path
      required: true
      schema:
        type: string
    Sha256Path:
      name: sha256
      in: path
      required: true
      schema:
        $ref: "#/components/schemas/Sha256"
    TusResumable:
      name: Tus-Resumable
      in: header
      required: true
      schema:
        type: string
        enum: ["1.0.0"]
    UploadOffset:
      name: Upload-Offset
      in: header
      required: true
      schema:
        type: integer
        format: int64
        minimum: 0
    UploadLength:
      name: Upload-Length
      in: header
      required: true
      schema:
        type: integer
        format: int64
        minimum: 0
    UploadMetadata:
      name: Upload-Metadata
      in: header
      required: true
      description: tus metadata, comma-separated `key base64(value)` pairs. Keys are defined in sync-protocol.md §7.3.
      schema:
        type: string
    UploadChecksum:
      name: Upload-Checksum
      in: header
      required: false
      description: Optional per-request checksum, `sha256 <base64 digest of this request body>`.
      schema:
        type: string
    Range:
      name: Range
      in: header
      required: false
      schema:
        type: string
        example: bytes=0-1048575
  headers:
    TusResumable:
      schema:
        type: string
        example: 1.0.0
    UploadOffset:
      schema:
        type: integer
        format: int64
    UploadLength:
      schema:
        type: integer
        format: int64
    UploadExpires:
      description: HTTP-date after which the upload session expires.
      schema:
        type: string
    Location:
      description: URL of the upload resource.
      schema:
        type: string
    AssetId:
      description: Asset the upload resolved to.
      schema:
        type: string
        format: uuid
    AssetCreated:
      description: "`true` when this request created a new asset, `false` when it resolved to an existing one."
      schema:
        type: boolean
    RetryAfter:
      description: Seconds to wait before retrying.
      schema:
        type: integer
    ETag:
      description: Quoted SHA-256 of the returned bytes.
      schema:
        type: string
  responses:
    BadRequest:
      description: "The request is malformed. Codes: `invalid_request`, `cursor_required`, `pairing_code_invalid`."
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    Unauthorized:
      description: "Missing or invalid credentials. Codes: `unauthorized`, `token_expired`, `refresh_token_reused`."
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    Forbidden:
      description: "The caller may not access this resource. Code: `forbidden`."
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    NotFound:
      description: "Not found, or not generated yet. Codes: `not_found`, `not_ready`."
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    Conflict:
      description: "Codes: `length_mismatch`, `tombstoned`, `pair_primary_missing`, `setup_already_done`."
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    Gone:
      description: "The cursor is older than the change-log retention. Code: `cursor_expired`."
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    PayloadTooLarge:
      description: "Codes: `file_too_large`, `quota_exceeded`."
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    RangeNotSatisfiable:
      description: "The Range header cannot be satisfied. Code: `invalid_request`."
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    Locked:
      description: "Another request is writing to this upload. Code: `upload_locked`."
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    UpgradeRequired:
      description: "The app is older than `min_client_version`. Code: `client_too_old`."
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    TooManyRequests:
      description: "Rate limited. Code: `rate_limited`."
      headers:
        Retry-After:
          $ref: "#/components/headers/RetryAfter"
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    ChecksumMismatch:
      description: "The bytes do not match the declared SHA-256. The upload session is discarded. Code: `checksum_mismatch`."
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    InternalError:
      description: "Unexpected server error. Code: `internal`."
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    ServiceUnavailable:
      description: "Temporarily unavailable. Code: `server_unavailable`."
      headers:
        Retry-After:
          $ref: "#/components/headers/RetryAfter"
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
    InsufficientStorage:
      description: "The server's disk is too full to accept this upload. Code: `insufficient_storage`."
      content:
        application/problem+json:
          schema:
            $ref: "#/components/schemas/Problem"
  schemas:
    Problem:
      type: object
      description: RFC 9457 problem details. `code` is stable and machine-readable; `title` and `detail` are for humans.
      required: [type, title, status, code]
      properties:
        type:
          type: string
          example: urn:pictunnel:problem:offset_mismatch
        title:
          type: string
          example: Upload offset does not match
        status:
          type: integer
          example: 409
        detail:
          type: string
        code:
          type: string
          example: offset_mismatch
          x-known-values:
            - invalid_request
            - cursor_required
            - pairing_code_invalid
            - unauthorized
            - token_expired
            - refresh_token_reused
            - forbidden
            - not_found
            - not_ready
            - offset_mismatch
            - length_mismatch
            - tombstoned
            - pair_primary_missing
            - setup_already_done
            - cursor_expired
            - file_too_large
            - quota_exceeded
            - upload_locked
            - client_too_old
            - rate_limited
            - checksum_mismatch
            - internal
            - server_unavailable
            - insufficient_storage
        request_id:
          type: string
    Sha256:
      type: string
      description: Lowercase hex SHA-256 of the original bytes.
      pattern: "^[0-9a-f]{64}$"
      example: fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83
    ServerInfo:
      type: object
      required: [server_id, name, version, api_version, min_client_version, capabilities, upload, time]
      properties:
        server_id:
          type: string
          format: uuid
        name:
          type: string
          example: Home server
        version:
          type: string
          example: 0.1.0
        api_version:
          type: string
          example: "1.0"
        min_client_version:
          $ref: "#/components/schemas/ClientVersions"
        capabilities:
          type: array
          items:
            type: string
            x-known-values: [tus, ml, share_links, search]
        upload:
          $ref: "#/components/schemas/UploadLimits"
        time:
          type: string
          format: date-time
          description: Server clock, for skew diagnostics only.
    ClientVersions:
      type: object
      required: [android, ios, web]
      properties:
        android:
          type: string
          example: 0.1.0
        ios:
          type: string
          example: 0.1.0
        web:
          type: string
          example: 0.1.0
    UploadLimits:
      type: object
      required: [tus_version, max_file_bytes, recommended_chunk_bytes]
      properties:
        tus_version:
          type: string
          example: 1.0.0
        max_file_bytes:
          type: integer
          format: int64
          example: 53687091200
        recommended_chunk_bytes:
          type: integer
          format: int64
          example: 8388608
    # @schemas-auth
    # @schemas-sync
    # @schemas-assets
```

- [ ] **Step 3: Run lint to verify it passes**

Run: `task lint:api`
Expected: Redocly reports no errors (warnings about unused components are acceptable at this stage), then `contract rules: ok (openapi.yaml)`.

- [ ] **Step 4: Commit**

```bash
git add api/openapi.yaml
git commit -s -m "feat(api): add OpenAPI foundation, shared components and server info"
```

---

### Task 6: OpenAPI contract — auth, pairing and devices

**Files:**
- Modify: `api/openapi.yaml` (replace `  # @paths-auth` and `    # @schemas-auth`)

**Interfaces:**
- Consumes: Task 5 components.
- Produces: operations `setupFirstAdmin`, `login`, `refreshTokens` (tags auth, engine), `logout`, `createPairingCode`, `redeemPairingCode`, `listDevices`, `updateDevice`, `revokeDevice`; schemas `SetupRequest`, `SetupResponse`, `LoginRequest`, `LoginResponse`, `DeviceRegistration`, `User`, `TokenPair`, `RefreshRequest`, `PairingCode`, `RedeemRequest`, `RedeemResponse`, `Device`, `DeviceList`, `DevicePatch`.

- [ ] **Step 1: Replace the line `  # @paths-auth` with**

```yaml
  /api/v1/auth/setup:
    post:
      operationId: setupFirstAdmin
      summary: Create the first administrator account
      description: Only succeeds while the server has no users; afterwards returns 409 `setup_already_done`.
      tags: [auth]
      security: []
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/SetupRequest"
      responses:
        "201":
          description: Administrator created.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/SetupResponse"
        "400":
          $ref: "#/components/responses/BadRequest"
        "409":
          $ref: "#/components/responses/Conflict"
        "429":
          $ref: "#/components/responses/TooManyRequests"
  /api/v1/auth/login:
    post:
      operationId: login
      summary: Log in with a password
      description: "`mode: tokens` returns device credentials (apps, requires `device`). `mode: cookie` sets the `pt_session` cookie and returns a CSRF token (web viewer)."
      tags: [auth]
      security: []
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/LoginRequest"
      responses:
        "200":
          description: Logged in.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/LoginResponse"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "426":
          $ref: "#/components/responses/UpgradeRequired"
        "429":
          $ref: "#/components/responses/TooManyRequests"
  /api/v1/auth/refresh:
    post:
      operationId: refreshTokens
      summary: Rotate the refresh token and issue a new access token
      description: Presenting the previous refresh token within 30 seconds of rotation returns the same successor pair. Later reuse revokes the device (`refresh_token_reused`).
      tags: [auth, engine]
      security: []
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/RefreshRequest"
      responses:
        "200":
          description: New token pair.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/TokenPair"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "426":
          $ref: "#/components/responses/UpgradeRequired"
        "429":
          $ref: "#/components/responses/TooManyRequests"
  /api/v1/auth/logout:
    post:
      operationId: logout
      summary: Revoke the current device session or web session
      tags: [auth]
      responses:
        "204":
          description: Logged out.
        "401":
          $ref: "#/components/responses/Unauthorized"
  /api/v1/pairing/codes:
    post:
      operationId: createPairingCode
      summary: Create a one-time pairing code for the caller's account
      tags: [pairing]
      responses:
        "201":
          description: Pairing code valid for 10 minutes, single use.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/PairingCode"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "429":
          $ref: "#/components/responses/TooManyRequests"
  /api/v1/pairing/redeem:
    post:
      operationId: redeemPairingCode
      summary: Exchange a pairing code for device credentials
      tags: [pairing]
      security: []
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/RedeemRequest"
      responses:
        "201":
          description: Device paired.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/RedeemResponse"
        "400":
          $ref: "#/components/responses/BadRequest"
        "426":
          $ref: "#/components/responses/UpgradeRequired"
        "429":
          $ref: "#/components/responses/TooManyRequests"
  /api/v1/devices:
    get:
      operationId: listDevices
      summary: List the caller's paired devices
      tags: [devices]
      responses:
        "200":
          description: Devices.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/DeviceList"
        "401":
          $ref: "#/components/responses/Unauthorized"
  /api/v1/devices/{device_id}:
    parameters:
      - $ref: "#/components/parameters/DeviceId"
    patch:
      operationId: updateDevice
      summary: Rename a device
      tags: [devices]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/DevicePatch"
      responses:
        "200":
          description: Updated device.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Device"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "404":
          $ref: "#/components/responses/NotFound"
    delete:
      operationId: revokeDevice
      summary: Revoke a device and all its tokens
      tags: [devices]
      responses:
        "204":
          description: Revoked.
        "401":
          $ref: "#/components/responses/Unauthorized"
        "404":
          $ref: "#/components/responses/NotFound"
```

- [ ] **Step 2: Replace the line `    # @schemas-auth` with**

```yaml
    SetupRequest:
      type: object
      required: [username, password]
      properties:
        username:
          type: string
          minLength: 3
          maxLength: 64
          pattern: "^[a-z0-9._-]+$"
        password:
          type: string
          format: password
          minLength: 10
          maxLength: 256
        display_name:
          type: string
          maxLength: 100
    SetupResponse:
      type: object
      required: [user]
      properties:
        user:
          $ref: "#/components/schemas/User"
    DeviceRegistration:
      type: object
      required: [device_name, platform, app_version]
      properties:
        device_name:
          type: string
          minLength: 1
          maxLength: 100
          example: Pixel 9
        platform:
          type: string
          enum: [android, ios, web, other]
        app_version:
          type: string
          example: 0.1.0
    LoginRequest:
      type: object
      required: [username, password, mode]
      properties:
        username:
          type: string
        password:
          type: string
          format: password
        mode:
          type: string
          enum: [tokens, cookie]
        device:
          $ref: "#/components/schemas/DeviceRegistration"
    LoginResponse:
      type: object
      required: [user]
      properties:
        user:
          $ref: "#/components/schemas/User"
        device:
          $ref: "#/components/schemas/Device"
        tokens:
          $ref: "#/components/schemas/TokenPair"
        csrf_token:
          type: string
          description: Present in cookie mode; send as `X-CSRF-Token`.
    User:
      type: object
      required: [id, username, display_name, role]
      properties:
        id:
          type: string
          format: uuid
        username:
          type: string
        display_name:
          type: string
        role:
          type: string
          x-known-values: [admin, user]
    TokenPair:
      type: object
      required: [access_token, access_token_expires_at, refresh_token, refresh_token_expires_at]
      properties:
        access_token:
          type: string
          example: pt_at_3q2-7wEXAMPLEtokenvalue
        access_token_expires_at:
          type: string
          format: date-time
        refresh_token:
          type: string
          example: pt_rt_9fEXAMPLErefreshvalue
        refresh_token_expires_at:
          type: string
          format: date-time
    RefreshRequest:
      type: object
      required: [refresh_token]
      properties:
        refresh_token:
          type: string
    PairingCode:
      type: object
      required: [code, qr_uri, expires_at]
      properties:
        code:
          type: string
          pattern: "^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{2}$"
          example: K7Q2-M9XD-4T
        qr_uri:
          type: string
          example: pictunnel://pair?v=1&sid=01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f&code=K7Q2-M9XD-4T&fp=xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc&u=https%3A%2F%2F192.168.1.20%3A8443
        expires_at:
          type: string
          format: date-time
    RedeemRequest:
      type: object
      required: [code, device]
      properties:
        code:
          type: string
        device:
          $ref: "#/components/schemas/DeviceRegistration"
    RedeemResponse:
      type: object
      required: [server_id, user, device, tokens]
      properties:
        server_id:
          type: string
          format: uuid
        user:
          $ref: "#/components/schemas/User"
        device:
          $ref: "#/components/schemas/Device"
        tokens:
          $ref: "#/components/schemas/TokenPair"
    Device:
      type: object
      required: [id, name, platform, app_version, created_at]
      properties:
        id:
          type: string
          format: uuid
        name:
          type: string
        platform:
          type: string
          x-known-values: [android, ios, web, other]
        app_version:
          type: string
        created_at:
          type: string
          format: date-time
        last_seen_at:
          type: string
          format: date-time
          nullable: true
    DeviceList:
      type: object
      required: [devices]
      properties:
        devices:
          type: array
          items:
            $ref: "#/components/schemas/Device"
    DevicePatch:
      type: object
      required: [name]
      properties:
        name:
          type: string
          minLength: 1
          maxLength: 100
```

- [ ] **Step 3: Verify the response-enum rule holds**

`DeviceRegistration.platform` is an `enum` but only reachable from request bodies; `Device.platform` (responses) is a string. Run `task lint:api` — expected: Redocly clean, `contract rules: ok`. If the rule reports a closed enum reachable from a response, a request schema was referenced from a response: fix the reference, not the rule.

- [ ] **Step 4: Commit**

```bash
git add api/openapi.yaml
git commit -s -m "feat(api): add auth, pairing and device endpoints"
```

---

### Task 7: OpenAPI contract — sync and tus uploads

**Files:**
- Modify: `api/openapi.yaml` (replace `  # @paths-sync`, `  # @paths-uploads`, `    # @schemas-sync`)

**Interfaces:**
- Consumes: Task 5 components.
- Produces: operations `checkContent`, `getChanges`, `getSnapshot`, `optionsUploads`, `createUpload`, `getUploadOffset`, `appendUpload`, `terminateUpload`; schemas `CheckRequest`, `CheckItem`, `CheckResponse`, `CheckResult`, `UploadRef`, `Asset`, `LiveVideo`, `ChangeEntry`, `ChangesPage`, `SnapshotPage`.

- [ ] **Step 1: Replace the line `  # @paths-sync` with**

```yaml
  /api/v1/sync/check:
    post:
      operationId: checkContent
      summary: Batch content check by SHA-256
      description: Read-only except for linking `(device, local_id)` to existing assets. See sync-protocol.md §7.2.
      tags: [sync, engine]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/CheckRequest"
      responses:
        "200":
          description: One result per requested item, in request order.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/CheckResponse"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "426":
          $ref: "#/components/responses/UpgradeRequired"
        "429":
          $ref: "#/components/responses/TooManyRequests"
        "503":
          $ref: "#/components/responses/ServiceUnavailable"
  /api/v1/sync/changes:
    get:
      operationId: getChanges
      summary: Delta change feed since a cursor
      description: "Calling without `cursor` returns 400 `cursor_required`; run a snapshot first. Cursors older than 90 days return 410 `cursor_expired`."
      tags: [sync]
      parameters:
        - $ref: "#/components/parameters/Cursor"
        - $ref: "#/components/parameters/Limit"
      responses:
        "200":
          description: Changes in sequence order.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/ChangesPage"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "410":
          $ref: "#/components/responses/Gone"
  /api/v1/sync/snapshot:
    get:
      operationId: getSnapshot
      summary: Full metadata snapshot, paged
      description: The first page carries `cursor` (change-log head at snapshot start). After the last page continue with `getChanges` from that cursor.
      tags: [sync]
      parameters:
        - $ref: "#/components/parameters/PageToken"
        - $ref: "#/components/parameters/Limit"
      responses:
        "200":
          description: A page of assets ordered by id.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/SnapshotPage"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
```

- [ ] **Step 2: Replace the line `  # @paths-uploads` with**

```yaml
  /api/v1/uploads:
    options:
      operationId: optionsUploads
      summary: tus capability discovery
      tags: [uploads, engine]
      security: []
      responses:
        "204":
          description: Supported tus version, extensions and limits.
          headers:
            Tus-Resumable:
              $ref: "#/components/headers/TusResumable"
            Tus-Version:
              schema:
                type: string
                example: 1.0.0
            Tus-Extension:
              schema:
                type: string
                example: creation,creation-with-upload,termination,expiration,checksum
            Tus-Max-Size:
              schema:
                type: integer
                format: int64
            Tus-Checksum-Algorithm:
              schema:
                type: string
                example: sha256
    post:
      operationId: createUpload
      summary: Create an upload, optionally sending bytes in the same request
      description: Idempotent per `(owner, sha256)`. Outcomes and their precedence are defined in sync-protocol.md §7.3.
      tags: [uploads, engine]
      parameters:
        - $ref: "#/components/parameters/TusResumable"
        - $ref: "#/components/parameters/UploadLength"
        - $ref: "#/components/parameters/UploadMetadata"
        - $ref: "#/components/parameters/UploadChecksum"
      requestBody:
        required: false
        content:
          application/offset+octet-stream:
            schema:
              type: string
              format: binary
      responses:
        "201":
          description: Upload session created, resumed, or resolved to an existing asset.
          headers:
            Tus-Resumable:
              $ref: "#/components/headers/TusResumable"
            Location:
              $ref: "#/components/headers/Location"
            Upload-Offset:
              $ref: "#/components/headers/UploadOffset"
            Upload-Expires:
              $ref: "#/components/headers/UploadExpires"
            PicTunnel-Asset-Id:
              $ref: "#/components/headers/AssetId"
            PicTunnel-Asset-Created:
              $ref: "#/components/headers/AssetCreated"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "409":
          $ref: "#/components/responses/Conflict"
        "413":
          $ref: "#/components/responses/PayloadTooLarge"
        "426":
          $ref: "#/components/responses/UpgradeRequired"
        "429":
          $ref: "#/components/responses/TooManyRequests"
        "460":
          $ref: "#/components/responses/ChecksumMismatch"
        "503":
          $ref: "#/components/responses/ServiceUnavailable"
        "507":
          $ref: "#/components/responses/InsufficientStorage"
  /api/v1/uploads/{upload_id}:
    parameters:
      - $ref: "#/components/parameters/UploadId"
    head:
      operationId: getUploadOffset
      summary: Current offset of an upload
      tags: [uploads, engine]
      responses:
        "200":
          description: Upload state. `PicTunnel-Asset-Id` is present once finalized.
          headers:
            Tus-Resumable:
              $ref: "#/components/headers/TusResumable"
            Upload-Offset:
              $ref: "#/components/headers/UploadOffset"
            Upload-Length:
              $ref: "#/components/headers/UploadLength"
            Upload-Expires:
              $ref: "#/components/headers/UploadExpires"
            PicTunnel-Asset-Id:
              $ref: "#/components/headers/AssetId"
        "401":
          description: Missing or invalid credentials.
        "404":
          description: Unknown or expired upload; restart with createUpload.
    patch:
      operationId: appendUpload
      summary: Append bytes at the current offset
      description: The request that completes the upload runs finalize (sync-protocol.md §7.4) before responding.
      tags: [uploads, engine]
      parameters:
        - $ref: "#/components/parameters/TusResumable"
        - $ref: "#/components/parameters/UploadOffset"
        - $ref: "#/components/parameters/UploadChecksum"
      requestBody:
        required: true
        content:
          application/offset+octet-stream:
            schema:
              type: string
              format: binary
      responses:
        "204":
          description: Bytes accepted. Asset headers are present when this request finalized the upload.
          headers:
            Tus-Resumable:
              $ref: "#/components/headers/TusResumable"
            Upload-Offset:
              $ref: "#/components/headers/UploadOffset"
            PicTunnel-Asset-Id:
              $ref: "#/components/headers/AssetId"
            PicTunnel-Asset-Created:
              $ref: "#/components/headers/AssetCreated"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "404":
          $ref: "#/components/responses/NotFound"
        "409":
          description: "`offset_mismatch`: the request's Upload-Offset differs from the server's. The current offset is returned."
          headers:
            Upload-Offset:
              $ref: "#/components/headers/UploadOffset"
          content:
            application/problem+json:
              schema:
                $ref: "#/components/schemas/Problem"
        "423":
          $ref: "#/components/responses/Locked"
        "429":
          $ref: "#/components/responses/TooManyRequests"
        "460":
          $ref: "#/components/responses/ChecksumMismatch"
        "503":
          $ref: "#/components/responses/ServiceUnavailable"
        "507":
          $ref: "#/components/responses/InsufficientStorage"
    delete:
      operationId: terminateUpload
      summary: Abandon an upload and delete its staged bytes
      tags: [uploads, engine]
      parameters:
        - $ref: "#/components/parameters/TusResumable"
      responses:
        "204":
          description: Terminated.
        "401":
          $ref: "#/components/responses/Unauthorized"
        "404":
          $ref: "#/components/responses/NotFound"
```

- [ ] **Step 3: Replace the line `    # @schemas-sync` with**

```yaml
    CheckItem:
      type: object
      required: [sha256, size_bytes]
      properties:
        sha256:
          $ref: "#/components/schemas/Sha256"
        size_bytes:
          type: integer
          format: int64
          minimum: 0
        local_id:
          type: string
          maxLength: 512
          description: Device-local identifier; linked to the asset when the verdict is `exists`.
        confirm_on_disk:
          type: boolean
          default: false
          description: Ask the server to stat the original and report `on_disk` (used before freeing space).
    CheckRequest:
      type: object
      required: [items]
      properties:
        items:
          type: array
          minItems: 1
          maxItems: 1000
          items:
            $ref: "#/components/schemas/CheckItem"
    UploadRef:
      type: object
      required: [id, url, offset, length, expires_at]
      properties:
        id:
          type: string
        url:
          type: string
          example: /api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab
        offset:
          type: integer
          format: int64
        length:
          type: integer
          format: int64
        expires_at:
          type: string
          format: date-time
    CheckResult:
      type: object
      required: [sha256, verdict]
      properties:
        sha256:
          $ref: "#/components/schemas/Sha256"
        verdict:
          type: string
          x-known-values: [exists, missing, partial, tombstoned]
        asset_id:
          type: string
          format: uuid
        asset_state:
          type: string
          x-known-values: [active, trashed]
        has_live_video:
          type: boolean
        on_disk:
          type: boolean
        upload:
          $ref: "#/components/schemas/UploadRef"
        deleted_at:
          type: string
          format: date-time
    CheckResponse:
      type: object
      required: [results]
      properties:
        results:
          type: array
          items:
            $ref: "#/components/schemas/CheckResult"
    LiveVideo:
      type: object
      required: [sha256, size_bytes, mime]
      properties:
        sha256:
          $ref: "#/components/schemas/Sha256"
        size_bytes:
          type: integer
          format: int64
        mime:
          type: string
          example: video/quicktime
    Asset:
      type: object
      required: [id, sha256, size_bytes, mime, kind, filename, taken_at_source, state, thumbnails_ready, created_at, updated_seq]
      properties:
        id:
          type: string
          format: uuid
        sha256:
          $ref: "#/components/schemas/Sha256"
        size_bytes:
          type: integer
          format: int64
        mime:
          type: string
          example: image/heic
        kind:
          type: string
          x-known-values: [photo, video, live_photo]
        filename:
          type: string
          example: IMG_0042.HEIC
        taken_at:
          type: string
          format: date-time
          nullable: true
        taken_at_offset_minutes:
          type: integer
          nullable: true
        taken_at_source:
          type: string
          x-known-values: [exif, container, client, file, unknown]
        width:
          type: integer
          nullable: true
        height:
          type: integer
          nullable: true
        duration_ms:
          type: integer
          format: int64
          nullable: true
        lat:
          type: number
          format: double
          nullable: true
        lon:
          type: number
          format: double
          nullable: true
        state:
          type: string
          x-known-values: [active, trashed]
        trashed_at:
          type: string
          format: date-time
          nullable: true
        stack_id:
          type: string
          format: uuid
          nullable: true
        live_video:
          $ref: "#/components/schemas/LiveVideo"
        thumbnails_ready:
          type: boolean
        created_at:
          type: string
          format: date-time
        updated_seq:
          type: integer
          format: int64
    ChangeEntry:
      type: object
      required: [seq, kind]
      properties:
        seq:
          type: integer
          format: int64
        kind:
          type: string
          x-known-values: [asset.upsert, asset.removed]
        asset:
          $ref: "#/components/schemas/Asset"
        asset_id:
          type: string
          format: uuid
          description: Present for `asset.removed`.
    ChangesPage:
      type: object
      required: [changes, next_cursor, has_more]
      properties:
        changes:
          type: array
          items:
            $ref: "#/components/schemas/ChangeEntry"
        next_cursor:
          type: string
        has_more:
          type: boolean
    SnapshotPage:
      type: object
      required: [assets, has_more]
      properties:
        cursor:
          type: string
          description: Present on the first page only. Continue with getChanges from here after the last page.
        assets:
          type: array
          items:
            $ref: "#/components/schemas/Asset"
        next_page_token:
          type: string
          nullable: true
        has_more:
          type: boolean
```

- [ ] **Step 4: Run lint**

Run: `task lint:api`
Expected: no errors, `contract rules: ok`. Redocly may warn that status `460` is non-standard; that warning is accepted (tus checksum extension).

- [ ] **Step 5: Commit**

```bash
git add api/openapi.yaml
git commit -s -m "feat(api): add sync check, change feed, snapshot and tus upload endpoints"
```

---

### Task 8: OpenAPI contract — assets, trash and tombstones

**Files:**
- Modify: `api/openapi.yaml` (replace `  # @paths-assets`, `    # @schemas-assets`)

**Interfaces:**
- Consumes: Tasks 5 and 7 (`Asset`).
- Produces: operations `getAsset`, `getAssetThumbnail`, `getAssetOriginal`, `getAssetPlayback`, `trashAssets`, `restoreAssets`, `purgeAssets`, `emptyTrash`, `listTombstones`, `deleteTombstone` (tags assets, engine); schemas `AssetIdList`, `BulkResult`, `BulkFailure`, `EmptyTrashResult`, `Tombstone`, `TombstonePage`. After this task the contract is complete for M0 (30 operations).

- [ ] **Step 1: Replace the line `  # @paths-assets` with**

```yaml
  /api/v1/assets/{asset_id}:
    parameters:
      - $ref: "#/components/parameters/AssetId"
    get:
      operationId: getAsset
      summary: Asset metadata
      tags: [assets]
      responses:
        "200":
          description: The asset.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/Asset"
        "401":
          $ref: "#/components/responses/Unauthorized"
        "404":
          $ref: "#/components/responses/NotFound"
  /api/v1/assets/{asset_id}/thumbnail:
    parameters:
      - $ref: "#/components/parameters/AssetId"
    get:
      operationId: getAssetThumbnail
      summary: JPEG thumbnail or preview
      tags: [assets]
      parameters:
        - name: size
          in: query
          required: false
          schema:
            type: string
            enum: [thumb, preview]
            default: thumb
      responses:
        "200":
          description: "`thumb` is 320 px on the long edge, `preview` is 1440 px."
          headers:
            ETag:
              $ref: "#/components/headers/ETag"
          content:
            image/jpeg:
              schema:
                type: string
                format: binary
        "401":
          $ref: "#/components/responses/Unauthorized"
        "404":
          $ref: "#/components/responses/NotFound"
  /api/v1/assets/{asset_id}/original:
    parameters:
      - $ref: "#/components/parameters/AssetId"
    get:
      operationId: getAssetOriginal
      summary: Original bytes, with Range support
      tags: [assets]
      parameters:
        - $ref: "#/components/parameters/Range"
      responses:
        "200":
          description: Whole file.
          headers:
            ETag:
              $ref: "#/components/headers/ETag"
            Accept-Ranges:
              schema:
                type: string
                example: bytes
            Content-Disposition:
              schema:
                type: string
          content:
            application/octet-stream:
              schema:
                type: string
                format: binary
        "206":
          description: Requested byte range.
          headers:
            ETag:
              $ref: "#/components/headers/ETag"
            Content-Range:
              schema:
                type: string
          content:
            application/octet-stream:
              schema:
                type: string
                format: binary
        "401":
          $ref: "#/components/responses/Unauthorized"
        "404":
          $ref: "#/components/responses/NotFound"
        "416":
          $ref: "#/components/responses/RangeNotSatisfiable"
  /api/v1/assets/{asset_id}/playback:
    parameters:
      - $ref: "#/components/parameters/AssetId"
    get:
      operationId: getAssetPlayback
      summary: Browser-playable video (original or H.264 transcode)
      tags: [assets]
      parameters:
        - $ref: "#/components/parameters/Range"
      responses:
        "200":
          description: Whole video.
          content:
            video/mp4:
              schema:
                type: string
                format: binary
        "206":
          description: Requested byte range.
          headers:
            Content-Range:
              schema:
                type: string
          content:
            video/mp4:
              schema:
                type: string
                format: binary
        "401":
          $ref: "#/components/responses/Unauthorized"
        "404":
          $ref: "#/components/responses/NotFound"
        "416":
          $ref: "#/components/responses/RangeNotSatisfiable"
  /api/v1/assets/trash:
    post:
      operationId: trashAssets
      summary: Move assets to the trash
      tags: [assets]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/AssetIdList"
      responses:
        "200":
          description: Per-asset outcome.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/BulkResult"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
  /api/v1/assets/restore:
    post:
      operationId: restoreAssets
      summary: Restore assets from the trash
      tags: [assets]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/AssetIdList"
      responses:
        "200":
          description: Per-asset outcome.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/BulkResult"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
  /api/v1/assets/purge:
    post:
      operationId: purgeAssets
      summary: Permanently delete trashed assets and record tombstones
      tags: [assets]
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: "#/components/schemas/AssetIdList"
      responses:
        "200":
          description: Per-asset outcome. Assets that are not trashed fail with `not_trashed`.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/BulkResult"
        "400":
          $ref: "#/components/responses/BadRequest"
        "401":
          $ref: "#/components/responses/Unauthorized"
  /api/v1/trash/empty:
    post:
      operationId: emptyTrash
      summary: Purge every trashed asset of the caller
      tags: [assets]
      responses:
        "200":
          description: Number of purged assets.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/EmptyTrashResult"
        "401":
          $ref: "#/components/responses/Unauthorized"
  /api/v1/tombstones:
    get:
      operationId: listTombstones
      summary: Content the caller deliberately purged
      tags: [assets]
      parameters:
        - $ref: "#/components/parameters/Cursor"
        - $ref: "#/components/parameters/Limit"
      responses:
        "200":
          description: Tombstones, newest first.
          content:
            application/json:
              schema:
                $ref: "#/components/schemas/TombstonePage"
        "401":
          $ref: "#/components/responses/Unauthorized"
  /api/v1/tombstones/{sha256}:
    parameters:
      - $ref: "#/components/parameters/Sha256Path"
    delete:
      operationId: deleteTombstone
      summary: Remove a tombstone so the content can be backed up again
      tags: [assets, engine]
      responses:
        "204":
          description: Removed.
        "401":
          $ref: "#/components/responses/Unauthorized"
        "404":
          $ref: "#/components/responses/NotFound"
```

- [ ] **Step 2: Replace the line `    # @schemas-assets` with**

```yaml
    AssetIdList:
      type: object
      required: [asset_ids]
      properties:
        asset_ids:
          type: array
          minItems: 1
          maxItems: 1000
          items:
            type: string
            format: uuid
    BulkFailure:
      type: object
      required: [asset_id, code]
      properties:
        asset_id:
          type: string
          format: uuid
        code:
          type: string
          x-known-values: [not_found, not_trashed]
    BulkResult:
      type: object
      required: [succeeded, failed]
      properties:
        succeeded:
          type: array
          items:
            type: string
            format: uuid
        failed:
          type: array
          items:
            $ref: "#/components/schemas/BulkFailure"
    EmptyTrashResult:
      type: object
      required: [purged_count]
      properties:
        purged_count:
          type: integer
    Tombstone:
      type: object
      required: [sha256, filename, deleted_at]
      properties:
        sha256:
          $ref: "#/components/schemas/Sha256"
        filename:
          type: string
        deleted_at:
          type: string
          format: date-time
    TombstonePage:
      type: object
      required: [tombstones, has_more]
      properties:
        tombstones:
          type: array
          items:
            $ref: "#/components/schemas/Tombstone"
        next_cursor:
          type: string
          nullable: true
        has_more:
          type: boolean
```

- [ ] **Step 3: Verify the contract is complete**

Run: `task lint:api` → Redocly: no errors; `contract rules: ok`.
Run: `grep -c "operationId:" api/openapi.yaml` → `30`.
Run: `grep -n "# @" api/openapi.yaml` → no output (all markers replaced).

- [ ] **Step 4: Commit**

```bash
git add api/openapi.yaml
git commit -s -m "feat(api): add asset, trash and tombstone endpoints"
```

---

### Task 9: Vector schema and validator

**Files:**
- Create: `api/protocol/vectors/vectors.schema.json`, `api/tools/validate-vectors.mjs`, `api/tools/validate-vectors.test.mjs`
- Modify: `api/package.json` (`vectors` script gets `--strict`), `Taskfile.yml` (append `vectors:validate`)

**Interfaces:**
- Consumes: Task 4 tooling (`ajv`, `ajv-formats`).
- Produces: the vector file format used by Tasks 10–14, 17, 18; exports `compileSchema(schema): (doc) => string[]`, `semanticErrors(doc, { dirKind, fileExists }): string[]`, `duplicateNameErrors(docs): string[]`, `minimumErrors(counts): string[]`, `MINIMUMS`, `DIR_KIND`, `validateAll(protocolDir, { strict }): { errors: string[], counts: Record<string, number> }`. CLI: `node api/tools/validate-vectors.mjs [--strict]`.

- [ ] **Step 1: Create `api/protocol/vectors/vectors.schema.json`**

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:pictunnel:vectors:v1",
  "title": "PicTunnel conformance vector file",
  "description": "Runner and matcher semantics are defined in api/protocol/sync-protocol.md, section 'Conformance vectors'.",
  "type": "object",
  "required": ["schema_version", "kind", "description", "cases"],
  "additionalProperties": false,
  "properties": {
    "schema_version": { "const": 1 },
    "kind": { "enum": ["hashing", "server-scenario", "client-decision", "pairing"] },
    "description": { "type": "string", "minLength": 1 },
    "cases": { "type": "array", "minItems": 1 }
  },
  "allOf": [
    { "if": { "properties": { "kind": { "const": "hashing" } } }, "then": { "properties": { "cases": { "items": { "$ref": "#/$defs/hashing_case" } } } } },
    { "if": { "properties": { "kind": { "const": "pairing" } } }, "then": { "properties": { "cases": { "items": { "$ref": "#/$defs/pairing_case" } } } } },
    { "if": { "properties": { "kind": { "const": "server-scenario" } } }, "then": { "properties": { "cases": { "items": { "$ref": "#/$defs/server_scenario_case" } } } } },
    { "if": { "properties": { "kind": { "const": "client-decision" } } }, "then": { "properties": { "cases": { "items": { "$ref": "#/$defs/client_decision_case" } } } } }
  ],
  "$defs": {
    "name": { "type": "string", "pattern": "^[a-z0-9]+(_[a-z0-9]+)*$" },
    "sha256": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
    "var_ref": { "type": "string", "pattern": "^\\$\\{[a-z0-9_]+\\}$" },
    "generate": {
      "type": "object",
      "required": ["pattern", "length"],
      "additionalProperties": false,
      "properties": {
        "pattern": { "const": "counter" },
        "seed": { "type": "integer", "minimum": 0, "maximum": 255 },
        "length": { "type": "integer", "minimum": 0 },
        "start": { "oneOf": [{ "type": "integer", "minimum": 0 }, { "$ref": "#/$defs/var_ref" }] },
        "end": { "oneOf": [{ "type": "integer", "minimum": 0 }, { "$ref": "#/$defs/var_ref" }] }
      }
    },
    "hashing_case": {
      "type": "object",
      "required": ["name", "input", "expected_sha256"],
      "additionalProperties": false,
      "properties": {
        "name": { "$ref": "#/$defs/name" },
        "description": { "type": "string" },
        "input": {
          "type": "object",
          "minProperties": 1,
          "maxProperties": 1,
          "additionalProperties": false,
          "properties": {
            "file": { "type": "string", "pattern": "^fixtures/[A-Za-z0-9._-]+$" },
            "inline_utf8": { "type": "string" },
            "generate": { "$ref": "#/$defs/generate" }
          }
        },
        "expected_sha256": { "$ref": "#/$defs/sha256" }
      }
    },
    "pairing_case": {
      "type": "object",
      "required": ["name", "uri", "expect"],
      "additionalProperties": false,
      "properties": {
        "name": { "$ref": "#/$defs/name" },
        "description": { "type": "string" },
        "uri": { "type": "string" },
        "connection": {
          "type": "object",
          "required": ["endpoint", "system_trusted", "spki_sha256"],
          "additionalProperties": false,
          "properties": {
            "endpoint": { "type": "string" },
            "system_trusted": { "type": "boolean" },
            "spki_sha256": { "type": "string" }
          }
        },
        "expect": {
          "type": "object",
          "required": ["parse"],
          "additionalProperties": false,
          "properties": {
            "parse": { "enum": ["ok", "error"] },
            "error": { "enum": ["invalid_scheme", "unsupported_version", "missing_server_id", "invalid_code", "missing_fingerprint", "missing_endpoint", "insecure_endpoint"] },
            "server_id": { "type": "string" },
            "code": { "type": "string" },
            "fingerprint": { "type": "string" },
            "endpoints": { "type": "array", "items": { "type": "string" } },
            "accept_connection": { "type": "boolean" }
          }
        }
      }
    },
    "server_scenario_case": {
      "type": "object",
      "required": ["name", "actors", "steps"],
      "additionalProperties": false,
      "properties": {
        "name": { "$ref": "#/$defs/name" },
        "description": { "type": "string" },
        "actors": {
          "type": "object",
          "minProperties": 1,
          "propertyNames": { "$ref": "#/$defs/name" },
          "additionalProperties": {
            "type": "object",
            "required": ["user"],
            "additionalProperties": false,
            "properties": {
              "user": { "type": "string" },
              "platform": { "enum": ["android", "ios", "web", "other"] }
            }
          }
        },
        "steps": { "type": "array", "minItems": 1, "items": { "oneOf": [{ "$ref": "#/$defs/http_step" }, { "$ref": "#/$defs/control_step" }] } }
      }
    },
    "http_step": {
      "type": "object",
      "required": ["actor", "request", "expect"],
      "additionalProperties": false,
      "properties": {
        "actor": { "type": "string" },
        "request": {
          "type": "object",
          "required": ["method", "path"],
          "additionalProperties": false,
          "properties": {
            "method": { "enum": ["GET", "POST", "PATCH", "HEAD", "DELETE", "OPTIONS"] },
            "path": { "type": "string" },
            "headers": { "type": "object", "additionalProperties": { "type": "string" } },
            "json": {},
            "tus_metadata": { "type": "object", "additionalProperties": { "type": "string" } },
            "body": {
              "type": "object",
              "required": ["generate"],
              "additionalProperties": false,
              "properties": { "generate": { "$ref": "#/$defs/generate" } }
            }
          }
        },
        "transport": {
          "type": "object",
          "required": ["drop_after_bytes"],
          "additionalProperties": false,
          "properties": { "drop_after_bytes": { "type": "integer", "minimum": 0 } }
        },
        "expect": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "status": { "type": "integer", "minimum": 100, "maximum": 599 },
            "no_response": { "const": true },
            "headers": { "type": "object", "additionalProperties": { "type": "string" } },
            "body": {}
          },
          "oneOf": [{ "required": ["status"] }, { "required": ["no_response"] }]
        },
        "save": {
          "type": "object",
          "propertyNames": { "$ref": "#/$defs/name" },
          "additionalProperties": { "type": "string", "pattern": "^(header:[A-Za-z0-9-]+|body:(/[^/]*)+)$" }
        }
      }
    },
    "control_step": {
      "type": "object",
      "required": ["control"],
      "additionalProperties": false,
      "properties": {
        "control": {
          "type": "object",
          "minProperties": 1,
          "maxProperties": 1,
          "additionalProperties": false,
          "properties": {
            "advance_clock_seconds": { "type": "integer", "minimum": 1 },
            "run_job": { "enum": ["compact_change_log", "expire_uploads", "purge_trash"] },
            "assert_library_paths": {
              "type": "object",
              "required": ["user", "paths"],
              "additionalProperties": false,
              "properties": {
                "user": { "type": "string" },
                "paths": { "type": "array", "items": { "type": "string" } }
              }
            },
            "assert_asset_sources": {
              "type": "object",
              "required": ["asset", "sources"],
              "additionalProperties": false,
              "properties": {
                "asset": { "type": "string" },
                "sources": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "required": ["actor", "local_id"],
                    "additionalProperties": false,
                    "properties": { "actor": { "type": "string" }, "local_id": { "type": "string" } }
                  }
                }
              }
            }
          }
        }
      }
    },
    "item_state": { "enum": ["Discovered", "Hashed", "Queued", "Uploading", "Verifying", "BackedUp", "Skipped", "Freed", "NeedsAttention", "Paused"] },
    "client_decision_case": {
      "type": "object",
      "required": ["name", "given", "server", "expect"],
      "additionalProperties": false,
      "properties": {
        "name": { "$ref": "#/$defs/name" },
        "description": { "type": "string" },
        "given": {
          "type": "object",
          "required": ["flow", "last_action"],
          "additionalProperties": false,
          "properties": {
            "flow": { "enum": ["backup", "auth", "browse", "pairing", "setup", "free_up_space"] },
            "item_state": { "$ref": "#/$defs/item_state" },
            "last_action": { "enum": ["check", "create_upload", "append_upload", "head_upload", "refresh", "get_changes", "get_thumbnail", "redeem_pairing", "setup", "free_up_space_check"] },
            "item": {
              "type": "object",
              "additionalProperties": false,
              "properties": {
                "kind": { "enum": ["photo", "video", "live_photo"] },
                "attempts": { "type": "integer", "minimum": 0 },
                "has_upload_id": { "type": "boolean" },
                "fingerprint_changed": { "type": "boolean" }
              }
            }
          }
        },
        "server": {
          "type": "object",
          "additionalProperties": false,
          "properties": {
            "status": { "type": "integer", "minimum": 100, "maximum": 599 },
            "headers": { "type": "object", "additionalProperties": { "type": "string" } },
            "json": {},
            "problem": { "type": "string" },
            "transport": { "enum": ["timeout", "reset", "offline"] }
          },
          "oneOf": [{ "required": ["status"] }, { "required": ["transport"] }]
        },
        "expect": {
          "type": "object",
          "required": ["action"],
          "additionalProperties": false,
          "properties": {
            "next_state": { "$ref": "#/$defs/item_state" },
            "action": {
              "enum": [
                "mark_backed_up", "queue_upload", "resume_upload", "head_then_resume", "restart_upload",
                "mark_skipped", "rehash_and_requeue", "backoff_retry", "wait_retry_after", "wait_for_network",
                "refresh_then_retry", "retry_original_request", "require_repair", "pause_all_uploads", "notify_quota",
                "prompt_update", "mark_needs_attention", "run_snapshot", "retry_later", "skip_this_run",
                "upload_primary_first", "upload_live_video", "check_then_resolve", "delete_local_allowed",
                "delete_local_denied", "show_error", "go_to_login"
              ]
            },
            "attempts_delta": { "type": "integer", "minimum": 0, "maximum": 1 }
          }
        }
      }
    }
  }
}
```

- [ ] **Step 2: Write the failing tests**

`api/tools/validate-vectors.test.mjs`:
```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { compileSchema, semanticErrors, duplicateNameErrors, minimumErrors } from "./validate-vectors.mjs";

const schema = JSON.parse(readFileSync(new URL("../protocol/vectors/vectors.schema.json", import.meta.url), "utf8"));
const validate = compileSchema(schema);
const SHA = "a".repeat(64);
const hashingDoc = (cases) => ({ schema_version: 1, kind: "hashing", description: "d", cases });
const exists = () => true;

test("accepts a valid hashing file", () => {
  const doc = hashingDoc([{ name: "empty", input: { generate: { pattern: "counter", length: 0 } }, expected_sha256: SHA }]);
  assert.deepEqual(validate(doc), []);
  assert.deepEqual(semanticErrors(doc, { dirKind: "hashing", fileExists: exists }), []);
});

test("rejects a malformed sha256", () => {
  const doc = hashingDoc([{ name: "bad", input: { inline_utf8: "abc" }, expected_sha256: "ABC" }]);
  assert.notDeepEqual(validate(doc), []);
});

test("rejects a kind that does not match its directory", () => {
  const doc = hashingDoc([{ name: "x", input: { inline_utf8: "" }, expected_sha256: SHA }]);
  assert.match(semanticErrors(doc, { dirKind: "pairing", fileExists: exists }).join("\n"), /kind "hashing" in pairing\//);
});

test("rejects a missing fixture file", () => {
  const doc = hashingDoc([{ name: "jpg", input: { file: "fixtures/none.jpg" }, expected_sha256: SHA }]);
  assert.match(semanticErrors(doc, { dirKind: "hashing", fileExists: () => false }).join("\n"), /fixtures\/none\.jpg does not exist/);
});

test("rejects duplicate case names within a kind", () => {
  const a = hashingDoc([{ name: "same", input: { inline_utf8: "" }, expected_sha256: SHA }]);
  const b = hashingDoc([{ name: "same", input: { inline_utf8: "x" }, expected_sha256: SHA }]);
  assert.match(duplicateNameErrors([a, b]).join("\n"), /duplicate hashing case "same"/);
});

test("rejects server-scenario steps that use undeclared actors", () => {
  const doc = {
    schema_version: 1, kind: "server-scenario", description: "d",
    cases: [{
      name: "s", actors: { device_a: { user: "alice" } },
      steps: [{ actor: "device_b", request: { method: "GET", path: "/api/v1/server/info" }, expect: { status: 200 } }],
    }],
  };
  assert.deepEqual(validate(doc), []);
  assert.match(semanticErrors(doc, { dirKind: "server-scenario", fileExists: exists }).join("\n"), /undeclared actor "device_b"/);
});

test("rejects an expectation with both status and no_response", () => {
  const doc = {
    schema_version: 1, kind: "server-scenario", description: "d",
    cases: [{ name: "s", actors: { a: { user: "u" } }, steps: [{ actor: "a", request: { method: "GET", path: "/x" }, expect: { status: 200, no_response: true } }] }],
  };
  assert.notDeepEqual(validate(doc), []);
});

test("rejects a client decision problem shorthand without a status", () => {
  const doc = {
    schema_version: 1, kind: "client-decision", description: "d",
    cases: [{ name: "c", given: { flow: "backup", last_action: "check" }, server: { transport: "timeout", problem: "internal" }, expect: { action: "backoff_retry" } }],
  };
  assert.match(semanticErrors(doc, { dirKind: "client-decision", fileExists: exists }).join("\n"), /problem requires status/);
});

test("reports kinds below their minimum case count", () => {
  const errors = minimumErrors({ hashing: 8, pairing: 3, "server-scenario": 14, "client-decision": 25 });
  assert.equal(errors.length, 1);
  assert.match(errors[0], /pairing: 3 cases, minimum 8/);
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `pnpm --dir api run test`
Expected: FAIL — cannot find module `./validate-vectors.mjs` (contract-rules tests still pass).

- [ ] **Step 4: Implement `api/tools/validate-vectors.mjs`**

```js
// Validates every conformance vector file against the schema plus semantic rules.
// Usage: node api/tools/validate-vectors.mjs [--strict]   (--strict also enforces minimum case counts)
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

export const MINIMUMS = { hashing: 8, "server-scenario": 14, "client-decision": 25, pairing: 8 };
export const DIR_KIND = { hashing: "hashing", pairing: "pairing", "server-scenarios": "server-scenario", "client-decisions": "client-decision" };

export function compileSchema(schema) {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const check = ajv.compile(schema);
  return (doc) => (check(doc) ? [] : check.errors.map((e) => `${e.instancePath || "/"} ${e.message}`));
}

export function semanticErrors(doc, { dirKind, fileExists }) {
  const errors = [];
  if (doc.kind !== dirKind) errors.push(`kind "${doc.kind}" in ${dirKind}/ directory`);
  for (const c of doc.cases ?? []) {
    if (doc.kind === "hashing" && c.input?.file && !fileExists(c.input.file)) {
      errors.push(`${c.name}: ${c.input.file} does not exist`);
    }
    if (doc.kind === "server-scenario") {
      const actors = new Set(Object.keys(c.actors ?? {}));
      for (const step of c.steps ?? []) {
        if (step.actor && !actors.has(step.actor)) errors.push(`${c.name}: undeclared actor "${step.actor}"`);
        for (const src of step.control?.assert_asset_sources?.sources ?? []) {
          if (!actors.has(src.actor)) errors.push(`${c.name}: undeclared actor "${src.actor}"`);
        }
      }
    }
    if (doc.kind === "client-decision" && c.server?.problem && c.server.status === undefined) {
      errors.push(`${c.name}: problem requires status`);
    }
  }
  return errors;
}

export function duplicateNameErrors(docs) {
  const seen = new Set();
  const errors = [];
  for (const doc of docs) {
    for (const c of doc.cases ?? []) {
      const key = `${doc.kind}/${c.name}`;
      if (seen.has(key)) errors.push(`duplicate ${doc.kind} case "${c.name}"`);
      seen.add(key);
    }
  }
  return errors;
}

export function minimumErrors(counts) {
  return Object.entries(MINIMUMS)
    .filter(([kind, min]) => (counts[kind] ?? 0) < min)
    .map(([kind, min]) => `${kind}: ${counts[kind] ?? 0} cases, minimum ${min}`);
}

export function validateAll(protocolDir, { strict }) {
  const schema = JSON.parse(readFileSync(join(protocolDir, "vectors", "vectors.schema.json"), "utf8"));
  const validate = compileSchema(schema);
  const errors = [];
  const docs = [];
  const counts = {};
  for (const [dir, kind] of Object.entries(DIR_KIND)) {
    const full = join(protocolDir, "vectors", dir);
    if (!existsSync(full)) continue;
    for (const file of readdirSync(full).filter((f) => f.endsWith(".json")).sort()) {
      const rel = `${dir}/${file}`;
      let doc;
      try {
        doc = JSON.parse(readFileSync(join(full, file), "utf8"));
      } catch (e) {
        errors.push(`${rel}: invalid JSON (${e.message})`);
        continue;
      }
      const fileExists = (p) => existsSync(join(protocolDir, p));
      for (const e of [...validate(doc), ...semanticErrors(doc, { dirKind: kind, fileExists })]) errors.push(`${rel}: ${e}`);
      docs.push(doc);
      counts[kind] = (counts[kind] ?? 0) + (doc.cases?.length ?? 0);
    }
  }
  errors.push(...duplicateNameErrors(docs));
  if (strict) errors.push(...minimumErrors(counts));
  return { errors, counts };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const protocolDir = fileURLToPath(new URL("../protocol", import.meta.url));
  const { errors, counts } = validateAll(protocolDir, { strict: process.argv.includes("--strict") });
  if (errors.length) {
    console.error(errors.join("\n"));
    process.exit(1);
  }
  console.log("vectors: ok", JSON.stringify(counts));
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pnpm --dir api run test`
Expected: PASS (contract-rules 11 + validate-vectors 9).

- [ ] **Step 6: Make the pnpm script strict and add the Taskfile task**

In `api/package.json` set `"vectors": "node tools/validate-vectors.mjs --strict"`.

Append to `Taskfile.yml`:
```yaml

  vectors:validate:
    desc: Validate conformance vectors (schema, semantics, minimum counts)
    cmds:
      - pnpm --dir api run vectors
```

- [ ] **Step 7: Commit**

```bash
git add api/protocol/vectors/vectors.schema.json api/tools/validate-vectors.mjs api/tools/validate-vectors.test.mjs api/package.json Taskfile.yml
git commit -s -m "feat(api): add conformance vector schema and validator"
```

---

### Task 10: Hashing vectors and media fixtures

**Files:**
- Create: `api/protocol/vectors/hashing/core.json`, `api/tools/make_fixtures.py`, `api/protocol/fixtures/tiny.jpg`, `api/protocol/fixtures/tiny.heic`, `api/protocol/fixtures/tiny.mp4`, `api/protocol/vectors/hashing/fixtures.json` (written by the script)

**Interfaces:**
- Consumes: Task 9 schema.
- Produces: 11 hashing cases consumed by the Go (Task 14), Kotlin (Task 17) and Swift (Task 18) runners. Fixtures are reused by server metadata tests in sub-project 2.

- [ ] **Step 1: Create `api/protocol/vectors/hashing/core.json`**

The expected values below were computed with Python `hashlib` (an independent oracle); `abc`, empty and one-zero-byte are also published SHA-256 test values.
```json
{
  "schema_version": 1,
  "kind": "hashing",
  "description": "Generated inputs around chunk boundaries. Counter pattern: byte i = (i + seed) mod 256.",
  "cases": [
    { "name": "abc_inline", "description": "FIPS 180-2 test vector.", "input": { "inline_utf8": "abc" }, "expected_sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
    { "name": "empty", "description": "Zero-length file.", "input": { "generate": { "pattern": "counter", "length": 0 } }, "expected_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
    { "name": "one_byte", "description": "Single 0x00 byte.", "input": { "generate": { "pattern": "counter", "length": 1 } }, "expected_sha256": "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d" },
    { "name": "counter_255", "input": { "generate": { "pattern": "counter", "length": 255 } }, "expected_sha256": "3f8591112c6bbe5c963965954e293108b7208ed2af893e500d859368c654eabe" },
    { "name": "counter_256", "input": { "generate": { "pattern": "counter", "length": 256 } }, "expected_sha256": "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
    { "name": "chunk_8mib", "description": "Exactly one default chunk.", "input": { "generate": { "pattern": "counter", "length": 8388608 } }, "expected_sha256": "7d212b9c884f5c77896de960ae17cc341cda43b14d6a971f34ca29ebd4badf7f" },
    { "name": "chunk_8mib_plus_1", "description": "One byte past a chunk boundary.", "input": { "generate": { "pattern": "counter", "length": 8388609 } }, "expected_sha256": "241ca9a8e51ef578c06db1c5ed27d8018eb6515d3427ca9b9a84d5e93bcce2ae" },
    { "name": "large_64mib_plus_1", "description": "One byte past the iOS background chunk size.", "input": { "generate": { "pattern": "counter", "length": 67108865 } }, "expected_sha256": "1c59ac3e75dad72b9911b18b7b02db7e848c6d8f04946284be2311f94a1f6a2f" }
  ]
}
```

- [ ] **Step 2: Create `api/tools/make_fixtures.py`**

```python
"""Generate tiny real-format media fixtures and their hashing vectors.

Encoders are not byte-for-byte reproducible, so run this only when adding fixtures:
    uv run --with pillow --with pillow-heif --with imageio-ffmpeg python api/tools/make_fixtures.py
"""
import hashlib
import json
import subprocess
from pathlib import Path

import imageio_ffmpeg
import pillow_heif
from PIL import Image

PROTOCOL = Path(__file__).resolve().parent.parent / "protocol"
FIXTURES = PROTOCOL / "fixtures"
EXIF_IFD = 0x8769
DATETIME_ORIGINAL = 0x9003
TAKEN = "2024:05:06 10:00:00"
MAX_BYTES = 64 * 1024


def gradient(size: int = 16) -> Image.Image:
    img = Image.new("RGB", (size, size))
    img.putdata([(x * 16 % 256, y * 16 % 256, 128) for y in range(size) for x in range(size)])
    return img


def make_jpeg(path: Path) -> None:
    img = gradient()
    exif = img.getexif()
    exif.get_ifd(EXIF_IFD)[DATETIME_ORIGINAL] = TAKEN
    img.save(path, "JPEG", quality=85, exif=exif)


def make_heic(path: Path) -> None:
    pillow_heif.register_heif_opener()
    gradient().save(path, "HEIF", quality=50)


def make_mp4(path: Path) -> None:
    subprocess.run(
        [
            imageio_ffmpeg.get_ffmpeg_exe(), "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc=size=16x16:rate=10:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            "-metadata", "creation_time=2024-05-06T10:00:00Z",
            "-movflags", "+faststart", str(path),
        ],
        check=True,
    )


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    makers = {"tiny.jpg": make_jpeg, "tiny.heic": make_heic, "tiny.mp4": make_mp4}
    cases = []
    for name, make in makers.items():
        path = FIXTURES / name
        make(path)
        size = path.stat().st_size
        assert size < MAX_BYTES, f"{name} is {size} bytes; fixtures must stay under 64 KiB"
        cases.append(
            {
                "name": "fixture_" + name.replace(".", "_"),
                "description": f"Real {name.split('.')[-1].upper()} file ({size} bytes), dated 2024-05-06T10:00:00Z.",
                "input": {"file": f"fixtures/{name}"},
                "expected_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
        )
    doc = {"schema_version": 1, "kind": "hashing", "description": "Hashes of small real media files.", "cases": cases}
    target = PROTOCOL / "vectors" / "hashing" / "fixtures.json"
    target.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8", newline="\n")
    for case in cases:
        print(case["name"], case["expected_sha256"])


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Generate the fixtures**

Run: `uv run --with pillow --with pillow-heif --with imageio-ffmpeg python api/tools/make_fixtures.py`
Expected: three lines `fixture_tiny_jpg <hash>`, `fixture_tiny_heic <hash>`, `fixture_tiny_mp4 <hash>`.

- [ ] **Step 4: Cross-check with an independent tool**

Run: `sha256sum api/protocol/fixtures/*`
Expected: each hash equals the matching `expected_sha256` in `api/protocol/vectors/hashing/fixtures.json`.

- [ ] **Step 5: Validate**

Run: `node api/tools/validate-vectors.mjs`
Expected: `vectors: ok {"hashing":11}`.

- [ ] **Step 6: Commit**

```bash
git add api/protocol/vectors/hashing api/protocol/fixtures api/tools/make_fixtures.py
git commit -s -m "test(api): add hashing vectors and media fixtures"
```

---

### Task 11: Pairing vectors

**Files:**
- Create: `api/protocol/vectors/pairing/qr.json`

**Interfaces:**
- Consumes: Task 9 schema; spec §6.3 (URI format, pinning rule).
- Produces: 12 pairing cases for the Dart/Kotlin/Swift pairing parsers (sub-project 3). Fingerprints are base64url SHA-256 of the strings `pictunnel-test-spki` (`xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc`), `attacker-spki` (`z0pEXVjYOhc0CN5i-OUFDhR6-JaPwKtubUrYBPzrVy4`) and `public-ca-spki` (`Hb2lReT4Ad1PYf3e03tI4L2OhxWfypH885LfrVnAcb4`).

Parse rules the cases encode: scheme must be `pictunnel` with host `pair`; `v` must be `1`; `sid` required; `code` must match `^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{2}$`; `fp` required; at least one `u`; every `u` must be `https://`; duplicate `u` values are dropped keeping first occurrence order. Connection rule: accept when `system_trusted` is true, otherwise only when `spki_sha256 == fp`.

- [ ] **Step 1: Create `api/protocol/vectors/pairing/qr.json`**

```json
{
  "schema_version": 1,
  "kind": "pairing",
  "description": "QR pairing URI parsing and certificate pinning decisions (sync-protocol.md §6.3).",
  "cases": [
    {
      "name": "valid_two_endpoints",
      "uri": "pictunnel://pair?v=1&sid=01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f&code=K7Q2-M9XD-4T&fp=xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc&u=https%3A%2F%2F192.168.1.20%3A8443&u=https%3A%2F%2Fphotos.example.com",
      "expect": {
        "parse": "ok",
        "server_id": "01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f",
        "code": "K7Q2-M9XD-4T",
        "fingerprint": "xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc",
        "endpoints": ["https://192.168.1.20:8443", "https://photos.example.com"]
      }
    },
    {
      "name": "missing_fingerprint",
      "uri": "pictunnel://pair?v=1&sid=01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f&code=K7Q2-M9XD-4T&u=https%3A%2F%2F192.168.1.20%3A8443",
      "expect": { "parse": "error", "error": "missing_fingerprint" }
    },
    {
      "name": "unsupported_version",
      "uri": "pictunnel://pair?v=2&sid=01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f&code=K7Q2-M9XD-4T&fp=xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc&u=https%3A%2F%2F192.168.1.20%3A8443",
      "expect": { "parse": "error", "error": "unsupported_version" }
    },
    {
      "name": "malformed_code",
      "description": "Contains the letter I, which Crockford base32 excludes.",
      "uri": "pictunnel://pair?v=1&sid=01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f&code=KIQ2-M9XD-4T&fp=xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc&u=https%3A%2F%2F192.168.1.20%3A8443",
      "expect": { "parse": "error", "error": "invalid_code" }
    },
    {
      "name": "missing_server_id",
      "uri": "pictunnel://pair?v=1&code=K7Q2-M9XD-4T&fp=xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc&u=https%3A%2F%2F192.168.1.20%3A8443",
      "expect": { "parse": "error", "error": "missing_server_id" }
    },
    {
      "name": "no_endpoints",
      "uri": "pictunnel://pair?v=1&sid=01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f&code=K7Q2-M9XD-4T&fp=xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc",
      "expect": { "parse": "error", "error": "missing_endpoint" }
    },
    {
      "name": "insecure_endpoint",
      "uri": "pictunnel://pair?v=1&sid=01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f&code=K7Q2-M9XD-4T&fp=xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc&u=http%3A%2F%2F192.168.1.20%3A8080",
      "expect": { "parse": "error", "error": "insecure_endpoint" }
    },
    {
      "name": "wrong_scheme",
      "uri": "https://pair?v=1&sid=01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f&code=K7Q2-M9XD-4T&fp=xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc&u=https%3A%2F%2F192.168.1.20%3A8443",
      "expect": { "parse": "error", "error": "invalid_scheme" }
    },
    {
      "name": "duplicate_endpoints_deduplicated",
      "uri": "pictunnel://pair?v=1&sid=01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f&code=K7Q2-M9XD-4T&fp=xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc&u=https%3A%2F%2F192.168.1.20%3A8443&u=https%3A%2F%2Fphotos.example.com&u=https%3A%2F%2F192.168.1.20%3A8443",
      "expect": { "parse": "ok", "endpoints": ["https://192.168.1.20:8443", "https://photos.example.com"] }
    },
    {
      "name": "pin_match_self_signed",
      "uri": "pictunnel://pair?v=1&sid=01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f&code=K7Q2-M9XD-4T&fp=xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc&u=https%3A%2F%2F192.168.1.20%3A8443",
      "connection": { "endpoint": "https://192.168.1.20:8443", "system_trusted": false, "spki_sha256": "xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc" },
      "expect": { "parse": "ok", "accept_connection": true }
    },
    {
      "name": "pin_mismatch_self_signed",
      "uri": "pictunnel://pair?v=1&sid=01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f&code=K7Q2-M9XD-4T&fp=xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc&u=https%3A%2F%2F192.168.1.20%3A8443",
      "connection": { "endpoint": "https://192.168.1.20:8443", "system_trusted": false, "spki_sha256": "z0pEXVjYOhc0CN5i-OUFDhR6-JaPwKtubUrYBPzrVy4" },
      "expect": { "parse": "ok", "accept_connection": false }
    },
    {
      "name": "public_ca_endpoint_accepted",
      "description": "A reverse proxy with a publicly trusted certificate is accepted even though its key differs from fp.",
      "uri": "pictunnel://pair?v=1&sid=01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f&code=K7Q2-M9XD-4T&fp=xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc&u=https%3A%2F%2Fphotos.example.com",
      "connection": { "endpoint": "https://photos.example.com", "system_trusted": true, "spki_sha256": "Hb2lReT4Ad1PYf3e03tI4L2OhxWfypH885LfrVnAcb4" },
      "expect": { "parse": "ok", "accept_connection": true }
    }
  ]
}
```

- [ ] **Step 2: Validate**

Run: `node api/tools/validate-vectors.mjs`
Expected: `vectors: ok {"hashing":11,"pairing":12}`.

- [ ] **Step 3: Commit**

```bash
git add api/protocol/vectors/pairing
git commit -s -m "test(api): add pairing URI and pinning vectors"
```

---

### Task 12: Server-scenario vectors

**Files:**
- Create: `api/protocol/vectors/server-scenarios/uploads.json`, `tombstones.json`, `sync.json`, `library.json`

**Interfaces:**
- Consumes: Task 9 schema; payload constants A, B, C, V from Global Constraints; spec §7.
- Produces: 17 scenarios executed by the Go conformance runner in sub-project 2. Runner semantics (documented in Task 21): each case starts on a fresh server; actors are created as users/devices and their bearer token is injected; `tus_metadata` is encoded as `key base64(value)` pairs in the given order; `Location` values are normalized to paths; matchers `$any`, `$uuid`, `$int`, `$sha256`, `$datetime`, `${var}`; body matching is a subset match and arrays match as ordered subsequences; `{"$len": n}` matches an array of exactly n items.

- [ ] **Step 1: Create `api/protocol/vectors/server-scenarios/uploads.json`**

```json
{
  "schema_version": 1,
  "kind": "server-scenario",
  "description": "tus upload creation, resume, idempotency and finalize verification (sync-protocol.md §7.3-7.4).",
  "cases": [
    {
      "name": "fresh_upload_chunked",
      "description": "Check reports missing; a bodyless create plus one PATCH uploads the file; the next check reports exists.",
      "actors": { "device_a": { "user": "alice", "platform": "android" } },
      "steps": [
        {
          "actor": "device_a",
          "request": { "method": "POST", "path": "/api/v1/sync/check", "json": { "items": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "size_bytes": 1048576, "local_id": "a-1" }] } },
          "expect": { "status": 200, "body": { "results": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "verdict": "missing" }] } }
        },
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.JPG", "mime": "image/jpeg", "local_id": "a-1" }
          },
          "expect": { "status": 201, "headers": { "Location": "$any" } },
          "save": { "upload": "header:Location" }
        },
        {
          "actor": "device_a",
          "request": {
            "method": "PATCH", "path": "${upload}",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Offset": "0", "Content-Type": "application/offset+octet-stream" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 1048576 } }
          },
          "expect": { "status": 204, "headers": { "Upload-Offset": "1048576", "PicTunnel-Asset-Id": "$uuid", "PicTunnel-Asset-Created": "true" } },
          "save": { "asset": "header:PicTunnel-Asset-Id" }
        },
        {
          "actor": "device_a",
          "request": { "method": "POST", "path": "/api/v1/sync/check", "json": { "items": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "size_bytes": 1048576 }] } },
          "expect": { "status": 200, "body": { "results": [{ "verdict": "exists", "asset_id": "${asset}", "asset_state": "active" }] } }
        },
        {
          "actor": "device_a",
          "request": { "method": "GET", "path": "/api/v1/assets/${asset}" },
          "expect": { "status": 200, "body": { "id": "${asset}", "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "size_bytes": 1048576, "filename": "IMG_0001.JPG", "kind": "photo", "state": "active" } }
        }
      ]
    },
    {
      "name": "creation_with_upload_single_shot",
      "description": "The whole file in the create request (iOS background profile) finalizes immediately.",
      "actors": { "device_a": { "user": "alice", "platform": "ios" } },
      "steps": [
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.HEIC", "mime": "image/heic" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 1048576 } }
          },
          "expect": { "status": 201, "headers": { "Location": "$any", "Upload-Offset": "1048576", "PicTunnel-Asset-Id": "$uuid", "PicTunnel-Asset-Created": "true" } }
        }
      ]
    },
    {
      "name": "resume_after_drop",
      "description": "A connection dropped mid-PATCH resumes from the offset reported by HEAD.",
      "actors": { "device_a": { "user": "alice", "platform": "android" } },
      "steps": [
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "3145728" },
            "tus_metadata": { "sha256": "f6dd7fec8584ad00219a447071c1fa368a1caee4d9c146083d233713ddccd2c0", "filename": "VID_0001.MP4", "mime": "video/mp4" }
          },
          "expect": { "status": 201 },
          "save": { "upload": "header:Location" }
        },
        {
          "actor": "device_a",
          "request": {
            "method": "PATCH", "path": "${upload}",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Offset": "0", "Content-Type": "application/offset+octet-stream" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 3145728 } }
          },
          "transport": { "drop_after_bytes": 1000000 },
          "expect": { "no_response": true }
        },
        {
          "actor": "device_a",
          "request": { "method": "HEAD", "path": "${upload}", "headers": { "Tus-Resumable": "1.0.0" } },
          "expect": { "status": 200, "headers": { "Upload-Offset": "$int", "Upload-Length": "3145728" } },
          "save": { "offset": "header:Upload-Offset" }
        },
        {
          "actor": "device_a",
          "request": {
            "method": "PATCH", "path": "${upload}",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Offset": "${offset}", "Content-Type": "application/offset+octet-stream" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 3145728, "start": "${offset}" } }
          },
          "expect": { "status": 204, "headers": { "Upload-Offset": "3145728", "PicTunnel-Asset-Id": "$uuid", "PicTunnel-Asset-Created": "true" } }
        }
      ]
    },
    {
      "name": "duplicate_post_returns_same_session",
      "description": "Retrying a create for the same content returns the existing session.",
      "actors": { "device_a": { "user": "alice", "platform": "android" } },
      "steps": [
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.JPG", "mime": "image/jpeg" }
          },
          "expect": { "status": 201 },
          "save": { "first": "header:Location" }
        },
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.JPG", "mime": "image/jpeg" }
          },
          "expect": { "status": 201, "headers": { "Location": "${first}", "Upload-Offset": "0" } }
        }
      ]
    },
    {
      "name": "existing_asset_short_circuit",
      "description": "Creating an upload for content that already exists resolves to the existing asset without storing bytes.",
      "actors": { "device_a": { "user": "alice", "platform": "android" } },
      "steps": [
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.JPG", "mime": "image/jpeg" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 1048576 } }
          },
          "expect": { "status": 201, "headers": { "PicTunnel-Asset-Created": "true" } },
          "save": { "asset": "header:PicTunnel-Asset-Id" }
        },
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001 copy.JPG", "mime": "image/jpeg" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 1048576 } }
          },
          "expect": { "status": 201, "headers": { "Upload-Offset": "1048576", "PicTunnel-Asset-Id": "${asset}", "PicTunnel-Asset-Created": "false" } },
          "save": { "second": "header:Location" }
        },
        {
          "actor": "device_a",
          "request": { "method": "HEAD", "path": "${second}", "headers": { "Tus-Resumable": "1.0.0" } },
          "expect": { "status": 200, "headers": { "Upload-Offset": "1048576", "Upload-Length": "1048576", "PicTunnel-Asset-Id": "${asset}" } }
        }
      ]
    },
    {
      "name": "two_devices_same_hash_cooperative",
      "description": "Two devices of one user upload the same video; the second continues the first's session and both see one asset.",
      "actors": { "device_a": { "user": "alice", "platform": "android" }, "device_b": { "user": "alice", "platform": "ios" } },
      "steps": [
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "3145728" },
            "tus_metadata": { "sha256": "f6dd7fec8584ad00219a447071c1fa368a1caee4d9c146083d233713ddccd2c0", "filename": "VID_0009.MP4", "mime": "video/mp4", "local_id": "a-9" }
          },
          "expect": { "status": 201 },
          "save": { "upload": "header:Location" }
        },
        {
          "actor": "device_a",
          "request": {
            "method": "PATCH", "path": "${upload}",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Offset": "0", "Content-Type": "application/offset+octet-stream" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 3145728, "start": 0, "end": 1048576 } }
          },
          "expect": { "status": 204, "headers": { "Upload-Offset": "1048576" } }
        },
        {
          "actor": "device_b",
          "request": { "method": "POST", "path": "/api/v1/sync/check", "json": { "items": [{ "sha256": "f6dd7fec8584ad00219a447071c1fa368a1caee4d9c146083d233713ddccd2c0", "size_bytes": 3145728, "local_id": "b-3" }] } },
          "expect": { "status": 200, "body": { "results": [{ "verdict": "partial", "upload": { "offset": 1048576, "length": 3145728 } }] } }
        },
        {
          "actor": "device_b",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "3145728" },
            "tus_metadata": { "sha256": "f6dd7fec8584ad00219a447071c1fa368a1caee4d9c146083d233713ddccd2c0", "filename": "IMG_7731.MOV", "mime": "video/mp4", "local_id": "b-3" }
          },
          "expect": { "status": 201, "headers": { "Location": "${upload}", "Upload-Offset": "1048576" } }
        },
        {
          "actor": "device_b",
          "request": {
            "method": "PATCH", "path": "${upload}",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Offset": "1048576", "Content-Type": "application/offset+octet-stream" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 3145728, "start": 1048576 } }
          },
          "expect": { "status": 204, "headers": { "Upload-Offset": "3145728", "PicTunnel-Asset-Id": "$uuid", "PicTunnel-Asset-Created": "true" } },
          "save": { "asset": "header:PicTunnel-Asset-Id" }
        },
        {
          "actor": "device_a",
          "request": { "method": "HEAD", "path": "${upload}", "headers": { "Tus-Resumable": "1.0.0" } },
          "expect": { "status": 200, "headers": { "Upload-Offset": "3145728", "PicTunnel-Asset-Id": "${asset}" } }
        },
        {
          "actor": "device_a",
          "request": { "method": "POST", "path": "/api/v1/sync/check", "json": { "items": [{ "sha256": "f6dd7fec8584ad00219a447071c1fa368a1caee4d9c146083d233713ddccd2c0", "size_bytes": 3145728 }] } },
          "expect": { "status": 200, "body": { "results": [{ "verdict": "exists", "asset_id": "${asset}" }] } }
        }
      ]
    },
    {
      "name": "checksum_mismatch_rejects",
      "description": "Bytes that do not hash to the declared sha256 are rejected and nothing is stored.",
      "actors": { "device_a": { "user": "alice", "platform": "android" } },
      "steps": [
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.JPG", "mime": "image/jpeg" },
            "body": { "generate": { "pattern": "counter", "seed": 1, "length": 1048576 } }
          },
          "expect": { "status": 460, "body": { "code": "checksum_mismatch" } }
        },
        {
          "actor": "device_a",
          "request": { "method": "POST", "path": "/api/v1/sync/check", "json": { "items": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "size_bytes": 1048576 }] } },
          "expect": { "status": 200, "body": { "results": [{ "verdict": "missing" }] } }
        }
      ]
    },
    {
      "name": "offset_mismatch_reports_offset",
      "description": "A PATCH at the wrong offset is rejected with the server's current offset.",
      "actors": { "device_a": { "user": "alice", "platform": "android" } },
      "steps": [
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.JPG", "mime": "image/jpeg" }
          },
          "expect": { "status": 201 },
          "save": { "upload": "header:Location" }
        },
        {
          "actor": "device_a",
          "request": {
            "method": "PATCH", "path": "${upload}",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Offset": "100", "Content-Type": "application/offset+octet-stream" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 1048576, "start": 100 } }
          },
          "expect": { "status": 409, "headers": { "Upload-Offset": "0" }, "body": { "code": "offset_mismatch" } }
        }
      ]
    },
    {
      "name": "length_mismatch_rejected",
      "description": "A create for the same hash with a different length is a client bug and is rejected.",
      "actors": { "device_a": { "user": "alice", "platform": "android" } },
      "steps": [
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.JPG", "mime": "image/jpeg" }
          },
          "expect": { "status": 201 }
        },
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048577" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.JPG", "mime": "image/jpeg" }
          },
          "expect": { "status": 409, "body": { "code": "length_mismatch" } }
        }
      ]
    }
  ]
}
```

- [ ] **Step 2: Create `api/protocol/vectors/server-scenarios/tombstones.json`**

```json
{
  "schema_version": 1,
  "kind": "server-scenario",
  "description": "Trash, purge and tombstones (sync-protocol.md §7.7).",
  "cases": [
    {
      "name": "tombstone_blocks_upload",
      "description": "Purged content is reported as tombstoned and its upload is refused.",
      "actors": { "device_a": { "user": "alice", "platform": "android" } },
      "steps": [
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.JPG", "mime": "image/jpeg" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 1048576 } }
          },
          "expect": { "status": 201 },
          "save": { "asset": "header:PicTunnel-Asset-Id" }
        },
        {
          "actor": "device_a",
          "request": { "method": "POST", "path": "/api/v1/assets/trash", "json": { "asset_ids": ["${asset}"] } },
          "expect": { "status": 200, "body": { "succeeded": ["${asset}"] } }
        },
        {
          "actor": "device_a",
          "request": { "method": "POST", "path": "/api/v1/assets/purge", "json": { "asset_ids": ["${asset}"] } },
          "expect": { "status": 200, "body": { "succeeded": ["${asset}"] } }
        },
        {
          "actor": "device_a",
          "request": { "method": "POST", "path": "/api/v1/sync/check", "json": { "items": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "size_bytes": 1048576 }] } },
          "expect": { "status": 200, "body": { "results": [{ "verdict": "tombstoned", "deleted_at": "$datetime" }] } }
        },
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.JPG", "mime": "image/jpeg" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 1048576 } }
          },
          "expect": { "status": 409, "body": { "code": "tombstoned" } }
        },
        {
          "actor": "device_a",
          "request": { "method": "GET", "path": "/api/v1/tombstones" },
          "expect": { "status": 200, "body": { "tombstones": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.JPG" }] } }
        }
      ]
    },
    {
      "name": "tombstone_override",
      "description": "Uploading with override_tombstone=1 stores the content again and clears the tombstone.",
      "actors": { "device_a": { "user": "alice", "platform": "android" } },
      "steps": [
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.JPG", "mime": "image/jpeg" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 1048576 } }
          },
          "expect": { "status": 201 },
          "save": { "asset": "header:PicTunnel-Asset-Id" }
        },
        {
          "actor": "device_a",
          "request": { "method": "POST", "path": "/api/v1/assets/trash", "json": { "asset_ids": ["${asset}"] } },
          "expect": { "status": 200 }
        },
        {
          "actor": "device_a",
          "request": { "method": "POST", "path": "/api/v1/assets/purge", "json": { "asset_ids": ["${asset}"] } },
          "expect": { "status": 200 }
        },
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.JPG", "mime": "image/jpeg", "override_tombstone": "1" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 1048576 } }
          },
          "expect": { "status": 201, "headers": { "PicTunnel-Asset-Id": "$uuid", "PicTunnel-Asset-Created": "true" } },
          "save": { "asset2": "header:PicTunnel-Asset-Id" }
        },
        {
          "actor": "device_a",
          "request": { "method": "GET", "path": "/api/v1/tombstones" },
          "expect": { "status": 200, "body": { "tombstones": { "$len": 0 } } }
        },
        {
          "actor": "device_a",
          "request": { "method": "POST", "path": "/api/v1/sync/check", "json": { "items": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "size_bytes": 1048576 }] } },
          "expect": { "status": 200, "body": { "results": [{ "verdict": "exists", "asset_id": "${asset2}" }] } }
        }
      ]
    }
  ]
}
```

- [ ] **Step 3: Create `api/protocol/vectors/server-scenarios/sync.json`**

```json
{
  "schema_version": 1,
  "kind": "server-scenario",
  "description": "Check side effects, snapshot plus change feed, cursor rules (sync-protocol.md §7.2, §7.6).",
  "cases": [
    {
      "name": "check_links_sources",
      "description": "An exists verdict links the caller's local_id to the asset, idempotently.",
      "actors": { "device_a": { "user": "alice", "platform": "android" }, "device_b": { "user": "alice", "platform": "ios" } },
      "steps": [
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.JPG", "mime": "image/jpeg", "local_id": "a-1" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 1048576 } }
          },
          "expect": { "status": 201 },
          "save": { "asset": "header:PicTunnel-Asset-Id" }
        },
        {
          "actor": "device_b",
          "request": { "method": "POST", "path": "/api/v1/sync/check", "json": { "items": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "size_bytes": 1048576, "local_id": "b-7" }] } },
          "expect": { "status": 200, "body": { "results": [{ "verdict": "exists", "asset_id": "${asset}" }] } }
        },
        {
          "control": { "assert_asset_sources": { "asset": "${asset}", "sources": [{ "actor": "device_a", "local_id": "a-1" }, { "actor": "device_b", "local_id": "b-7" }] } }
        },
        {
          "actor": "device_b",
          "request": { "method": "POST", "path": "/api/v1/sync/check", "json": { "items": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "size_bytes": 1048576, "local_id": "b-7" }] } },
          "expect": { "status": 200, "body": { "results": [{ "verdict": "exists", "asset_id": "${asset}" }] } }
        },
        {
          "control": { "assert_asset_sources": { "asset": "${asset}", "sources": [{ "actor": "device_a", "local_id": "a-1" }, { "actor": "device_b", "local_id": "b-7" }] } }
        }
      ]
    },
    {
      "name": "snapshot_changes_overlap",
      "description": "Changes made after a snapshot are delivered by the feed from the snapshot cursor.",
      "actors": { "device_a": { "user": "alice", "platform": "android" } },
      "steps": [
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.JPG", "mime": "image/jpeg" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 1048576 } }
          },
          "expect": { "status": 201 },
          "save": { "asset_a": "header:PicTunnel-Asset-Id" }
        },
        {
          "actor": "device_a",
          "request": { "method": "GET", "path": "/api/v1/sync/snapshot" },
          "expect": { "status": 200, "body": { "cursor": "$any", "assets": [{ "id": "${asset_a}" }], "has_more": false } },
          "save": { "cursor": "body:/cursor" }
        },
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "18af9b054114c04a1eb836533a3e760dfa9dc53934ecb02fc059ff27150e77fb", "filename": "IMG_0002.JPG", "mime": "image/jpeg" },
            "body": { "generate": { "pattern": "counter", "seed": 1, "length": 1048576 } }
          },
          "expect": { "status": 201 },
          "save": { "asset_b": "header:PicTunnel-Asset-Id" }
        },
        {
          "actor": "device_a",
          "request": { "method": "POST", "path": "/api/v1/assets/trash", "json": { "asset_ids": ["${asset_a}"] } },
          "expect": { "status": 200 }
        },
        {
          "actor": "device_a",
          "request": { "method": "GET", "path": "/api/v1/sync/changes?cursor=${cursor}" },
          "expect": {
            "status": 200,
            "body": {
              "changes": [
                { "kind": "asset.upsert", "asset": { "id": "${asset_b}", "state": "active" } },
                { "kind": "asset.upsert", "asset": { "id": "${asset_a}", "state": "trashed" } }
              ],
              "has_more": false
            }
          }
        }
      ]
    },
    {
      "name": "cursor_expired_requires_snapshot",
      "description": "A cursor older than the 90-day retention is rejected with 410.",
      "actors": { "device_a": { "user": "alice", "platform": "android" } },
      "steps": [
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0001.JPG", "mime": "image/jpeg" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 1048576 } }
          },
          "expect": { "status": 201 }
        },
        {
          "actor": "device_a",
          "request": { "method": "GET", "path": "/api/v1/sync/snapshot" },
          "expect": { "status": 200 },
          "save": { "cursor": "body:/cursor" }
        },
        { "control": { "advance_clock_seconds": 7862400 } },
        { "control": { "run_job": "compact_change_log" } },
        {
          "actor": "device_a",
          "request": { "method": "GET", "path": "/api/v1/sync/changes?cursor=${cursor}" },
          "expect": { "status": 410, "body": { "code": "cursor_expired" } }
        }
      ]
    },
    {
      "name": "changes_without_cursor_rejected",
      "description": "The feed requires a cursor so clients always start from a snapshot.",
      "actors": { "device_a": { "user": "alice", "platform": "web" } },
      "steps": [
        {
          "actor": "device_a",
          "request": { "method": "GET", "path": "/api/v1/sync/changes" },
          "expect": { "status": 400, "body": { "code": "cursor_required" } }
        }
      ]
    }
  ]
}
```

- [ ] **Step 4: Create `api/protocol/vectors/server-scenarios/library.json`**

```json
{
  "schema_version": 1,
  "kind": "server-scenario",
  "description": "Library path assignment and Live Photo pairing (sync-protocol.md §5 H4, §7.5).",
  "cases": [
    {
      "name": "unicode_and_case_collision_paths",
      "description": "Names differing only by case collide on case-insensitive filesystems; the second gets ~2 and both keep their original UTF-8 names.",
      "actors": { "device_a": { "user": "alice", "platform": "ios" } },
      "steps": [
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "Photo 🙂.JPG", "mime": "image/jpeg", "created_at": "2024-05-06T10:00:00Z" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 1048576 } }
          },
          "expect": { "status": 201 }
        },
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "18af9b054114c04a1eb836533a3e760dfa9dc53934ecb02fc059ff27150e77fb", "filename": "photo 🙂.jpg", "mime": "image/jpeg", "created_at": "2024-05-06T10:00:00Z" },
            "body": { "generate": { "pattern": "counter", "seed": 1, "length": 1048576 } }
          },
          "expect": { "status": 201 },
          "save": { "second": "header:PicTunnel-Asset-Id" }
        },
        {
          "actor": "device_a",
          "request": { "method": "GET", "path": "/api/v1/assets/${second}" },
          "expect": { "status": 200, "body": { "filename": "photo 🙂.jpg" } }
        },
        {
          "control": { "assert_library_paths": { "user": "alice", "paths": ["alice/2024/05/Photo 🙂.JPG", "alice/2024/05/photo 🙂~2.jpg"] } }
        }
      ]
    },
    {
      "name": "live_video_requires_primary",
      "description": "A Live Photo video component is rejected until its still exists, then attaches to it.",
      "actors": { "device_a": { "user": "alice", "platform": "ios" } },
      "steps": [
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "c11788fa01aebe9ddeadf2d6fd661693d75a0ca28dc957a6042b5ff6d8a08e66", "filename": "IMG_0003.MOV", "mime": "video/quicktime", "pair_role": "live_video", "pair_sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83" },
            "body": { "generate": { "pattern": "counter", "seed": 2, "length": 1048576 } }
          },
          "expect": { "status": 409, "body": { "code": "pair_primary_missing" } }
        },
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "filename": "IMG_0003.HEIC", "mime": "image/heic", "pair_role": "primary" },
            "body": { "generate": { "pattern": "counter", "seed": 0, "length": 1048576 } }
          },
          "expect": { "status": 201 },
          "save": { "asset": "header:PicTunnel-Asset-Id" }
        },
        {
          "actor": "device_a",
          "request": { "method": "POST", "path": "/api/v1/sync/check", "json": { "items": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "size_bytes": 1048576 }] } },
          "expect": { "status": 200, "body": { "results": [{ "verdict": "exists", "has_live_video": false }] } }
        },
        {
          "actor": "device_a",
          "request": {
            "method": "POST", "path": "/api/v1/uploads",
            "headers": { "Tus-Resumable": "1.0.0", "Upload-Length": "1048576", "Content-Type": "application/offset+octet-stream" },
            "tus_metadata": { "sha256": "c11788fa01aebe9ddeadf2d6fd661693d75a0ca28dc957a6042b5ff6d8a08e66", "filename": "IMG_0003.MOV", "mime": "video/quicktime", "pair_role": "live_video", "pair_sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83" },
            "body": { "generate": { "pattern": "counter", "seed": 2, "length": 1048576 } }
          },
          "expect": { "status": 201, "headers": { "PicTunnel-Asset-Id": "${asset}" } }
        },
        {
          "actor": "device_a",
          "request": { "method": "POST", "path": "/api/v1/sync/check", "json": { "items": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "size_bytes": 1048576 }] } },
          "expect": { "status": 200, "body": { "results": [{ "verdict": "exists", "has_live_video": true }] } }
        },
        {
          "actor": "device_a",
          "request": { "method": "GET", "path": "/api/v1/assets/${asset}" },
          "expect": { "status": 200, "body": { "kind": "live_photo", "live_video": { "sha256": "c11788fa01aebe9ddeadf2d6fd661693d75a0ca28dc957a6042b5ff6d8a08e66" } } }
        }
      ]
    }
  ]
}
```

- [ ] **Step 5: Validate**

Run: `node api/tools/validate-vectors.mjs`
Expected: `vectors: ok {"hashing":11,"pairing":12,"server-scenario":17}`.

- [ ] **Step 6: Commit**

```bash
git add api/protocol/vectors/server-scenarios
git commit -s -m "test(api): add server-scenario conformance vectors"
```

---

### Task 13: Client-decision vectors

**Files:**
- Create: `api/protocol/vectors/client-decisions/check-verdicts.json`, `create-upload.json`, `append-upload.json`, `auth-browse-setup.json`, `free-up-space.json`

**Interfaces:**
- Consumes: Task 9 schema; spec §8 (problem catalogue) and §9 (R1–R11).
- Produces: 51 cases consumed by the Kotlin and Swift engine state machines (sub-project 3). `server.problem: "<code>"` means the runner synthesizes `{"type":"urn:pictunnel:problem:<code>","title":"<code>","status":<status>,"code":"<code>"}`. Every one of the 24 problem codes appears at least once.

- [ ] **Step 1: Create `check-verdicts.json`**

```json
{
  "schema_version": 1,
  "kind": "client-decision",
  "description": "Engine reactions to /sync/check results (sync-protocol.md §7.2, R2, R5, R7).",
  "cases": [
    { "name": "check_exists_active", "given": { "flow": "backup", "item_state": "Hashed", "last_action": "check", "item": { "kind": "photo" } }, "server": { "status": 200, "json": { "results": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "verdict": "exists", "asset_id": "01928f40-0000-7000-8000-000000000001", "asset_state": "active" }] } }, "expect": { "next_state": "BackedUp", "action": "mark_backed_up", "attempts_delta": 0 } },
    { "name": "check_exists_trashed", "description": "Content in the server trash counts as backed up.", "given": { "flow": "backup", "item_state": "Hashed", "last_action": "check", "item": { "kind": "photo" } }, "server": { "status": 200, "json": { "results": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "verdict": "exists", "asset_id": "01928f40-0000-7000-8000-000000000001", "asset_state": "trashed" }] } }, "expect": { "next_state": "BackedUp", "action": "mark_backed_up", "attempts_delta": 0 } },
    { "name": "check_missing", "given": { "flow": "backup", "item_state": "Hashed", "last_action": "check", "item": { "kind": "photo" } }, "server": { "status": 200, "json": { "results": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "verdict": "missing" }] } }, "expect": { "next_state": "Queued", "action": "queue_upload", "attempts_delta": 0 } },
    { "name": "check_partial", "given": { "flow": "backup", "item_state": "Hashed", "last_action": "check", "item": { "kind": "video" } }, "server": { "status": 200, "json": { "results": [{ "sha256": "f6dd7fec8584ad00219a447071c1fa368a1caee4d9c146083d233713ddccd2c0", "verdict": "partial", "upload": { "id": "u1", "url": "/api/v1/uploads/u1", "offset": 1048576, "length": 3145728, "expires_at": "2026-10-04T12:00:00Z" } }] } }, "expect": { "next_state": "Uploading", "action": "resume_upload", "attempts_delta": 0 } },
    { "name": "check_tombstoned", "given": { "flow": "backup", "item_state": "Hashed", "last_action": "check", "item": { "kind": "photo" } }, "server": { "status": 200, "json": { "results": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "verdict": "tombstoned", "deleted_at": "2026-09-01T08:00:00Z" }] } }, "expect": { "next_state": "Skipped", "action": "mark_skipped", "attempts_delta": 0 } },
    { "name": "check_unknown_verdict", "description": "R7: unknown verdicts are skipped for this run, not treated as errors.", "given": { "flow": "backup", "item_state": "Hashed", "last_action": "check", "item": { "kind": "photo" } }, "server": { "status": 200, "json": { "results": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "verdict": "archived_cold" }] } }, "expect": { "next_state": "Hashed", "action": "skip_this_run", "attempts_delta": 0 } },
    { "name": "check_live_photo_missing_video", "description": "H4: the still exists but its video component never arrived.", "given": { "flow": "backup", "item_state": "Hashed", "last_action": "check", "item": { "kind": "live_photo" } }, "server": { "status": 200, "json": { "results": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "verdict": "exists", "asset_id": "01928f40-0000-7000-8000-000000000001", "asset_state": "active", "has_live_video": false }] } }, "expect": { "next_state": "Queued", "action": "upload_live_video", "attempts_delta": 0 } },
    { "name": "check_timeout", "given": { "flow": "backup", "item_state": "Hashed", "last_action": "check", "item": { "kind": "photo", "attempts": 0 } }, "server": { "transport": "timeout" }, "expect": { "next_state": "Hashed", "action": "backoff_retry", "attempts_delta": 1 } },
    { "name": "check_offline", "description": "R5: no network does not count as an attempt.", "given": { "flow": "backup", "item_state": "Hashed", "last_action": "check", "item": { "kind": "photo", "attempts": 0 } }, "server": { "transport": "offline" }, "expect": { "next_state": "Hashed", "action": "wait_for_network", "attempts_delta": 0 } }
  ]
}
```

- [ ] **Step 2: Create `create-upload.json`**

```json
{
  "schema_version": 1,
  "kind": "client-decision",
  "description": "Engine reactions to POST /uploads (sync-protocol.md §7.3).",
  "cases": [
    { "name": "create_timeout_unknown_outcome", "description": "R2: without an upload id the engine re-checks instead of guessing.", "given": { "flow": "backup", "item_state": "Queued", "last_action": "create_upload", "item": { "kind": "photo", "has_upload_id": false } }, "server": { "transport": "timeout" }, "expect": { "next_state": "Hashed", "action": "check_then_resolve", "attempts_delta": 1 } },
    { "name": "create_resolved_to_existing_asset", "given": { "flow": "backup", "item_state": "Queued", "last_action": "create_upload", "item": { "kind": "photo" } }, "server": { "status": 201, "headers": { "Location": "/api/v1/uploads/a_01928f40", "Upload-Offset": "1048576", "PicTunnel-Asset-Id": "01928f40-0000-7000-8000-000000000001", "PicTunnel-Asset-Created": "false" } }, "expect": { "next_state": "BackedUp", "action": "mark_backed_up", "attempts_delta": 0 } },
    { "name": "create_session_returned", "given": { "flow": "backup", "item_state": "Queued", "last_action": "create_upload", "item": { "kind": "video" } }, "server": { "status": 201, "headers": { "Location": "/api/v1/uploads/u1", "Upload-Offset": "0" } }, "expect": { "next_state": "Uploading", "action": "resume_upload", "attempts_delta": 0 } },
    { "name": "create_tombstoned", "given": { "flow": "backup", "item_state": "Queued", "last_action": "create_upload", "item": { "kind": "photo" } }, "server": { "status": 409, "problem": "tombstoned" }, "expect": { "next_state": "Skipped", "action": "mark_skipped", "attempts_delta": 0 } },
    { "name": "create_length_mismatch", "description": "The cached hash or size is stale; re-hash the file.", "given": { "flow": "backup", "item_state": "Queued", "last_action": "create_upload", "item": { "kind": "photo" } }, "server": { "status": 409, "problem": "length_mismatch" }, "expect": { "next_state": "Discovered", "action": "rehash_and_requeue", "attempts_delta": 1 } },
    { "name": "create_pair_primary_missing", "given": { "flow": "backup", "item_state": "Queued", "last_action": "create_upload", "item": { "kind": "live_photo" } }, "server": { "status": 409, "problem": "pair_primary_missing" }, "expect": { "next_state": "Queued", "action": "upload_primary_first", "attempts_delta": 0 } },
    { "name": "create_file_too_large", "given": { "flow": "backup", "item_state": "Queued", "last_action": "create_upload", "item": { "kind": "video" } }, "server": { "status": 413, "problem": "file_too_large" }, "expect": { "next_state": "NeedsAttention", "action": "mark_needs_attention", "attempts_delta": 0 } },
    { "name": "create_quota_exceeded", "given": { "flow": "backup", "item_state": "Queued", "last_action": "create_upload", "item": { "kind": "photo" } }, "server": { "status": 413, "problem": "quota_exceeded" }, "expect": { "next_state": "Paused", "action": "notify_quota", "attempts_delta": 0 } },
    { "name": "create_insufficient_storage", "given": { "flow": "backup", "item_state": "Queued", "last_action": "create_upload", "item": { "kind": "photo" } }, "server": { "status": 507, "problem": "insufficient_storage" }, "expect": { "next_state": "Paused", "action": "pause_all_uploads", "attempts_delta": 0 } },
    { "name": "create_client_too_old", "given": { "flow": "backup", "item_state": "Queued", "last_action": "create_upload", "item": { "kind": "photo" } }, "server": { "status": 426, "problem": "client_too_old" }, "expect": { "next_state": "Paused", "action": "prompt_update", "attempts_delta": 0 } },
    { "name": "create_checksum_mismatch_single_shot", "given": { "flow": "backup", "item_state": "Queued", "last_action": "create_upload", "item": { "kind": "photo" } }, "server": { "status": 460, "problem": "checksum_mismatch" }, "expect": { "next_state": "Discovered", "action": "rehash_and_requeue", "attempts_delta": 1 } }
  ]
}
```

- [ ] **Step 3: Create `append-upload.json`**

```json
{
  "schema_version": 1,
  "kind": "client-decision",
  "description": "Engine reactions to PATCH and HEAD on an upload (sync-protocol.md §7.3, §8, R2, R5, R7, R11).",
  "cases": [
    { "name": "append_finalized", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "photo", "has_upload_id": true } }, "server": { "status": 204, "headers": { "Upload-Offset": "1048576", "PicTunnel-Asset-Id": "01928f40-0000-7000-8000-000000000001", "PicTunnel-Asset-Created": "true" } }, "expect": { "next_state": "BackedUp", "action": "mark_backed_up", "attempts_delta": 0 } },
    { "name": "append_offset_mismatch", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "video", "has_upload_id": true } }, "server": { "status": 409, "headers": { "Upload-Offset": "2097152" }, "problem": "offset_mismatch" }, "expect": { "next_state": "Uploading", "action": "head_then_resume", "attempts_delta": 0 } },
    { "name": "append_upload_locked", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "video", "has_upload_id": true } }, "server": { "status": 423, "problem": "upload_locked" }, "expect": { "next_state": "Uploading", "action": "backoff_retry", "attempts_delta": 1 } },
    { "name": "append_checksum_mismatch", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "photo", "has_upload_id": true } }, "server": { "status": 460, "problem": "checksum_mismatch" }, "expect": { "next_state": "Discovered", "action": "rehash_and_requeue", "attempts_delta": 1 } },
    { "name": "append_upload_not_found", "description": "The session expired; creating again is safe because creation is idempotent.", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "video", "has_upload_id": true } }, "server": { "status": 404, "problem": "not_found" }, "expect": { "next_state": "Queued", "action": "restart_upload", "attempts_delta": 0 } },
    { "name": "append_reset_during_final_chunk", "description": "R2: the finalize may or may not have happened; ask with HEAD.", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "photo", "has_upload_id": true } }, "server": { "transport": "reset" }, "expect": { "next_state": "Uploading", "action": "head_then_resume", "attempts_delta": 1 } },
    { "name": "append_rate_limited", "description": "Throttling is not the item's fault and does not count as an attempt.", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "photo", "has_upload_id": true } }, "server": { "status": 429, "headers": { "Retry-After": "30" }, "problem": "rate_limited" }, "expect": { "next_state": "Uploading", "action": "wait_retry_after", "attempts_delta": 0 } },
    { "name": "append_server_unavailable", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "photo", "has_upload_id": true } }, "server": { "status": 503, "headers": { "Retry-After": "60" }, "problem": "server_unavailable" }, "expect": { "next_state": "Uploading", "action": "wait_retry_after", "attempts_delta": 1 } },
    { "name": "append_internal_error", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "photo", "has_upload_id": true } }, "server": { "status": 500, "problem": "internal" }, "expect": { "next_state": "Uploading", "action": "backoff_retry", "attempts_delta": 1 } },
    { "name": "append_offline", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "photo", "has_upload_id": true } }, "server": { "transport": "offline" }, "expect": { "next_state": "Uploading", "action": "wait_for_network", "attempts_delta": 0 } },
    { "name": "append_token_expired", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "photo", "has_upload_id": true } }, "server": { "status": 401, "problem": "token_expired" }, "expect": { "next_state": "Uploading", "action": "refresh_then_retry", "attempts_delta": 0 } },
    { "name": "append_unauthorized", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "photo", "has_upload_id": true } }, "server": { "status": 401, "problem": "unauthorized" }, "expect": { "next_state": "Uploading", "action": "refresh_then_retry", "attempts_delta": 0 } },
    { "name": "append_forbidden", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "photo", "has_upload_id": true } }, "server": { "status": 403, "problem": "forbidden" }, "expect": { "next_state": "NeedsAttention", "action": "mark_needs_attention", "attempts_delta": 0 } },
    { "name": "append_invalid_request", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "photo", "has_upload_id": true } }, "server": { "status": 400, "problem": "invalid_request" }, "expect": { "next_state": "NeedsAttention", "action": "mark_needs_attention", "attempts_delta": 0 } },
    { "name": "append_unknown_4xx", "description": "R7: unknown 4xx statuses are not retried.", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "photo", "has_upload_id": true } }, "server": { "status": 418, "problem": "teapot" }, "expect": { "next_state": "NeedsAttention", "action": "mark_needs_attention", "attempts_delta": 0 } },
    { "name": "append_unknown_5xx", "description": "R7: unknown 5xx statuses are retried with backoff.", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "photo", "has_upload_id": true } }, "server": { "status": 599 }, "expect": { "next_state": "Uploading", "action": "backoff_retry", "attempts_delta": 1 } },
    { "name": "append_insufficient_storage", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "append_upload", "item": { "kind": "video", "has_upload_id": true } }, "server": { "status": 507, "problem": "insufficient_storage" }, "expect": { "next_state": "Paused", "action": "pause_all_uploads", "attempts_delta": 0 } },
    { "name": "head_timeout", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "head_upload", "item": { "kind": "video", "has_upload_id": true } }, "server": { "transport": "timeout" }, "expect": { "next_state": "Uploading", "action": "backoff_retry", "attempts_delta": 1 } },
    { "name": "head_reports_finalized", "given": { "flow": "backup", "item_state": "Uploading", "last_action": "head_upload", "item": { "kind": "photo", "has_upload_id": true } }, "server": { "status": 200, "headers": { "Upload-Offset": "1048576", "Upload-Length": "1048576", "PicTunnel-Asset-Id": "01928f40-0000-7000-8000-000000000001" } }, "expect": { "next_state": "BackedUp", "action": "mark_backed_up", "attempts_delta": 0 } }
  ]
}
```

- [ ] **Step 4: Create `auth-browse-setup.json`**

```json
{
  "schema_version": 1,
  "kind": "client-decision",
  "description": "Token refresh, change feed, thumbnails, pairing and first-run setup (sync-protocol.md §6.2, §7.6, §8).",
  "cases": [
    { "name": "refresh_token_reused", "given": { "flow": "auth", "last_action": "refresh" }, "server": { "status": 401, "problem": "refresh_token_reused" }, "expect": { "next_state": "Paused", "action": "require_repair", "attempts_delta": 0 } },
    { "name": "refresh_grace_returns_same_pair", "description": "A concurrent refresh inside the 30 s grace window succeeds; retry the original request.", "given": { "flow": "auth", "last_action": "refresh" }, "server": { "status": 200, "json": { "access_token": "pt_at_example", "access_token_expires_at": "2026-10-03T12:15:00Z", "refresh_token": "pt_rt_example", "refresh_token_expires_at": "2027-01-01T12:00:00Z" } }, "expect": { "action": "retry_original_request", "attempts_delta": 0 } },
    { "name": "changes_cursor_expired", "given": { "flow": "browse", "last_action": "get_changes" }, "server": { "status": 410, "problem": "cursor_expired" }, "expect": { "action": "run_snapshot", "attempts_delta": 0 } },
    { "name": "changes_cursor_required", "given": { "flow": "browse", "last_action": "get_changes" }, "server": { "status": 400, "problem": "cursor_required" }, "expect": { "action": "run_snapshot", "attempts_delta": 0 } },
    { "name": "thumbnail_not_ready", "given": { "flow": "browse", "last_action": "get_thumbnail" }, "server": { "status": 404, "problem": "not_ready" }, "expect": { "action": "retry_later", "attempts_delta": 0 } },
    { "name": "pairing_code_invalid", "given": { "flow": "pairing", "last_action": "redeem_pairing" }, "server": { "status": 400, "problem": "pairing_code_invalid" }, "expect": { "action": "show_error", "attempts_delta": 0 } },
    { "name": "setup_already_done", "given": { "flow": "setup", "last_action": "setup" }, "server": { "status": 409, "problem": "setup_already_done" }, "expect": { "action": "go_to_login", "attempts_delta": 0 } }
  ]
}
```

- [ ] **Step 5: Create `free-up-space.json`**

```json
{
  "schema_version": 1,
  "kind": "client-decision",
  "description": "Free-up-space preconditions (sync-protocol.md §7.8, R8). The check was sent with confirm_on_disk=true.",
  "cases": [
    { "name": "free_space_confirmed", "given": { "flow": "free_up_space", "item_state": "BackedUp", "last_action": "free_up_space_check", "item": { "kind": "photo", "fingerprint_changed": false } }, "server": { "status": 200, "json": { "results": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "verdict": "exists", "asset_id": "01928f40-0000-7000-8000-000000000001", "asset_state": "active", "on_disk": true }] } }, "expect": { "next_state": "Freed", "action": "delete_local_allowed", "attempts_delta": 0 } },
    { "name": "free_space_asset_trashed", "given": { "flow": "free_up_space", "item_state": "BackedUp", "last_action": "free_up_space_check", "item": { "kind": "photo", "fingerprint_changed": false } }, "server": { "status": 200, "json": { "results": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "verdict": "exists", "asset_id": "01928f40-0000-7000-8000-000000000001", "asset_state": "trashed", "on_disk": true }] } }, "expect": { "next_state": "BackedUp", "action": "delete_local_denied", "attempts_delta": 0 } },
    { "name": "free_space_not_on_disk", "given": { "flow": "free_up_space", "item_state": "BackedUp", "last_action": "free_up_space_check", "item": { "kind": "photo", "fingerprint_changed": false } }, "server": { "status": 200, "json": { "results": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "verdict": "exists", "asset_id": "01928f40-0000-7000-8000-000000000001", "asset_state": "active", "on_disk": false }] } }, "expect": { "next_state": "BackedUp", "action": "delete_local_denied", "attempts_delta": 0 } },
    { "name": "free_space_fingerprint_changed", "description": "The local file changed since it was hashed, so the server copy may differ.", "given": { "flow": "free_up_space", "item_state": "BackedUp", "last_action": "free_up_space_check", "item": { "kind": "photo", "fingerprint_changed": true } }, "server": { "status": 200, "json": { "results": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "verdict": "exists", "asset_id": "01928f40-0000-7000-8000-000000000001", "asset_state": "active", "on_disk": true }] } }, "expect": { "next_state": "Discovered", "action": "delete_local_denied", "attempts_delta": 0 } },
    { "name": "free_space_missing_on_server", "given": { "flow": "free_up_space", "item_state": "BackedUp", "last_action": "free_up_space_check", "item": { "kind": "photo", "fingerprint_changed": false } }, "server": { "status": 200, "json": { "results": [{ "sha256": "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83", "verdict": "missing" }] } }, "expect": { "next_state": "Queued", "action": "delete_local_denied", "attempts_delta": 0 } }
  ]
}
```

- [ ] **Step 6: Verify every problem code is covered**

Run:
```bash
for c in invalid_request cursor_required pairing_code_invalid unauthorized token_expired refresh_token_reused forbidden not_found not_ready offset_mismatch length_mismatch tombstoned pair_primary_missing setup_already_done cursor_expired file_too_large quota_exceeded upload_locked client_too_old rate_limited checksum_mismatch internal server_unavailable insufficient_storage; do
  grep -rq "\"problem\": \"$c\"" api/protocol/vectors/client-decisions || echo "MISSING $c"
done
```
Expected: no output.

- [ ] **Step 7: Validate strictly (all minimums now met)**

Run: `task vectors:validate`
Expected: `vectors: ok {"hashing":11,"pairing":12,"server-scenario":17,"client-decision":51}`.

- [ ] **Step 8: Commit**

```bash
git add api/protocol/vectors/client-decisions
git commit -s -m "test(api): add client-decision conformance vectors"
```

---

### Task 14: Go module, content hashing and the Go vector runner

**Files:**
- Create: `server/go.mod`, `server/internal/contenthash/contenthash.go`, `server/internal/contenthash/contenthash_test.go`, `server/internal/conformance/vectors.go`, `server/internal/conformance/generate.go`, `server/internal/conformance/generate_test.go`, `server/internal/conformance/hashing_test.go`
- Modify: `Taskfile.yml` (append `test:server`)

**Interfaces:**
- Consumes: Task 10 hashing vectors.
- Produces: `contenthash.HashReader(r io.Reader) (string, error)` (used by the upload module in sub-project 2); `conformance.Generate{Pattern string; Seed int; Length int64}`, `conformance.CounterReader(g Generate, start, end int64) io.Reader`, `conformance.HashingCase`, `conformance.HashingInput.Open(protocolDir string) (io.ReadCloser, error)`, `conformance.LoadHashingCases(protocolDir string) ([]HashingCase, error)`, `conformance.ProtocolDir() string` (the server-scenario runner in sub-project 2 builds on these).

- [ ] **Step 1: Initialize the module**

```bash
mkdir -p server/internal/contenthash server/internal/conformance
cd server
go mod init github.com/PrithvirajG/pictunnel/server
cd ..
```

- [ ] **Step 2: Write the failing content-hash tests**

`server/internal/contenthash/contenthash_test.go`:
```go
package contenthash

import (
	"errors"
	"strings"
	"testing"
)

func TestHashReaderKnownVectors(t *testing.T) {
	cases := map[string]string{
		"":    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		"abc": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	}
	for in, want := range cases {
		got, err := HashReader(strings.NewReader(in))
		if err != nil {
			t.Fatalf("HashReader(%q): %v", in, err)
		}
		if got != want {
			t.Errorf("HashReader(%q) = %s, want %s", in, got, want)
		}
	}
}

type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, errors.New("disk on fire") }

func TestHashReaderPropagatesReadErrors(t *testing.T) {
	_, err := HashReader(failingReader{})
	if err == nil || !strings.Contains(err.Error(), "disk on fire") {
		t.Fatalf("expected the read error, got %v", err)
	}
}
```

- [ ] **Step 3: Run to verify failure**

Run: `cd server && go test ./internal/contenthash/`
Expected: FAIL — `undefined: HashReader`.

- [ ] **Step 4: Implement `server/internal/contenthash/contenthash.go`**

```go
// Package contenthash computes PicTunnel content identities: SHA-256 as lowercase hex.
package contenthash

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
)

// bufferSize matches the 1 MiB read size used by the native engines.
const bufferSize = 1 << 20

// HashReader streams r through SHA-256 and returns the lowercase hex digest.
func HashReader(r io.Reader) (string, error) {
	h := sha256.New()
	if _, err := io.CopyBuffer(h, r, make([]byte, bufferSize)); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd server && go test ./internal/contenthash/`
Expected: `ok`.

- [ ] **Step 6: Write the failing conformance tests**

`server/internal/conformance/generate_test.go`:
```go
package conformance

import (
	"bytes"
	"io"
	"testing"
)

func TestCounterReaderProducesPattern(t *testing.T) {
	got, err := io.ReadAll(CounterReader(Generate{Pattern: "counter", Seed: 1, Length: 258}, 0, 258))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 258 {
		t.Fatalf("len = %d, want 258", len(got))
	}
	if got[0] != 1 || got[254] != 255 || got[255] != 0 || got[257] != 2 {
		t.Fatalf("unexpected bytes: %v ... %v", got[:3], got[254:])
	}
}

func TestCounterReaderRangeMatchesSlice(t *testing.T) {
	g := Generate{Pattern: "counter", Length: 1000}
	full, _ := io.ReadAll(CounterReader(g, 0, 1000))
	part, _ := io.ReadAll(CounterReader(g, 300, 700))
	if !bytes.Equal(part, full[300:700]) {
		t.Fatal("a range must equal the same slice of the full stream")
	}
}
```

`server/internal/conformance/hashing_test.go`:
```go
package conformance

import (
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/contenthash"
)

func TestHashingVectors(t *testing.T) {
	dir := ProtocolDir()
	cases, err := LoadHashingCases(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(cases) < 8 {
		t.Fatalf("found %d hashing cases, want at least 8", len(cases))
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			r, err := c.Input.Open(dir)
			if err != nil {
				t.Fatal(err)
			}
			defer r.Close()
			got, err := contenthash.HashReader(r)
			if err != nil {
				t.Fatal(err)
			}
			if got != c.ExpectedSHA256 {
				t.Errorf("got %s, want %s", got, c.ExpectedSHA256)
			}
		})
	}
}
```

- [ ] **Step 7: Run to verify failure**

Run: `cd server && go test ./internal/conformance/`
Expected: FAIL — `undefined: CounterReader` / `undefined: Generate`.

- [ ] **Step 8: Implement the vector loader and generator**

`server/internal/conformance/vectors.go`:
```go
// Package conformance loads the shared protocol vectors in api/protocol/vectors.
package conformance

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Generate describes a deterministic stream: byte i is (i + Seed) mod 256 for i in [0, Length).
type Generate struct {
	Pattern string `json:"pattern"`
	Seed    int    `json:"seed"`
	Length  int64  `json:"length"`
}

// HashingInput has exactly one source.
type HashingInput struct {
	File       string    `json:"file,omitempty"`
	InlineUTF8 *string   `json:"inline_utf8,omitempty"`
	Generate   *Generate `json:"generate,omitempty"`
}

type HashingCase struct {
	Name           string       `json:"name"`
	Description    string       `json:"description,omitempty"`
	Input          HashingInput `json:"input"`
	ExpectedSHA256 string       `json:"expected_sha256"`
}

type vectorFile[C any] struct {
	SchemaVersion int    `json:"schema_version"`
	Kind          string `json:"kind"`
	Cases         []C    `json:"cases"`
}

// ProtocolDir is api/protocol relative to this package's directory, which is the working directory of go test.
func ProtocolDir() string { return filepath.Join("..", "..", "..", "api", "protocol") }

// LoadHashingCases reads every vectors/hashing/*.json file in name order.
func LoadHashingCases(protocolDir string) ([]HashingCase, error) {
	files, err := filepath.Glob(filepath.Join(protocolDir, "vectors", "hashing", "*.json"))
	if err != nil {
		return nil, err
	}
	sort.Strings(files)
	var all []HashingCase
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		var vf vectorFile[HashingCase]
		if err := json.Unmarshal(raw, &vf); err != nil {
			return nil, fmt.Errorf("%s: %w", f, err)
		}
		if vf.Kind != "hashing" {
			return nil, fmt.Errorf("%s: kind %q, want hashing", f, vf.Kind)
		}
		all = append(all, vf.Cases...)
	}
	return all, nil
}

// Open returns the bytes described by the input.
func (in HashingInput) Open(protocolDir string) (io.ReadCloser, error) {
	switch {
	case in.File != "":
		return os.Open(filepath.Join(protocolDir, filepath.FromSlash(in.File)))
	case in.InlineUTF8 != nil:
		return io.NopCloser(strings.NewReader(*in.InlineUTF8)), nil
	case in.Generate != nil:
		return io.NopCloser(CounterReader(*in.Generate, 0, in.Generate.Length)), nil
	default:
		return nil, fmt.Errorf("hashing input has no source")
	}
}
```

`server/internal/conformance/generate.go`:
```go
package conformance

import "io"

type counterReader struct {
	pos, end, seed int64
}

// CounterReader streams bytes [start, end) of the counter pattern described by g.
// Positions are absolute, so a range equals the same slice of the full stream.
func CounterReader(g Generate, start, end int64) io.Reader {
	return &counterReader{pos: start, end: end, seed: int64(g.Seed)}
}

func (c *counterReader) Read(p []byte) (int, error) {
	if c.pos >= c.end {
		return 0, io.EOF
	}
	n := int64(len(p))
	if rem := c.end - c.pos; rem < n {
		n = rem
	}
	for i := int64(0); i < n; i++ {
		p[i] = byte((c.pos + i + c.seed) % 256)
	}
	c.pos += n
	return int(n), nil
}
```

- [ ] **Step 9: Run all server tests**

Run: `cd server && go vet ./... && go test ./...`
Expected: `ok` for both packages; `TestHashingVectors` runs 11 subtests.

- [ ] **Step 10: Append the Taskfile task**

```yaml

  test:server:
    desc: Vet and test the Go server
    dir: server
    cmds:
      - go vet ./...
      - go test ./...
```

- [ ] **Step 11: Commit**

```bash
git add server Taskfile.yml
git commit -s -m "feat(server): add content hashing and Go conformance vector runner"
```

---

### Task 15: Go code generation and the `pictunnel` command

**Files:**
- Create: `server/internal/httpapi/oapi-codegen.yaml`, `server/internal/httpapi/gen/api.gen.go` (generated), `server/internal/httpapi/contract_test.go`, `server/cmd/pictunnel/main.go`, `server/cmd/pictunnel/main_test.go`
- Modify: `server/go.mod`, `server/go.sum`, `Taskfile.yml` (append `gen:go`)

**Interfaces:**
- Consumes: Task 8 complete contract; Task 14 module.
- Produces: package `github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen` with `StrictServerInterface` (methods named after operationIds: `GetServerInfo`, `CheckContent`, …), request/response models (`CheckRequest`, `CheckItem`, `Asset`, …), and `GetSwagger()`. Command `pictunnel version` printing `pictunnel <version>`; `version` set via `-ldflags "-X main.version=<v>"`.

- [ ] **Step 1: Add oapi-codegen as a module tool**

```bash
cd server
go get -tool github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@latest
cd ..
```
Verify `server/go.mod` contains a `tool github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen` line and the version is ≥ v2.8.0.

- [ ] **Step 2: Create `server/internal/httpapi/oapi-codegen.yaml`**

```yaml
package: gen
output: gen/api.gen.go
generate:
  models: true
  std-http-server: true
  strict-server: true
  embedded-spec: true
```

- [ ] **Step 3: Write the failing contract test**

`server/internal/httpapi/contract_test.go`:
```go
package httpapi_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/PrithvirajG/pictunnel/server/internal/httpapi/gen"
)

// Compile-time proof that the strict server exposes every engine operation.
var _ = []any{
	gen.StrictServerInterface.GetServerInfo,
	gen.StrictServerInterface.RefreshTokens,
	gen.StrictServerInterface.CheckContent,
	gen.StrictServerInterface.OptionsUploads,
	gen.StrictServerInterface.CreateUpload,
	gen.StrictServerInterface.GetUploadOffset,
	gen.StrictServerInterface.AppendUpload,
	gen.StrictServerInterface.TerminateUpload,
	gen.StrictServerInterface.DeleteTombstone,
}

func TestCheckRequestRoundTripsSnakeCase(t *testing.T) {
	body := `{"items":[{"sha256":"fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83","size_bytes":1048576,"local_id":"a-1"}]}`
	var req gen.CheckRequest
	if err := json.Unmarshal([]byte(body), &req); err != nil {
		t.Fatal(err)
	}
	if len(req.Items) != 1 || req.Items[0].SizeBytes != 1048576 {
		t.Fatalf("unexpected decode: %+v", req)
	}
	out, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(out), `"size_bytes":1048576`) {
		t.Fatalf("marshal lost snake_case: %s", out)
	}
}

func TestEmbeddedSpecContainsSyncCheck(t *testing.T) {
	spec, err := gen.GetSwagger()
	if err != nil {
		t.Fatal(err)
	}
	if spec.Paths.Find("/api/v1/sync/check") == nil {
		t.Fatal("embedded spec lacks /api/v1/sync/check")
	}
}
```

- [ ] **Step 4: Run to verify failure**

Run: `cd server && go test ./internal/httpapi/`
Expected: FAIL — package `.../internal/httpapi/gen` is not in std / no Go files.

- [ ] **Step 5: Append the Taskfile task and generate**

Append to `Taskfile.yml`:
```yaml

  gen:go:
    desc: Generate Go server interfaces and models from the contract
    dir: server/internal/httpapi
    cmds:
      - go tool oapi-codegen -config oapi-codegen.yaml ../../../api/openapi.yaml
      - go mod tidy
```
Run: `task gen:go`
Expected: `server/internal/httpapi/gen/api.gen.go` is created; `go.mod` gains `github.com/oapi-codegen/runtime` and `github.com/getkin/kin-openapi`.
If generation fails, the error names a contract construct. Fix `api/openapi.yaml` (re-run `task lint:api`), never the generated file.

- [ ] **Step 6: Run to verify it passes**

Run: `cd server && go test ./internal/httpapi/`
Expected: `ok`.

- [ ] **Step 7: Write the failing command tests**

`server/cmd/pictunnel/main_test.go`:
```go
package main

import (
	"bytes"
	"testing"
)

func TestRunVersion(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"version"}, &out, &errOut); code != 0 {
		t.Fatalf("exit code %d, stderr %q", code, errOut.String())
	}
	if out.String() != "pictunnel dev\n" {
		t.Fatalf("stdout = %q", out.String())
	}
}

func TestRunUnknownCommandShowsUsage(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"serve"}, &out, &errOut); code != 2 {
		t.Fatalf("exit code %d, want 2", code)
	}
	if errOut.String() != "usage: pictunnel version\n" {
		t.Fatalf("stderr = %q", errOut.String())
	}
}
```
Run: `cd server && go test ./cmd/pictunnel/` → FAIL (`undefined: run`).

- [ ] **Step 8: Implement `server/cmd/pictunnel/main.go`**

```go
// Command pictunnel is the PicTunnel server. Serving arrives in sub-project 2.
package main

import (
	"fmt"
	"io"
	"os"
)

// version is set at build time with -ldflags "-X main.version=<version>".
var version = "dev"

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 1 && (args[0] == "version" || args[0] == "--version") {
		fmt.Fprintf(stdout, "pictunnel %s\n", version)
		return 0
	}
	fmt.Fprintln(stderr, "usage: pictunnel version")
	return 2
}
```

- [ ] **Step 9: Verify tests and cross-compilation**

Run: `task test:server` → all packages `ok`.
Run (PowerShell): `cd server; $env:CGO_ENABLED="0"; $env:GOOS="linux"; $env:GOARCH="arm64"; go build -o NUL ./cmd/pictunnel; Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED; cd ..`
Expected: exit 0 (proves no cgo dependency).

- [ ] **Step 10: Commit**

```bash
git add server Taskfile.yml
git commit -s -m "feat(server): generate Go API interfaces and add the pictunnel command"
```

---

### Task 16: Web skeleton and TypeScript client

**Files:**
- Create: `web/package.json` (via pnpm), `web/svelte.config.js`, `web/vite.config.ts`, `web/tsconfig.json`, `web/src/app.html`, `web/src/app.d.ts`, `web/src/routes/+layout.ts`, `web/src/routes/+page.svelte`, `web/src/lib/api/schema.d.ts` (generated), `web/src/lib/api/client.ts`, `web/src/lib/api/client.test.ts`
- Modify: `Taskfile.yml` (append `gen:ts`, `test:web`)

**Interfaces:**
- Consumes: Task 8 contract.
- Produces: `createApiClient(baseUrl: string, fetchImpl?: (input: Request) => Promise<Response>): ApiClient` (typed `openapi-fetch` client over generated `paths`), static build in `web/build` (embedded by the server in sub-project 4).

- [ ] **Step 1: Create the package**

```bash
mkdir -p web/src/routes web/src/lib/api
cd web
pnpm init
pnpm add -D @sveltejs/kit @sveltejs/adapter-static @sveltejs/vite-plugin-svelte svelte svelte-check typescript vite vitest openapi-typescript
pnpm add openapi-fetch
cd ..
```
Set the `web/package.json` header fields and scripts to (keep pnpm's dependency blocks):
```json
{
  "name": "pictunnel-web",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite dev",
    "build": "vite build",
    "check": "svelte-kit sync && svelte-check --tsconfig ./tsconfig.json",
    "test": "vitest run",
    "gen:api": "openapi-typescript ../api/openapi.yaml -o src/lib/api/schema.d.ts"
  }
}
```

- [ ] **Step 2: Create the SvelteKit files**

`web/svelte.config.js`:
```js
import adapter from "@sveltejs/adapter-static";
import { vitePreprocess } from "@sveltejs/vite-plugin-svelte";

export default {
  preprocess: vitePreprocess(),
  kit: {
    adapter: adapter({ pages: "build", assets: "build", fallback: "index.html" }),
  },
};
```

`web/vite.config.ts`:
```ts
import { sveltekit } from "@sveltejs/kit/vite";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [sveltekit()],
  test: { include: ["src/**/*.test.ts"] },
});
```

`web/tsconfig.json`:
```json
{
  "extends": "./.svelte-kit/tsconfig.json",
  "compilerOptions": {
    "strict": true,
    "moduleResolution": "bundler",
    "allowJs": true,
    "checkJs": true,
    "esModuleInterop": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "skipLibCheck": true,
    "sourceMap": true
  }
}
```

`web/src/app.html`:
```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    %sveltekit.head%
  </head>
  <body data-sveltekit-preload-data="hover">
    <div style="display: contents">%sveltekit.body%</div>
  </body>
</html>
```

`web/src/app.d.ts`:
```ts
// See https://svelte.dev/docs/kit/types#app.d.ts
declare global {
  namespace App {}
}

export {};
```

`web/src/routes/+layout.ts`:
```ts
export const prerender = true;
export const ssr = false;
```

`web/src/routes/+page.svelte`:
```svelte
<svelte:head>
  <title>PicTunnel</title>
</svelte:head>

<main>
  <h1>PicTunnel</h1>
  <p>The web viewer arrives in a later milestone.</p>
</main>
```

- [ ] **Step 3: Append Taskfile tasks and generate types**

```yaml

  gen:ts:
    desc: Generate TypeScript types for the web viewer
    cmds:
      - pnpm --dir web run gen:api

  test:web:
    desc: Type-check, test and build the web viewer
    cmds:
      - pnpm --dir web run check
      - pnpm --dir web run test
      - pnpm --dir web run build
```
Run: `task gen:ts` → `web/src/lib/api/schema.d.ts` created.

- [ ] **Step 4: Write the failing client test**

`web/src/lib/api/client.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { createApiClient } from "./client";

const serverInfo = {
  server_id: "01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f",
  name: "Home server",
  version: "0.1.0",
  api_version: "1.0",
  min_client_version: { android: "0.1.0", ios: "0.1.0", web: "0.1.0" },
  capabilities: ["tus"],
  upload: { tus_version: "1.0.0", max_file_bytes: 53687091200, recommended_chunk_bytes: 8388608 },
  time: "2026-10-03T12:00:00Z",
};

describe("createApiClient", () => {
  it("calls the server info endpoint and returns typed data", async () => {
    const paths: string[] = [];
    const fakeFetch = async (input: Request) => {
      paths.push(new URL(input.url).pathname);
      return new Response(JSON.stringify(serverInfo), { status: 200, headers: { "Content-Type": "application/json" } });
    };
    const client = createApiClient("https://localhost:8443", fakeFetch);
    const { data, error } = await client.GET("/api/v1/server/info");
    expect(error).toBeUndefined();
    expect(data?.api_version).toBe("1.0");
    expect(data?.upload.recommended_chunk_bytes).toBe(8388608);
    expect(paths).toEqual(["/api/v1/server/info"]);
  });
});
```
Run: `pnpm --dir web run test` → FAIL (cannot resolve `./client`).

- [ ] **Step 5: Implement `web/src/lib/api/client.ts`**

```ts
import createClient from "openapi-fetch";
import type { paths } from "./schema";

export type ApiClient = ReturnType<typeof createClient<paths>>;

export function createApiClient(baseUrl: string, fetchImpl?: (input: Request) => Promise<Response>): ApiClient {
  return createClient<paths>({ baseUrl, credentials: "include", ...(fetchImpl ? { fetch: fetchImpl } : {}) });
}
```

- [ ] **Step 6: Verify**

Run: `task test:web`
Expected: svelte-check 0 errors; vitest 1 passed; `vite build` writes `web/build/index.html`.

- [ ] **Step 7: Commit**

```bash
git add web Taskfile.yml
git commit -s -m "feat(web): add SvelteKit skeleton and generated TypeScript client"
```

---

### Task 17: Engine-subset bundle and the Kotlin engine-api module

**Files:**
- Create: `api/tools/check-engine-bundle.mjs`, `api/tools/check-engine-bundle.test.mjs`, `mobile/android/engine-api/settings.gradle.kts`, `mobile/android/engine-api/build.gradle.kts`, `mobile/android/engine-api/gradlew`, `gradlew.bat`, `gradle/wrapper/*` (generated by Gradle), `mobile/android/engine-api/generated/**` (generated), `mobile/android/engine-api/src/main/kotlin/io/github/prithvirajg/pictunnel/engineapi/ContentHash.kt`, `mobile/android/engine-api/src/test/kotlin/io/github/prithvirajg/pictunnel/engineapi/{CounterInputStream.kt,ContentHashTest.kt,HashingVectorsTest.kt}`
- Modify: `Taskfile.yml` (append `gen:engine-bundle`, `gen:kotlin`, `test:kotlin`)

**Interfaces:**
- Consumes: Task 8 contract (`engine` tags), Task 10 vectors, Task 2 `DOCKER_RUN`.
- Produces: `api/build/engine-openapi.yaml` (git-ignored); `engineOperationIds(doc): string[]` and `EXPECTED_ENGINE_OPERATIONS`; Kotlin package `io.github.prithvirajg.pictunnel.engineapi` with generated client plus `ContentHash.sha256Hex(input: InputStream): String`. Sub-project 3's Android engine depends on this module.

- [ ] **Step 1: Write the failing bundle-check test**

`api/tools/check-engine-bundle.test.mjs`:
```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { engineOperationIds, EXPECTED_ENGINE_OPERATIONS, bundleErrors } from "./check-engine-bundle.mjs";

const op = (operationId) => ({ operationId, responses: {} });

test("collects operation ids across methods", () => {
  const doc = { paths: { "/a": { get: op("x"), head: op("y") }, "/b": { options: op("z") } } };
  assert.deepEqual(engineOperationIds(doc), ["x", "y", "z"]);
});

test("accepts exactly the expected engine operations", () => {
  const paths = {};
  EXPECTED_ENGINE_OPERATIONS.forEach((id, i) => (paths[`/p${i}`] = { post: op(id) }));
  assert.deepEqual(bundleErrors({ paths }), []);
});

test("reports missing and unexpected operations", () => {
  const paths = {};
  EXPECTED_ENGINE_OPERATIONS.filter((id) => id !== "refreshTokens").forEach((id, i) => (paths[`/p${i}`] = { post: op(id) }));
  paths["/admin"] = { get: op("listUsers") };
  const text = bundleErrors({ paths }).join("\n");
  assert.match(text, /missing engine operation: refreshTokens/);
  assert.match(text, /unexpected engine operation: listUsers/);
});
```
Run: `pnpm --dir api run test` → FAIL (cannot find `./check-engine-bundle.mjs`).

- [ ] **Step 2: Implement `api/tools/check-engine-bundle.mjs`**

```js
// Verifies the engine subset contains exactly the operations the native engines may call.
// Usage: node tools/check-engine-bundle.mjs build/engine-openapi.yaml
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { parse } from "yaml";

export const EXPECTED_ENGINE_OPERATIONS = [
  "getServerInfo", "refreshTokens", "checkContent", "optionsUploads", "createUpload",
  "getUploadOffset", "appendUpload", "terminateUpload", "deleteTombstone",
];
const METHODS = ["get", "put", "post", "delete", "options", "head", "patch"];

export function engineOperationIds(doc) {
  const ids = [];
  for (const item of Object.values(doc.paths ?? {})) {
    for (const m of METHODS) if (item[m]?.operationId) ids.push(item[m].operationId);
  }
  return ids;
}

export function bundleErrors(doc) {
  const actual = new Set(engineOperationIds(doc));
  const expected = new Set(EXPECTED_ENGINE_OPERATIONS);
  return [
    ...[...expected].filter((id) => !actual.has(id)).map((id) => `missing engine operation: ${id}`),
    ...[...actual].filter((id) => !expected.has(id)).map((id) => `unexpected engine operation: ${id}`),
  ];
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const file = process.argv[2];
  const errors = bundleErrors(parse(readFileSync(file, "utf8")));
  if (errors.length) {
    console.error(errors.join("\n"));
    process.exit(1);
  }
  console.log(`engine bundle: ok (${EXPECTED_ENGINE_OPERATIONS.length} operations)`);
}
```
Run: `pnpm --dir api run test` → PASS.

- [ ] **Step 3: Append the bundle task and run it**

```yaml

  gen:engine-bundle:
    desc: Bundle the engine-only subset of the contract
    cmds:
      - pnpm --dir api run bundle:engine
```
Run: `task gen:engine-bundle`
Expected: `api/build/engine-openapi.yaml` written, then `engine bundle: ok (9 operations)`.

- [ ] **Step 4: Create the Gradle build**

`mobile/android/engine-api/settings.gradle.kts`:
```kotlin
rootProject.name = "engine-api"
```

`mobile/android/engine-api/build.gradle.kts`:
```kotlin
plugins {
    kotlin("jvm") version "2.3.20"
    kotlin("plugin.serialization") version "2.3.20"
}

group = "io.github.prithvirajg.pictunnel"

repositories {
    mavenCentral()
}

kotlin {
    jvmToolchain(17)
    sourceSets["main"].kotlin.srcDir("generated/src/main/kotlin")
}

dependencies {
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
    systemProperty("pictunnel.protocolDir", rootDir.resolve("../../../api/protocol").canonicalPath)
}
```

- [ ] **Step 5: Generate the Gradle wrapper (PowerShell, repo root)**

```powershell
docker run --rm -v "${PWD}:/repo" -w /repo/mobile/android/engine-api -e GRADLE_USER_HOME=/tmp/gradle gradle:9.3.0-jdk17 gradle wrapper --gradle-version 9.3.0 --no-daemon
git update-index --add --chmod=+x mobile/android/engine-api/gradlew
```
Expected: `gradlew`, `gradlew.bat`, `gradle/wrapper/gradle-wrapper.jar`, `gradle/wrapper/gradle-wrapper.properties` exist. If Maven Central reports `2.3.20` or `1.11.0` unavailable, use the newest stable Kotlin 2.3.x and kotlinx-serialization 1.11.x and record the versions in the commit message.

- [ ] **Step 6: Append the Kotlin tasks and generate the client**

```yaml

  gen:kotlin:
    desc: Generate the Kotlin engine client from the engine subset
    deps: [gen:engine-bundle]
    cmds:
      - node tools/dev/rmrf.mjs mobile/android/engine-api/generated
      - >-
        {{.DOCKER_RUN}} {{.OPENAPI_GENERATOR_IMAGE}} generate
        -i /repo/api/build/engine-openapi.yaml -g kotlin
        -o /repo/mobile/android/engine-api/generated
        --additional-properties=packageName=io.github.prithvirajg.pictunnel.engineapi,library=jvm-okhttp4,serializationLibrary=kotlinx_serialization,enumUnknownDefaultCase=true,omitGradleWrapper=true,dateLibrary=java8
        --global-property=apiTests=false,modelTests=false,apiDocs=false,modelDocs=false

  test:kotlin:
    desc: Compile the Kotlin engine client and run its vector tests
    cmds:
      - >-
        {{if eq .TOOLS_MODE "native"}}cd mobile/android/engine-api && ./gradlew test --no-daemon{{else}}{{.DOCKER_RUN}} -w /repo/mobile/android/engine-api -e GRADLE_USER_HOME=/tmp/gradle {{.GRADLE_IMAGE}} gradle test --no-daemon{{end}}
```
Run: `task gen:kotlin`
Expected: `mobile/android/engine-api/generated/src/main/kotlin/io/github/prithvirajg/pictunnel/engineapi/apis/` contains `ServerApi.kt`, `AuthApi.kt`, `SyncApi.kt`, `UploadsApi.kt`, `AssetsApi.kt` (grouped by first tag).

- [ ] **Step 7: Write the failing Kotlin tests**

`mobile/android/engine-api/src/test/kotlin/io/github/prithvirajg/pictunnel/engineapi/CounterInputStream.kt`:
```kotlin
package io.github.prithvirajg.pictunnel.engineapi

import java.io.InputStream

/** Byte i is (i + seed) mod 256 for i in [0, length). Mirrors the vector "counter" generator. */
class CounterInputStream(private val seed: Int, private val length: Long) : InputStream() {
    private var pos = 0L

    override fun read(): Int = if (pos >= length) -1 else ((pos++ + seed) % 256).toInt()

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (pos >= length) return -1
        val n = minOf(len.toLong(), length - pos).toInt()
        for (i in 0 until n) b[off + i] = ((pos + i + seed) % 256).toByte()
        pos += n
        return n
    }
}
```

`.../ContentHashTest.kt`:
```kotlin
package io.github.prithvirajg.pictunnel.engineapi

import kotlin.test.Test
import kotlin.test.assertEquals

class ContentHashTest {
    @Test
    fun hashesKnownValues() {
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", ContentHash.sha256Hex("abc".byteInputStream()))
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", ContentHash.sha256Hex(ByteArray(0).inputStream()))
    }

    @Test
    fun counterStreamWrapsAt256() {
        val bytes = CounterInputStream(seed = 1, length = 258).readBytes()
        assertEquals(258, bytes.size)
        assertEquals(0, bytes[255].toInt() and 0xff)
        assertEquals(2, bytes[257].toInt() and 0xff)
    }
}
```

`.../HashingVectorsTest.kt`:
```kotlin
package io.github.prithvirajg.pictunnel.engineapi

import java.io.File
import java.io.InputStream
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

class HashingVectorsTest {
    private val protocolDir = File(System.getProperty("pictunnel.protocolDir"))

    @Test
    fun allHashingVectorsMatch() {
        val files = File(protocolDir, "vectors/hashing").listFiles { f -> f.extension == "json" }.orEmpty().sortedBy { it.name }
        val failures = mutableListOf<String>()
        var count = 0
        for (file in files) {
            val cases = Json.parseToJsonElement(file.readText()).jsonObject.getValue("cases").jsonArray
            for (element in cases) {
                val case = element.jsonObject
                count++
                val name = case.getValue("name").jsonPrimitive.content
                val expected = case.getValue("expected_sha256").jsonPrimitive.content
                val actual = openInput(case.getValue("input").jsonObject).use { ContentHash.sha256Hex(it) }
                if (actual != expected) failures += "${file.name}/$name: expected $expected, got $actual"
            }
        }
        assertTrue(count >= 8, "expected at least 8 hashing cases in $protocolDir, found $count")
        assertTrue(failures.isEmpty(), failures.joinToString("\n"))
    }

    private fun openInput(input: JsonObject): InputStream = when {
        "file" in input -> File(protocolDir, input.getValue("file").jsonPrimitive.content).inputStream()
        "inline_utf8" in input -> input.getValue("inline_utf8").jsonPrimitive.content.toByteArray(Charsets.UTF_8).inputStream()
        "generate" in input -> input.getValue("generate").jsonObject.let { g ->
            CounterInputStream(g["seed"]?.jsonPrimitive?.int ?: 0, g.getValue("length").jsonPrimitive.long)
        }
        else -> error("unsupported hashing input: $input")
    }
}
```
Run: `task test:kotlin` → FAIL (`Unresolved reference: ContentHash`).

- [ ] **Step 8: Implement `ContentHash.kt`**

`mobile/android/engine-api/src/main/kotlin/io/github/prithvirajg/pictunnel/engineapi/ContentHash.kt`:
```kotlin
package io.github.prithvirajg.pictunnel.engineapi

import java.io.InputStream
import java.security.MessageDigest

/** PicTunnel content identity: SHA-256 of the original bytes as lowercase hex. */
object ContentHash {
    private const val BUFFER_SIZE = 1 shl 20

    fun sha256Hex(input: InputStream): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(BUFFER_SIZE)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
```

- [ ] **Step 9: Verify**

Run: `task test:kotlin`
Expected: BUILD SUCCESSFUL; the generated client compiles; 3 tests pass (11 hashing cases inside `allHashingVectorsMatch`).

- [ ] **Step 10: Commit**

```bash
git add api/tools/check-engine-bundle.mjs api/tools/check-engine-bundle.test.mjs mobile/android/engine-api Taskfile.yml
git commit -s -m "feat(mobile): add engine-subset bundle and Kotlin engine-api module"
```

---

### Task 18: Swift EngineAPI package

**Files:**
- Create: `mobile/ios/EngineAPI/Package.swift`, `mobile/ios/EngineAPI/openapi-generator-config.yaml`, `mobile/ios/EngineAPI/Sources/EngineAPI/ContentHash.swift`, `mobile/ios/EngineAPI/Sources/EngineAPI/Generated/{Types.swift,Client.swift}` (generated), `mobile/ios/EngineAPI/Tests/EngineAPITests/HashingVectorsTests.swift`
- Modify: `Taskfile.yml` (append `gen:swift`, `test:swift`)

**Interfaces:**
- Consumes: Task 17 `gen:engine-bundle`, Task 10 vectors.
- Produces: SwiftPM library `EngineAPI` exposing the generated `Client`/`Components`/`Operations` (swift-openapi-generator naming) and `ContentHash.sha256Hex(readingWith:)` / `ContentHash.sha256Hex(fileAt:)`. Sub-project 3's iOS engine depends on it.

- [ ] **Step 1: Create the package manifest and generator config**

`mobile/ios/EngineAPI/Package.swift`:
```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EngineAPI",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "EngineAPI", targets: ["EngineAPI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "EngineAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "EngineAPITests", dependencies: ["EngineAPI"]),
    ]
)
```

`mobile/ios/EngineAPI/openapi-generator-config.yaml`:
```yaml
generate:
  - types
  - client
accessModifier: public
```

- [ ] **Step 2: Append Swift tasks and generate**

```yaml

  gen:swift:
    desc: Generate the Swift engine client from the engine subset (swift-openapi-generator in Docker)
    deps: [gen:engine-bundle]
    vars:
      GEN_DIR: /repo/.cache/swift-openapi-generator-{{.SWIFT_OPENAPI_GENERATOR_VERSION}}
    cmds:
      - node tools/dev/rmrf.mjs mobile/ios/EngineAPI/Sources/EngineAPI/Generated
      - >-
        {{.DOCKER_RUN}} {{.SWIFT_IMAGE}} bash -c "
        mkdir -p /repo/mobile/ios/EngineAPI/Sources/EngineAPI/Generated &&
        (test -d {{.GEN_DIR}} || git clone --depth 1 --branch {{.SWIFT_OPENAPI_GENERATOR_VERSION}} https://github.com/apple/swift-openapi-generator {{.GEN_DIR}}) &&
        swift run --package-path {{.GEN_DIR}} -c release swift-openapi-generator generate
        --config /repo/mobile/ios/EngineAPI/openapi-generator-config.yaml
        --output-directory /repo/mobile/ios/EngineAPI/Sources/EngineAPI/Generated
        /repo/api/build/engine-openapi.yaml"

  test:swift:
    desc: Build the Swift engine client and run its vector tests
    cmds:
      - >-
        {{if eq .TOOLS_MODE "native"}}swift test --package-path mobile/ios/EngineAPI{{else}}{{.DOCKER_RUN}} {{.SWIFT_IMAGE}} swift test --package-path /repo/mobile/ios/EngineAPI --scratch-path /repo/.cache/engineapi-build{{end}}
```
Run: `task gen:swift` (the first run builds the generator; expect several minutes).
Expected: `Generated/Types.swift` and `Generated/Client.swift` exist.

- [ ] **Step 3: Write the failing test**

`mobile/ios/EngineAPI/Tests/EngineAPITests/HashingVectorsTests.swift`:
```swift
import Foundation
import XCTest
@testable import EngineAPI

final class HashingVectorsTests: XCTestCase {
    private struct VectorFile: Decodable { let cases: [HashingCase] }
    private struct HashingCase: Decodable {
        let name: String
        let input: Input
        let expected_sha256: String
    }
    private struct Input: Decodable {
        let file: String?
        let inline_utf8: String?
        let generate: Generate?
    }
    private struct Generate: Decodable {
        let pattern: String
        let seed: Int?
        let length: Int
    }

    /// Tests/EngineAPITests/<file> → EngineAPI → ios → mobile → repo root → api/protocol
    private let protocolDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("api/protocol")

    func testKnownValues() {
        XCTAssertEqual(feed(Array("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(feed([]), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testAllHashingVectorsMatch() throws {
        let dir = protocolDir.appendingPathComponent("vectors/hashing")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var count = 0
        var failures: [String] = []
        for file in files {
            let vectors = try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: file))
            for c in vectors.cases {
                count += 1
                let actual = try hash(c.input)
                if actual != c.expected_sha256 {
                    failures.append("\(file.lastPathComponent)/\(c.name): expected \(c.expected_sha256), got \(actual)")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(count, 8, "hashing cases found in \(dir.path)")
        XCTAssertEqual(failures, [])
    }

    private func hash(_ input: Input) throws -> String {
        if let file = input.file {
            return try ContentHash.sha256Hex(fileAt: protocolDir.appendingPathComponent(file))
        }
        if let text = input.inline_utf8 {
            return feed(Array(text.utf8))
        }
        if let g = input.generate {
            let seed = g.seed ?? 0
            var pos = 0
            return ContentHash.sha256Hex { buffer in
                let n = min(buffer.count, g.length - pos)
                for i in 0..<n { buffer[i] = UInt8((pos + i + seed) % 256) }
                pos += n
                return n
            }
        }
        XCTFail("hashing input has no source")
        return ""
    }

    private func feed(_ bytes: [UInt8]) -> String {
        var pos = 0
        return ContentHash.sha256Hex { buffer in
            let n = min(buffer.count, bytes.count - pos)
            for i in 0..<n { buffer[i] = bytes[pos + i] }
            pos += n
            return n
        }
    }
}
```
Run: `task test:swift` → FAIL (`cannot find 'ContentHash' in scope`).

- [ ] **Step 4: Implement `ContentHash.swift`**

`mobile/ios/EngineAPI/Sources/EngineAPI/ContentHash.swift`:
```swift
import Crypto
import Foundation

/// PicTunnel content identity: SHA-256 of the original bytes as lowercase hex.
public enum ContentHash {
    static let bufferSize = 1 << 20

    /// Streams bytes from `read`, which fills the buffer and returns the byte count (0 at the end).
    public static func sha256Hex(readingWith read: (inout [UInt8]) throws -> Int) rethrows -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let n = try read(&buffer)
            if n == 0 { break }
            hasher.update(data: buffer[0..<n])
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try sha256Hex { buffer in
            guard let data = try handle.read(upToCount: buffer.count), !data.isEmpty else { return 0 }
            data.copyBytes(to: &buffer, count: data.count)
            return data.count
        }
    }
}
```

- [ ] **Step 5: Verify**

Run: `task test:swift`
Expected: the generated client compiles on Linux; `Executed 2 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add mobile/ios/EngineAPI Taskfile.yml
git commit -s -m "feat(mobile): add Swift EngineAPI package with generated client"
```

---

### Task 19: Flutter app skeleton and generated Dart client

**Files:**
- Create: `mobile/` Flutter project (via `flutter create`), `mobile/.flutter-version`, `tools/dev/dart-image.txt`, `mobile/packages/pictunnel_api/**` (generated), `mobile/test/api_client_test.dart`
- Modify: `mobile/pubspec.yaml`, `mobile/analysis_options.yaml`, `Taskfile.yml` (append `gen:dart`, `test:mobile`)

**Interfaces:**
- Consumes: Task 8 contract.
- Produces: Flutter app `pictunnel` (applicationId / bundle id `io.github.prithvirajg.pictunnel`); Dart package `pictunnel_api` with `PictunnelApi` (`getServerApi()`, `getSyncApi()`, …, `serializers`) and built_value models (`ServerInfo`, `CheckRequest`, `Asset`, …).

- [ ] **Step 1: Create the Flutter project (PowerShell, repo root)**

```powershell
docker run --rm -v "${PWD}:/repo" -w /repo/mobile ghcr.io/cirruslabs/flutter:stable flutter create --org io.github.prithvirajg --project-name pictunnel --platforms android,ios --empty .
```
Expected: `mobile/pubspec.yaml`, `mobile/lib/main.dart`, `mobile/android/`, `mobile/ios/` exist; `mobile/LICENSE`, `mobile/android/engine-api/` and `mobile/ios/EngineAPI/` are untouched.
Verify ids: `grep -r "applicationId" mobile/android/app/build.gradle*` shows `io.github.prithvirajg.pictunnel`; `grep PRODUCT_BUNDLE_IDENTIFIER mobile/ios/Runner.xcodeproj/project.pbxproj | head -1` shows `io.github.prithvirajg.pictunnel`.
Flutter's `mobile/android/.gitignore` ignores `gradle-wrapper.jar` at any depth; the engine-api wrapper jar stays tracked because it was committed in Task 17. Verify: `git ls-files mobile/android/engine-api/gradle/wrapper/gradle-wrapper.jar` prints the path.

- [ ] **Step 2: Pin the Flutter and Dart images**

```powershell
docker run --rm ghcr.io/cirruslabs/flutter:stable flutter --version --machine
```
Write the `frameworkVersion` value (for example `3.41.2`) as the only line of `mobile/.flutter-version`. Confirm `docker pull ghcr.io/cirruslabs/flutter:<that version>` succeeds.
```powershell
docker run --rm dart:stable dart --version
```
Write `dart:<version>` (for example `dart:3.12.1`) as the only line of `tools/dev/dart-image.txt`. Confirm `docker pull dart:<version>` succeeds.

- [ ] **Step 3: Exclude generated packages from app analysis**

Append to `mobile/analysis_options.yaml`:
```yaml

analyzer:
  exclude:
    - packages/**
```

- [ ] **Step 4: Append Dart tasks and generate**

```yaml

  gen:dart:
    desc: Generate the Dart client package for the Flutter app
    cmds:
      - node tools/dev/rmrf.mjs mobile/packages/pictunnel_api
      - >-
        {{.DOCKER_RUN}} {{.OPENAPI_GENERATOR_IMAGE}} generate
        -i /repo/api/openapi.yaml -g dart-dio
        -o /repo/mobile/packages/pictunnel_api
        --additional-properties=pubName=pictunnel_api,pubLibrary=pictunnel_api,enumUnknownDefaultCase=true
        --global-property=apiTests=false,modelTests=false,apiDocs=false,modelDocs=false
      - >-
        {{.DOCKER_RUN}} -w /repo/mobile/packages/pictunnel_api {{.DART_IMAGE}}
        bash -c "dart pub get && dart run build_runner build --delete-conflicting-outputs"

  test:mobile:
    desc: Analyze and test the Flutter app
    cmds:
      - >-
        {{if eq .TOOLS_MODE "native"}}cd mobile && flutter pub get && flutter analyze && flutter test{{else}}{{.DOCKER_RUN}} -w /repo/mobile ghcr.io/cirruslabs/flutter:{{.FLUTTER_VERSION}} bash -c "flutter pub get && flutter analyze && flutter test"{{end}}
```
Run: `task gen:dart`
Expected: `mobile/packages/pictunnel_api/lib/pictunnel_api.dart` exists along with `*.g.dart` files from build_runner.
Then add the dependency (PowerShell):
```powershell
docker run --rm -v "${PWD}:/repo" -w /repo/mobile ghcr.io/cirruslabs/flutter:stable flutter pub add pictunnel_api --path packages/pictunnel_api
```

- [ ] **Step 5: Write the failing Dart test**

`mobile/test/api_client_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel_api/pictunnel_api.dart';

void main() {
  test('generated client exposes the server API', () {
    final api = PictunnelApi(basePathOverride: 'https://localhost:8443');
    expect(api.getServerApi(), isA<ServerApi>());
  });

  test('ServerInfo deserializes snake_case JSON', () {
    final api = PictunnelApi();
    final info = api.serializers.deserializeWith(ServerInfo.serializer, {
      'server_id': '01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f',
      'name': 'Home server',
      'version': '0.1.0',
      'api_version': '1.0',
      'min_client_version': {'android': '0.1.0', 'ios': '0.1.0', 'web': '0.1.0'},
      'capabilities': ['tus'],
      'upload': {'tus_version': '1.0.0', 'max_file_bytes': 53687091200, 'recommended_chunk_bytes': 8388608},
      'time': '2026-10-03T12:00:00Z',
    })!;
    expect(info.apiVersion, '1.0');
    expect(info.upload.recommendedChunkBytes, 8388608);
  });
}
```
Before generation and `pub add`, this fails to compile (`Target of URI doesn't exist: 'package:pictunnel_api/pictunnel_api.dart'`). If the generated names differ (for example the API class), use the names in `mobile/packages/pictunnel_api/lib/pictunnel_api.dart`; do not edit generated code.

- [ ] **Step 6: Verify**

Run: `task test:mobile`
Expected: `No issues found!` from analyze; `All tests passed!` (2 tests).

- [ ] **Step 7: Commit**

```bash
git add mobile tools/dev/dart-image.txt Taskfile.yml
git commit -s -m "feat(mobile): add Flutter app skeleton and generated Dart client"
```

---

### Task 20: ML worker skeleton

**Files:**
- Create: `ml/pyproject.toml`, `ml/.python-version`, `ml/src/pictunnel_ml/__init__.py`, `ml/tests/test_version.py`
- Modify: `Taskfile.yml` (append `test:ml`)

**Interfaces:**
- Consumes: nothing.
- Produces: installable package `pictunnel_ml` with `__version__`; sub-project 6 builds the worker here.

- [ ] **Step 1: Create the project files**

`ml/pyproject.toml`:
```toml
[project]
name = "pictunnel-ml"
version = "0.0.0"
description = "Optional machine-learning worker for PicTunnel"
requires-python = ">=3.12"
license = "AGPL-3.0-only"
dependencies = []

[dependency-groups]
dev = ["pytest>=8", "ruff>=0.6"]

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/pictunnel_ml"]

[tool.ruff]
line-length = 100
```
`ml/.python-version`:
```
3.12
```

- [ ] **Step 2: Write the failing test**

`ml/tests/test_version.py`:
```python
import pictunnel_ml


def test_version_is_semver_like():
    parts = pictunnel_ml.__version__.split(".")
    assert len(parts) == 3
    assert all(p.isdigit() for p in parts)
```
Run: `uv sync --project ml && uv run --project ml pytest ml` → FAIL (`ModuleNotFoundError: No module named 'pictunnel_ml'`).

- [ ] **Step 3: Implement**

`ml/src/pictunnel_ml/__init__.py`:
```python
"""PicTunnel optional ML worker. The worker itself arrives in sub-project 6."""

__version__ = "0.0.0"
```

- [ ] **Step 4: Append the task and verify**

```yaml

  test:ml:
    desc: Lint and test the ML worker
    cmds:
      - uv sync --project ml
      - uv run --project ml ruff check ml
      - uv run --project ml pytest ml
```
Run: `task test:ml` → `All checks passed!` and `1 passed`.

- [ ] **Step 5: Commit**

```bash
git add ml Taskfile.yml
git commit -s -m "feat(ml): add ML worker skeleton"
```

---

### Task 21: Normative sync-protocol document

**Files:**
- Create: `api/protocol/sync-protocol.md`, `api/tools/check-protocol-doc.mjs`, `api/tools/check-protocol-doc.test.mjs`
- Modify: `api/package.json` (`lint` script)

**Interfaces:**
- Consumes: spec §3–§9 (copied verbatim, numbering preserved so `sync-protocol.md §7.3` references in the contract stay valid); vectors from Tasks 10–13; `engineOperationIds` from Task 17 (it returns every operation id in a document).
- Produces: `api/protocol/sync-protocol.md` with §1–§11; `missingExamples(operationIds: string[], markdown: string): string[]`; `pnpm --dir api run lint` now also fails when an operation lacks a worked example.

- [ ] **Step 1: Write the failing doc-check test**

`api/tools/check-protocol-doc.test.mjs`:
```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { missingExamples } from "./check-protocol-doc.mjs";

test("reports operations without a worked example heading", () => {
  const md = "#### `getServerInfo`\n\n```http\nGET /api/v1/server/info\n```\n\n#### `checkContent`\n";
  assert.deepEqual(missingExamples(["getServerInfo", "checkContent", "createUpload"], md), ["createUpload"]);
});

test("a mention in prose is not an example", () => {
  assert.deepEqual(missingExamples(["login"], "Call `login` first."), ["login"]);
});
```
Run: `pnpm --dir api run test` → FAIL (cannot find `./check-protocol-doc.mjs`).

- [ ] **Step 2: Implement `api/tools/check-protocol-doc.mjs`**

```js
// Ensures sync-protocol.md has a worked-example heading (#### `operationId`) for every operation.
// Usage: node tools/check-protocol-doc.mjs openapi.yaml protocol/sync-protocol.md
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { parse } from "yaml";
import { engineOperationIds as allOperationIds } from "./check-engine-bundle.mjs";

export function missingExamples(operationIds, markdown) {
  return operationIds.filter((id) => !new RegExp("^#### `" + id + "`\\s*$", "m").test(markdown));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [specFile, docFile] = process.argv.slice(2);
  const ids = allOperationIds(parse(readFileSync(specFile, "utf8")));
  const missing = missingExamples(ids, readFileSync(docFile, "utf8"));
  if (missing.length) {
    console.error(`${docFile} lacks worked examples for:\n` + missing.join("\n"));
    process.exit(1);
  }
  console.log(`protocol doc: ok (${ids.length} operations have examples)`);
}
```
Run: `pnpm --dir api run test` → PASS.

- [ ] **Step 3: Start the document with §1–§2**

Create `api/protocol/sync-protocol.md` with exactly:
````markdown
# PicTunnel Sync Protocol (API v1)

- Status: Normative for API v1 · License: Apache-2.0
- Wire format: [`../openapi.yaml`](../openapi.yaml) · Decisions: [`../../docs/adr/`](../../docs/adr/)

## 1. Scope

This document defines how PicTunnel clients and servers identify content, authenticate, upload, browse and delete, so that independent implementations (the Go server, the Kotlin and Swift backup engines, the Flutter app, the web viewer) behave identically. The OpenAPI document defines the wire format; this document defines behavior. Section numbers are stable and are referenced from the OpenAPI descriptions.

## 2. Normative language and terms

The key words MUST, MUST NOT, SHOULD and MAY are to be interpreted as in RFC 2119.

- **Asset**: one unique original owned by one user, identified by the SHA-256 of its bytes.
- **Engine**: the native backup pipeline on a phone (Kotlin on Android, Swift on iOS).
- **Session**: a tus upload resource on the server.
- **Tombstone**: a record that a user deliberately purged content with a given hash.
- **Counter pattern**: test content where byte *i* is (*i* + seed) mod 256.
````

- [ ] **Step 4: Append spec §3–§9 verbatim**

Run from the repo root:
```bash
python - <<'EOF'
import io
spec = io.open("docs/superpowers/specs/2026-10-03-contract-and-sync-protocol-design.md", encoding="utf-8").read()
body = spec[spec.index("## 3. API conventions"):spec.index("## 10. Conformance vectors")]
with io.open("api/protocol/sync-protocol.md", "a", encoding="utf-8", newline="\n") as f:
    f.write("\n" + body.rstrip() + "\n")
EOF
```
Then edit the appended text in two places so it describes the protocol rather than the M0 project:
1. In §4, replace the sentence that starts `Tags marked **engine** form the subset` with: `Operations tagged **engine** are the only ones the native backup engines call.`
2. In §4, replace `Tags \`users\`, \`albums\`, \`shares\`, \`search\`, \`admin\`, \`ml\` are reserved; their endpoints are added by later specs.` with `The tags \`users\`, \`albums\`, \`shares\`, \`search\`, \`admin\` and \`ml\` are reserved for future, additive versions of API v1.`

- [ ] **Step 5: Append §10 Conformance vectors**

Append:
````markdown

## 10. Conformance vectors

Vectors live in `vectors/<dir>/*.json` and validate against `vectors/vectors.schema.json` (run `node api/tools/validate-vectors.mjs --strict`). Each file has `schema_version: 1`, a `kind`, a `description` and a list of `cases`. Directories map to kinds: `hashing/` → `hashing`, `pairing/` → `pairing`, `server-scenarios/` → `server-scenario`, `client-decisions/` → `client-decision`.

### 10.1 Generated content

`{"pattern": "counter", "seed": s, "length": L, "start": a, "end": b}` denotes the bytes at absolute positions *i* ∈ [*a*, *b*) of a stream of length *L* where byte *i* = (*i* + *s*) mod 256. `seed` defaults to 0, `start` to 0 and `end` to *L*. `start` and `end` may be `${name}` references to saved decimal values. Payloads used across vectors:

| Name | seed | length | sha256 |
|---|---|---|---|
| A | 0 | 1048576 | `fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83` |
| B | 1 | 1048576 | `18af9b054114c04a1eb836533a3e760dfa9dc53934ecb02fc059ff27150e77fb` |
| C | 0 | 3145728 | `f6dd7fec8584ad00219a447071c1fa368a1caee4d9c146083d233713ddccd2c0` |
| V | 2 | 1048576 | `c11788fa01aebe9ddeadf2d6fd661693d75a0ca28dc957a6042b5ff6d8a08e66` |

### 10.2 Hashing

The runner streams the input (`file` relative to `api/protocol/`, `inline_utf8` as UTF-8 bytes, or `generate`) through SHA-256 in chunks and compares the lowercase hex digest with `expected_sha256`.

### 10.3 Pairing

Parsing: the scheme MUST be `pictunnel` with host `pair` (`invalid_scheme`); `v` MUST be `1` (`unsupported_version`); `sid` is required (`missing_server_id`); `code` MUST match `^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{2}$` (`invalid_code`); `fp` is required (`missing_fingerprint`); at least one `u` is required (`missing_endpoint`); every `u` MUST use `https://` (`insecure_endpoint`). Duplicate `u` values are dropped, keeping first-occurrence order. Errors are checked in the order listed. When `connection` is present, the expected `accept_connection` is `true` if `system_trusted` is true, otherwise only if `spki_sha256` equals `fp`.

### 10.4 Server scenarios

- Each case runs against a fresh server with an empty library and a controllable test clock.
- For every distinct `user` the runner creates an account (the user slug equals the name); for every actor it pairs a device with the given `platform` to that user. HTTP steps carry `Authorization: Bearer <actor access token>` unless `request.headers.Authorization` is set to an empty string.
- `${name}` is substituted in `path`, header values, JSON string values and `generate.start`/`end`.
- `tus_metadata` becomes the `Upload-Metadata` header: `key base64(UTF-8 value)` pairs, comma-separated, in the listed order.
- `body.generate` becomes the request body with a matching `Content-Length`.
- `transport.drop_after_bytes: N` makes the runner send the headers and the first N body bytes, then close the connection without reading a response; such steps expect `no_response: true`.
- `Location` header values are normalized to their path before saving or comparing.
- `save` reads `header:<Name>` (case-insensitive) or `body:<JSON Pointer>`; numbers are saved as decimal strings.
- Matchers in `expect.headers` and `expect.body` string values: `$any` (present), `$uuid`, `$int` (decimal string or JSON integer), `$sha256`, `$datetime` (RFC 3339), `${name}` (equals a saved value); any other value must be equal. Objects match as subsets (extra keys allowed). Arrays match as ordered subsequences. `{"$len": n}` matches an array of exactly n items.
- Control steps: `advance_clock_seconds` moves the server test clock; `run_job` runs the named job to completion synchronously; `assert_library_paths` compares the exact set of file paths under `<library>/<user>/` (NFC-normalized, relative to the library root); `assert_asset_sources` compares the exact set of `(device, local_id)` links of an asset.

### 10.5 Client decisions

The engine's decision function is fed `given` (flow, item state, last action, item flags) and `server` (a response, or a `transport` failure: `timeout`, `reset` or `offline`), and must produce `expect.next_state`, `expect.action` and `expect.attempts_delta`. `server.problem: "<code>"` expands to the body `{"type": "urn:pictunnel:problem:<code>", "title": "<code>", "status": <status>, "code": "<code>"}`.

| Action | Meaning |
|---|---|
| `mark_backed_up` | Record the server `asset_id`; the item is done |
| `queue_upload` | Put the item in the upload queue |
| `resume_upload` | Continue the known session from the server offset |
| `head_then_resume` | `HEAD` the session, then continue from its offset |
| `restart_upload` | Forget the session and `POST` again (safe: creation is idempotent) |
| `mark_skipped` | Content is tombstoned; offer "back up again" |
| `rehash_and_requeue` | Discard the cached hash, re-hash the file, check again |
| `backoff_retry` | Retry with exponential backoff and full jitter (R5) |
| `wait_retry_after` | Wait for `Retry-After`, then retry |
| `wait_for_network` | Wait for connectivity; not an attempt |
| `refresh_then_retry` | Refresh tokens once, then retry the request (R11) |
| `retry_original_request` | The refresh succeeded; repeat the request that needed it |
| `require_repair` | Credentials are revoked; ask the user to pair again |
| `pause_all_uploads` | Stop uploading for every item and notify the user |
| `notify_quota` | Pause and tell the user how much space is left |
| `prompt_update` | Pause and ask the user to update the app |
| `mark_needs_attention` | Stop retrying this item and list it for the user |
| `run_snapshot` | Discard the cursor and run a full snapshot |
| `retry_later` | Try again on the next view of the item |
| `skip_this_run` | Leave the item unchanged until the next run (R7) |
| `upload_primary_first` | Upload the Live Photo still before its video |
| `upload_live_video` | Upload the missing Live Photo video component |
| `check_then_resolve` | Outcome unknown; ask `/sync/check` before acting (R2) |
| `delete_local_allowed` | All §7.8 conditions hold; request the OS delete with confirmation |
| `delete_local_denied` | At least one §7.8 condition failed; keep the local file |
| `show_error` | Show the problem's message to the user |
| `go_to_login` | Navigate to the login screen |
````

- [ ] **Step 6: Append §11 Worked examples**

Append:
````markdown

## 11. Worked examples

Bodies are abbreviated only where marked `…`. Authentication headers are omitted after the first example.

### 11.1 Server

#### `getHealthz`

```http
GET /healthz

HTTP/1.1 200 OK
Content-Type: text/plain

ok
```

#### `getReadyz`

```http
GET /readyz

HTTP/1.1 503 Service Unavailable
Content-Type: application/problem+json
Retry-After: 5

{"type":"urn:pictunnel:problem:server_unavailable","title":"Storage is not writable","status":503,"code":"server_unavailable"}
```

#### `getServerInfo`

```http
GET /api/v1/server/info

HTTP/1.1 200 OK
Content-Type: application/json

{"server_id":"01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f","name":"Home server","version":"0.1.0","api_version":"1.0",
 "min_client_version":{"android":"0.1.0","ios":"0.1.0","web":"0.1.0"},"capabilities":["tus"],
 "upload":{"tus_version":"1.0.0","max_file_bytes":53687091200,"recommended_chunk_bytes":8388608},
 "time":"2026-10-03T12:00:00Z"}
```

### 11.2 Accounts and tokens

#### `setupFirstAdmin`

```http
POST /api/v1/auth/setup
Content-Type: application/json

{"username":"alice","password":"correct horse battery","display_name":"Alice"}

HTTP/1.1 201 Created
{"user":{"id":"01928f3f-0000-7000-8000-00000000a11c","username":"alice","display_name":"Alice","role":"admin"}}
```
A second call returns `409` with `"code":"setup_already_done"`.

#### `login`

```http
POST /api/v1/auth/login
Content-Type: application/json
PicTunnel-Client: android/0.1.0

{"username":"alice","password":"correct horse battery","mode":"tokens",
 "device":{"device_name":"Pixel 9","platform":"android","app_version":"0.1.0"}}

HTTP/1.1 200 OK
{"user":{"id":"01928f3f-0000-7000-8000-00000000a11c","username":"alice","display_name":"Alice","role":"admin"},
 "device":{"id":"01928f3f-1111-7000-8000-0000000d0001","name":"Pixel 9","platform":"android","app_version":"0.1.0","created_at":"2026-10-03T12:00:00Z","last_seen_at":null},
 "tokens":{"access_token":"pt_at_…","access_token_expires_at":"2026-10-03T12:15:00Z","refresh_token":"pt_rt_…","refresh_token_expires_at":"2027-01-01T12:00:00Z"}}
```
With `"mode":"cookie"` the response sets `Set-Cookie: pt_session=…; HttpOnly; Secure; SameSite=Lax; Path=/` and returns `csrf_token`; later state-changing requests send `X-CSRF-Token`.

#### `refreshTokens`

```http
POST /api/v1/auth/refresh
Content-Type: application/json

{"refresh_token":"pt_rt_…"}

HTTP/1.1 200 OK
{"access_token":"pt_at_…","access_token_expires_at":"2026-10-03T12:30:00Z","refresh_token":"pt_rt_…(new)","refresh_token_expires_at":"2027-01-01T12:15:00Z"}
```
Presenting the old refresh token again within 30 s returns the same pair; after 30 s it returns `401` with `"code":"refresh_token_reused"` and the device is revoked.

#### `logout`

```http
POST /api/v1/auth/logout
Authorization: Bearer pt_at_…

HTTP/1.1 204 No Content
```

### 11.3 Pairing and devices

#### `createPairingCode`

```http
POST /api/v1/pairing/codes

HTTP/1.1 201 Created
{"code":"K7Q2-M9XD-4T",
 "qr_uri":"pictunnel://pair?v=1&sid=01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f&code=K7Q2-M9XD-4T&fp=xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc&u=https%3A%2F%2F192.168.1.20%3A8443",
 "expires_at":"2026-10-03T12:10:00Z"}
```

#### `redeemPairingCode`

```http
POST /api/v1/pairing/redeem
Content-Type: application/json

{"code":"K7Q2-M9XD-4T","device":{"device_name":"Alice's iPhone","platform":"ios","app_version":"0.1.0"}}

HTTP/1.1 201 Created
{"server_id":"01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f","user":{…},"device":{…},"tokens":{…}}
```
An unknown, used or expired code returns `400` with `"code":"pairing_code_invalid"`.

#### `listDevices`

```http
GET /api/v1/devices

HTTP/1.1 200 OK
{"devices":[{"id":"01928f3f-1111-7000-8000-0000000d0001","name":"Pixel 9","platform":"android","app_version":"0.1.0","created_at":"2026-10-03T12:00:00Z","last_seen_at":"2026-10-03T12:05:00Z"}]}
```

#### `updateDevice`

```http
PATCH /api/v1/devices/01928f3f-1111-7000-8000-0000000d0001
Content-Type: application/json

{"name":"Alice's Pixel"}

HTTP/1.1 200 OK
{"id":"01928f3f-1111-7000-8000-0000000d0001","name":"Alice's Pixel","platform":"android","app_version":"0.1.0","created_at":"2026-10-03T12:00:00Z","last_seen_at":"2026-10-03T12:05:00Z"}
```

#### `revokeDevice`

```http
DELETE /api/v1/devices/01928f3f-1111-7000-8000-0000000d0001

HTTP/1.1 204 No Content
```

### 11.4 Sync

#### `checkContent`

```http
POST /api/v1/sync/check
Content-Type: application/json

{"items":[
  {"sha256":"fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83","size_bytes":1048576,"local_id":"a-1"},
  {"sha256":"18af9b054114c04a1eb836533a3e760dfa9dc53934ecb02fc059ff27150e77fb","size_bytes":1048576},
  {"sha256":"f6dd7fec8584ad00219a447071c1fa368a1caee4d9c146083d233713ddccd2c0","size_bytes":3145728}]}

HTTP/1.1 200 OK
{"results":[
  {"sha256":"fbbab289…7c83","verdict":"exists","asset_id":"01928f40-0000-7000-8000-000000000001","asset_state":"active","has_live_video":false},
  {"sha256":"18af9b05…77fb","verdict":"missing"},
  {"sha256":"f6dd7fec…d2c0","verdict":"partial","upload":{"id":"01928f40-1111-7aaa-8bbb-0123456789ab","url":"/api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab","offset":1048576,"length":3145728,"expires_at":"2026-10-04T12:00:00Z"}}]}
```

#### `getSnapshot`

```http
GET /api/v1/sync/snapshot?limit=1000

HTTP/1.1 200 OK
{"cursor":"c_00000000000003e9","assets":[{"id":"01928f40-0000-7000-8000-000000000001","sha256":"fbbab289…7c83","kind":"photo","state":"active",…}],
 "next_page_token":null,"has_more":false}
```

#### `getChanges`

```http
GET /api/v1/sync/changes?cursor=c_00000000000003e9&limit=500

HTTP/1.1 200 OK
{"changes":[
  {"seq":1002,"kind":"asset.upsert","asset":{"id":"01928f40-0000-7000-8000-000000000002","state":"active",…}},
  {"seq":1003,"kind":"asset.removed","asset_id":"01928f40-0000-7000-8000-000000000001"}],
 "next_cursor":"c_00000000000003eb","has_more":false}
```
A cursor older than 90 days returns `410` with `"code":"cursor_expired"`; omitting it returns `400` with `"code":"cursor_required"`.

### 11.5 Uploads (tus)

The metadata below encodes `sha256`, `filename` (`IMG_0001.JPG`), `mime` (`image/jpeg`) and `local_id` (`a-1`).

#### `optionsUploads`

```http
OPTIONS /api/v1/uploads

HTTP/1.1 204 No Content
Tus-Resumable: 1.0.0
Tus-Version: 1.0.0
Tus-Extension: creation,creation-with-upload,termination,expiration,checksum
Tus-Max-Size: 53687091200
Tus-Checksum-Algorithm: sha256
```

#### `createUpload`

Bodyless creation:
```http
POST /api/v1/uploads
Tus-Resumable: 1.0.0
Upload-Length: 1048576
Upload-Metadata: sha256 ZmJiYWIyODlmN2Y5NGIyNTczNmM1OGJlNDZhOTk0YzQ0MWZkMDI1NTJjYzYwMjIzNTJlM2Q4NmQyZmFiN2M4Mw==,filename SU1HXzAwMDEuSlBH,mime aW1hZ2UvanBlZw==,local_id YS0x

HTTP/1.1 201 Created
Tus-Resumable: 1.0.0
Location: /api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab
Upload-Expires: Sun, 04 Oct 2026 12:00:00 GMT
```
Creation with upload (iOS single shot) finalizes in the same request:
```http
POST /api/v1/uploads
Tus-Resumable: 1.0.0
Upload-Length: 1048576
Upload-Metadata: sha256 ZmJiYWIy…,filename SU1HXzAwMDEuSlBH,mime aW1hZ2UvanBlZw==
Content-Type: application/offset+octet-stream
Content-Length: 1048576

<1048576 bytes>

HTTP/1.1 201 Created
Location: /api/v1/uploads/01928f40-2222-7aaa-8bbb-0123456789ab
Upload-Offset: 1048576
PicTunnel-Asset-Id: 01928f40-0000-7000-8000-000000000001
PicTunnel-Asset-Created: true
```
Content the user already has resolves without storing bytes: `201` with `Upload-Offset` equal to `Upload-Length`, `PicTunnel-Asset-Id` of the existing asset and `PicTunnel-Asset-Created: false`. Tombstoned content returns `409` with `"code":"tombstoned"` unless metadata includes `override_tombstone MQ==` (base64 of `1`).

#### `getUploadOffset`

```http
HEAD /api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab
Tus-Resumable: 1.0.0

HTTP/1.1 200 OK
Upload-Offset: 524288
Upload-Length: 1048576
Upload-Expires: Sun, 04 Oct 2026 12:00:00 GMT
```

#### `appendUpload`

```http
PATCH /api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab
Tus-Resumable: 1.0.0
Upload-Offset: 524288
Content-Type: application/offset+octet-stream
Content-Length: 524288

<524288 bytes>

HTTP/1.1 204 No Content
Upload-Offset: 1048576
PicTunnel-Asset-Id: 01928f40-0000-7000-8000-000000000001
PicTunnel-Asset-Created: true
```
A wrong offset returns `409` with `"code":"offset_mismatch"` and the server's `Upload-Offset`; bytes that do not hash to the declared sha256 return `460` with `"code":"checksum_mismatch"` and the session is discarded.

#### `terminateUpload`

```http
DELETE /api/v1/uploads/01928f40-1111-7aaa-8bbb-0123456789ab
Tus-Resumable: 1.0.0

HTTP/1.1 204 No Content
```

### 11.6 Assets, trash and tombstones

#### `getAsset`

```http
GET /api/v1/assets/01928f40-0000-7000-8000-000000000001

HTTP/1.1 200 OK
{"id":"01928f40-0000-7000-8000-000000000001","sha256":"fbbab289…7c83","size_bytes":1048576,"mime":"image/jpeg","kind":"photo",
 "filename":"IMG_0001.JPG","taken_at":"2024-05-06T10:00:00Z","taken_at_offset_minutes":120,"taken_at_source":"exif",
 "width":4032,"height":3024,"duration_ms":null,"lat":38.7223,"lon":-9.1393,"state":"active","trashed_at":null,
 "stack_id":null,"thumbnails_ready":true,"created_at":"2026-10-03T12:00:02Z","updated_seq":1001}
```

#### `getAssetThumbnail`

```http
GET /api/v1/assets/01928f40-0000-7000-8000-000000000001/thumbnail?size=preview

HTTP/1.1 200 OK
Content-Type: image/jpeg
ETag: "3b1e…"

<jpeg bytes>
```
Before the thumbnail job has run: `404` with `"code":"not_ready"`.

#### `getAssetOriginal`

```http
GET /api/v1/assets/01928f40-0000-7000-8000-000000000001/original
Range: bytes=0-1023

HTTP/1.1 206 Partial Content
Content-Type: application/octet-stream
Content-Range: bytes 0-1023/1048576
ETag: "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83"

<1024 bytes>
```

#### `getAssetPlayback`

```http
GET /api/v1/assets/01928f40-0000-7000-8000-000000000003/playback
Range: bytes=0-

HTTP/1.1 206 Partial Content
Content-Type: video/mp4
Content-Range: bytes 0-3145727/3145728

<mp4 bytes>
```

#### `trashAssets`

```http
POST /api/v1/assets/trash
Content-Type: application/json

{"asset_ids":["01928f40-0000-7000-8000-000000000001","01928f40-0000-7000-8000-0000000000ff"]}

HTTP/1.1 200 OK
{"succeeded":["01928f40-0000-7000-8000-000000000001"],"failed":[{"asset_id":"01928f40-0000-7000-8000-0000000000ff","code":"not_found"}]}
```

#### `restoreAssets`

```http
POST /api/v1/assets/restore
Content-Type: application/json

{"asset_ids":["01928f40-0000-7000-8000-000000000001"]}

HTTP/1.1 200 OK
{"succeeded":["01928f40-0000-7000-8000-000000000001"],"failed":[]}
```

#### `purgeAssets`

```http
POST /api/v1/assets/purge
Content-Type: application/json

{"asset_ids":["01928f40-0000-7000-8000-000000000001","01928f40-0000-7000-8000-000000000002"]}

HTTP/1.1 200 OK
{"succeeded":["01928f40-0000-7000-8000-000000000001"],"failed":[{"asset_id":"01928f40-0000-7000-8000-000000000002","code":"not_trashed"}]}
```

#### `emptyTrash`

```http
POST /api/v1/trash/empty

HTTP/1.1 200 OK
{"purged_count":12}
```

#### `listTombstones`

```http
GET /api/v1/tombstones?limit=50

HTTP/1.1 200 OK
{"tombstones":[{"sha256":"fbbab289…7c83","filename":"IMG_0001.JPG","deleted_at":"2026-10-03T13:00:00Z"}],"next_cursor":null,"has_more":false}
```

#### `deleteTombstone`

```http
DELETE /api/v1/tombstones/fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83

HTTP/1.1 204 No Content
```
````

- [ ] **Step 7: Enforce the doc check in lint**

Set the `lint` script in `api/package.json` to:
```json
"lint": "redocly lint pictunnel@v1 && node tools/contract-rules.mjs openapi.yaml && node tools/check-protocol-doc.mjs openapi.yaml protocol/sync-protocol.md"
```
Run: `task lint:api`
Expected: Redocly clean, `contract rules: ok`, `protocol doc: ok (30 operations have examples)`.

- [ ] **Step 8: Commit**

```bash
git add api/protocol/sync-protocol.md api/tools/check-protocol-doc.mjs api/tools/check-protocol-doc.test.mjs api/package.json
git commit -s -m "docs(api): add normative sync protocol with worked examples"
```

---

### Task 22: CI workflows and aggregate tasks

**Files:**
- Create: `.github/workflows/ci-repo.yml`, `ci-api.yml`, `ci-server.yml`, `ci-mobile.yml`, `ci-web.yml`, `ci-ml.yml`, `dco.yml`, `tools/ci/check-clean.mjs`
- Modify: `Taskfile.yml` (append `setup`, `gen`, `lint`, `test`, `check:drift`, `ci`)

**Interfaces:**
- Consumes: every task above.
- Produces: `task ci` (everything CI runs), path-filtered workflows; required checks for `main`.

- [ ] **Step 1: Create `tools/ci/check-clean.mjs`**

```js
// Fails when the working tree differs from HEAD, including untracked files (used after `task gen`).
import { execFileSync } from "node:child_process";

const out = execFileSync("git", ["status", "--porcelain"], { encoding: "utf8" }).trim();
if (out) {
  console.error("Generated output differs from the committed files. Run `task gen` and commit:\n" + out);
  process.exit(1);
}
console.log("working tree clean");
```

- [ ] **Step 2: Append aggregate tasks to `Taskfile.yml`**

```yaml

  setup:
    desc: Install JavaScript dependencies for api/ and web/
    cmds:
      - pnpm --dir api install --frozen-lockfile
      - pnpm --dir web install --frozen-lockfile

  gen:
    desc: Regenerate every client from api/openapi.yaml
    cmds:
      - task: gen:go
      - task: gen:ts
      - task: gen:kotlin
      - task: gen:swift
      - task: gen:dart

  lint:
    desc: Contract lint and repository checks
    cmds:
      - task: lint:api
      - task: check:eol

  test:
    desc: Every test suite
    cmds:
      - task: test:tools
      - task: test:api
      - task: test:server
      - task: test:web
      - task: test:kotlin
      - task: test:swift
      - task: test:mobile
      - task: test:ml

  check:drift:
    desc: Fail if generated code differs from the commit
    cmds:
      - node tools/ci/check-clean.mjs

  ci:
    desc: Everything CI checks, runnable locally (start from a clean working tree)
    cmds:
      - task: setup
      - task: lint
      - task: vectors:validate
      - task: gen
      - task: check:drift
      - task: test
```

- [ ] **Step 3: Create `.github/workflows/ci-repo.yml`**

```yaml
name: ci-repo
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
jobs:
  repo:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 24
      - name: Line endings
        run: node tools/ci/check-eol.mjs
      - name: Repo script tests
        run: node --test "tools/ci/*.test.mjs"
      - name: Lint workflows
        run: docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest -color
```

- [ ] **Step 4: Create `.github/workflows/ci-api.yml`**

```yaml
name: ci-api
on:
  push:
    branches: [main]
    paths:
      - "api/**"
      - "server/internal/httpapi/**"
      - "web/src/lib/api/**"
      - "mobile/packages/pictunnel_api/**"
      - "mobile/android/engine-api/generated/**"
      - "mobile/ios/EngineAPI/Sources/EngineAPI/Generated/**"
      - "Taskfile.yml"
      - "tools/**"
      - ".github/workflows/ci-api.yml"
  pull_request:
    paths:
      - "api/**"
      - "server/internal/httpapi/**"
      - "web/src/lib/api/**"
      - "mobile/packages/pictunnel_api/**"
      - "mobile/android/engine-api/generated/**"
      - "mobile/ios/EngineAPI/Sources/EngineAPI/Generated/**"
      - "Taskfile.yml"
      - "tools/**"
      - ".github/workflows/ci-api.yml"
permissions:
  contents: read
jobs:
  contract:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: pnpm/action-setup@v4
        with:
          version: 10
      - uses: actions/setup-node@v4
        with:
          node-version: 24
          cache: pnpm
          cache-dependency-path: "**/pnpm-lock.yaml"
      - uses: arduino/setup-task@v2
        with:
          version: 3.x
          repo-token: ${{ secrets.GITHUB_TOKEN }}
      - run: task api:install
      - run: task lint:api
      - run: task test:api
      - run: task vectors:validate
      - name: Breaking changes against the base branch
        if: github.event_name == 'pull_request'
        run: |
          if git show "origin/${{ github.base_ref }}:api/openapi.yaml" > /tmp/base.yaml 2>/dev/null; then
            docker run --rm -v /tmp:/base -v "$PWD/api:/spec" tufin/oasdiff breaking /base/base.yaml /spec/openapi.yaml --fail-on ERR
          else
            echo "No contract on the base branch yet; skipping."
          fi
  codegen-drift:
    needs: contract
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
        with:
          version: 10
      - uses: actions/setup-node@v4
        with:
          node-version: 24
          cache: pnpm
          cache-dependency-path: "**/pnpm-lock.yaml"
      - uses: actions/setup-go@v5
        with:
          go-version-file: server/go.mod
      - uses: arduino/setup-task@v2
        with:
          version: 3.x
          repo-token: ${{ secrets.GITHUB_TOKEN }}
      - uses: actions/cache@v4
        with:
          path: .cache
          key: codegen-${{ hashFiles('Taskfile.yml') }}
      - run: task setup
      - name: Generated code matches the commit
        run: task gen && task check:drift
      - name: Generation is deterministic
        run: task gen && task check:drift
      - name: No root-owned files from containers
        run: test -z "$(find . -path ./.git -prune -o -user root -print | head -1)"
```

- [ ] **Step 5: Create `.github/workflows/ci-server.yml`**

```yaml
name: ci-server
on:
  push:
    branches: [main]
    paths: ["server/**", "api/openapi.yaml", "api/protocol/**", ".github/workflows/ci-server.yml"]
  pull_request:
    paths: ["server/**", "api/openapi.yaml", "api/protocol/**", ".github/workflows/ci-server.yml"]
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version-file: server/go.mod
          cache-dependency-path: server/go.sum
      - uses: golangci/golangci-lint-action@v8
        with:
          version: latest
          working-directory: server
      - run: go vet ./...
        working-directory: server
      - run: go test -race ./...
        working-directory: server
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        target: [linux/amd64, linux/arm64, windows/amd64, darwin/arm64]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version-file: server/go.mod
          cache-dependency-path: server/go.sum
      - name: Cross-compile without cgo
        working-directory: server
        env:
          TARGET: ${{ matrix.target }}
        run: CGO_ENABLED=0 GOOS="${TARGET%/*}" GOARCH="${TARGET#*/}" go build -o /dev/null ./cmd/pictunnel
```

- [ ] **Step 6: Create `.github/workflows/ci-mobile.yml`**

```yaml
name: ci-mobile
on:
  push:
    branches: [main]
    paths: ["mobile/**", "api/protocol/**", ".github/workflows/ci-mobile.yml"]
  pull_request:
    paths: ["mobile/**", "api/protocol/**", ".github/workflows/ci-mobile.yml"]
permissions:
  contents: read
jobs:
  flutter-android:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: 17
      - id: flutter
        run: echo "version=$(cat mobile/.flutter-version)" >> "$GITHUB_OUTPUT"
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          flutter-version: ${{ steps.flutter.outputs.version }}
          cache: true
      - uses: arduino/setup-task@v2
        with:
          version: 3.x
          repo-token: ${{ secrets.GITHUB_TOKEN }}
      - run: task test:mobile TOOLS_MODE=native
      - name: Build Android debug APK
        working-directory: mobile
        run: flutter build apk --debug
  engine-kotlin:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: 17
          cache: gradle
      - uses: arduino/setup-task@v2
        with:
          version: 3.x
          repo-token: ${{ secrets.GITHUB_TOKEN }}
      - run: task test:kotlin TOOLS_MODE=native
  ios:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - id: flutter
        run: echo "version=$(cat mobile/.flutter-version)" >> "$GITHUB_OUTPUT"
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          flutter-version: ${{ steps.flutter.outputs.version }}
          cache: true
      - name: Build iOS without code signing
        working-directory: mobile
        run: flutter pub get && flutter build ios --debug --no-codesign
      - name: Swift EngineAPI tests
        run: swift test --package-path mobile/ios/EngineAPI
```

- [ ] **Step 7: Create `.github/workflows/ci-web.yml`, `ci-ml.yml` and `dco.yml`**

`.github/workflows/ci-web.yml`:
```yaml
name: ci-web
on:
  push:
    branches: [main]
    paths: ["web/**", "api/openapi.yaml", ".github/workflows/ci-web.yml"]
  pull_request:
    paths: ["web/**", "api/openapi.yaml", ".github/workflows/ci-web.yml"]
permissions:
  contents: read
jobs:
  web:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
        with:
          version: 10
      - uses: actions/setup-node@v4
        with:
          node-version: 24
          cache: pnpm
          cache-dependency-path: web/pnpm-lock.yaml
      - uses: arduino/setup-task@v2
        with:
          version: 3.x
          repo-token: ${{ secrets.GITHUB_TOKEN }}
      - run: pnpm --dir web install --frozen-lockfile
      - run: task test:web
```

`.github/workflows/ci-ml.yml`:
```yaml
name: ci-ml
on:
  push:
    branches: [main]
    paths: ["ml/**", ".github/workflows/ci-ml.yml"]
  pull_request:
    paths: ["ml/**", ".github/workflows/ci-ml.yml"]
permissions:
  contents: read
jobs:
  ml:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v6
      - uses: arduino/setup-task@v2
        with:
          version: 3.x
          repo-token: ${{ secrets.GITHUB_TOKEN }}
      - run: task test:ml
```

`.github/workflows/dco.yml`:
```yaml
name: dco
on:
  pull_request:
permissions:
  contents: read
jobs:
  signoff:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/setup-node@v4
        with:
          node-version: 24
      - run: node tools/ci/check-dco.mjs "origin/${{ github.base_ref }}" HEAD
```

- [ ] **Step 8: Lint the workflows locally (PowerShell)**

```powershell
docker run --rm -v "${PWD}:/repo" -w /repo rhysd/actionlint:latest -color
```
Expected: no output, exit 0.

- [ ] **Step 9: Commit**

```bash
git add .github/workflows tools/ci/check-clean.mjs Taskfile.yml
git commit -s -m "ci: add path-filtered workflows, drift check and aggregate tasks"
```

---

### Task 23: Full verification and publication

**Files:**
- Modify: `README.md` (status line) only if all checks pass

**Interfaces:**
- Consumes: everything.
- Produces: a public GitHub repository with green CI (only after the user approves publishing).

- [ ] **Step 1: Run everything locally from a clean tree**

Run: `git status --porcelain` → no output. Then `task ci`.
Expected: every subtask succeeds, including `working tree clean` after `task gen`.

- [ ] **Step 2: Check determinism locally**

Run: `task gen && task check:drift` a second time.
Expected: `working tree clean`.

- [ ] **Step 3: Walk the M0 acceptance criteria (spec §14)**

| # | Criterion | Evidence |
|---|---|---|
| 1 | Contract complete and linted | `task lint:api` clean; `grep -c "operationId:" api/openapi.yaml` = 30 |
| 2 | Protocol doc normative with examples | `protocol doc: ok (30 operations have examples)` |
| 3 | Vector minimums | `task vectors:validate` counts: hashing 11, pairing 12, server-scenario 17, client-decision 51 |
| 4 | All five generators compile | `task test:server`, `task test:web`, `task test:kotlin`, `task test:swift`, `task test:mobile` pass |
| 5 | Hashing vectors pass in Go, Kotlin, Swift | `TestHashingVectors`, `allHashingVectorsMatch`, `testAllHashingVectorsMatch` pass |
| 6 | CI green including macOS | Step 6 below |
| 7 | ADRs, licenses, contributor docs, DCO | `ls docs/adr` = 11 files; `dco` workflow present |

Record any criterion that fails; fix it before continuing (use superpowers:systematic-debugging for failures).

- [ ] **Step 4: Ask the user before publishing**

Creating a public GitHub repository is outward-facing and hard to undo. Stop and ask:
"M0 passes locally. May I create the public repository `PrithvirajG/pictunnel` on GitHub and push `main`?"
Continue only on an explicit yes.

- [ ] **Step 5: Publish**

```bash
gh repo create PrithvirajG/pictunnel --public --source . --remote origin --push --description "Self-hosted photo and video backup that installs like an app"
gh api -X PUT repos/PrithvirajG/pictunnel/private-vulnerability-reporting
```

- [ ] **Step 6: Watch CI to green**

```bash
gh run list --limit 10
gh run watch
```
Expected: `ci-repo`, `ci-api`, `ci-server`, `ci-mobile` (including the macOS `ios` job), `ci-web`, `ci-ml` all succeed. On failure, read the logs with `gh run view <id> --log-failed`, fix on a branch, and push until green.

- [ ] **Step 7: Update the README status and commit**

In `README.md` replace the status block with:
```markdown
> **Status: pre-alpha.** Milestone M0 is complete: API contract, sync protocol, conformance vectors and repository foundation. Next: sub-project 2 (server core).
```
```bash
git add README.md
git commit -s -m "docs: mark milestone M0 complete"
git push
```
