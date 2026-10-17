// tus-js-client interop test (S§11.6): runs a real PicTunnel server and
// uploads payload C with tus-js-client, aborting after two 1 MiB chunks and
// resuming with findPreviousUploads, then checks the asset via /sync/check.
//
//   node upload.mjs            (from server/test/interop/tus-js, after pnpm install)
//
// Env: INTEROP_HTTPS_PORT (default 18443), INTEROP_LOCAL_PORT (default 18080),
// INTEROP_KEEP=1 keeps the temp data dir. Exits non-zero on any failure and
// always stops the server.
//
// NODE_EXTRA_CA_CERTS is read by Node only at startup, so the script runs in
// two phases: the parent builds and starts the server, then re-runs itself
// with NODE_EXTRA_CA_CERTS=<data>/tls/ca.crt to do the HTTPS work.
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const serverDir = resolve(here, "../../..");
const httpsPort = Number(process.env.INTEROP_HTTPS_PORT ?? 18443);
const localPort = Number(process.env.INTEROP_LOCAL_PORT ?? 18080);

// Payload C (P§10.1): byte i = i mod 256, 3 MiB.
const PAYLOAD_C_LENGTH = 3145728;
const PAYLOAD_C_SHA256 = "f6dd7fec8584ad00219a447071c1fa368a1caee4d9c146083d233713ddccd2c0";
const CHUNK = 1048576;

function fail(msg) {
  throw new Error(msg);
}

function payloadC() {
  const b = Buffer.alloc(PAYLOAD_C_LENGTH);
  for (let i = 0; i < b.length; i++) b[i] = i % 256;
  const sha = createHash("sha256").update(b).digest("hex");
  if (sha !== PAYLOAD_C_SHA256) fail(`payload C sha256 ${sha}, P§10.1 says ${PAYLOAD_C_SHA256}`);
  return b;
}

async function json(res, want, what) {
  const text = await res.text();
  if (res.status !== want) fail(`${what}: HTTP ${res.status}, want ${want}: ${text}`);
  return text ? JSON.parse(text) : null;
}

// ---- Phase 2: the client, with the server's CA trusted. ----
async function client() {
  const tus = (await import("tus-js-client")).default;
  const base = `https://127.0.0.1:${httpsPort}`;
  const local = `http://127.0.0.1:${localPort}`;
  const device = { device_name: "tus-js interop", platform: "web", app_version: "0.1.0" };
  const password = "correct horse battery";

  // First-run setup over the loopback listener (no setup token needed).
  await json(
    await fetch(`${local}/api/v1/auth/setup`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username: "alice", password, display_name: "Alice" }),
    }),
    201,
    "setup",
  );
  // Log in over HTTPS, create a pairing code and pair a second device.
  const login = await json(
    await fetch(`${base}/api/v1/auth/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username: "alice", password, mode: "tokens", device }),
    }),
    200,
    "login",
  );
  const code = await json(
    await fetch(`${base}/api/v1/pairing/codes`, {
      method: "POST",
      headers: { Authorization: `Bearer ${login.tokens.access_token}` },
    }),
    201,
    "create pairing code",
  );
  const paired = await json(
    await fetch(`${base}/api/v1/pairing/redeem`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: code.code, device: { ...device, device_name: "tus-js paired" } }),
    }),
    201,
    "redeem pairing code",
  );
  const auth = { Authorization: `Bearer ${paired.tokens.access_token}` };

  const content = payloadC();
  const urlStorage = new tus.FileUrlStorage(join(process.env.INTEROP_DATA_DIR, "tus-url-storage.json"));
  const common = {
    endpoint: `${base}/api/v1/uploads`,
    chunkSize: CHUNK,
    headers: auth,
    metadata: { sha256: PAYLOAD_C_SHA256, filename: "IMG_C.JPG", mime: "image/jpeg" },
    urlStorage,
    storeFingerprintForResuming: true,
    removeFingerprintOnSuccess: true,
    retryDelays: null,
  };

  // Upload 1: stop after the second chunk is acknowledged.
  let firstURL = null;
  await new Promise((resolveUp, rejectUp) => {
    let chunks = 0;
    const up = new tus.Upload(content, {
      ...common,
      onError: rejectUp,
      onSuccess: () => rejectUp(new Error("first upload finished; it should have been aborted")),
      onChunkComplete: (_size, sent) => {
        chunks++;
        if (chunks === 2) {
          if (sent !== 2 * CHUNK) rejectUp(new Error(`acknowledged ${sent} bytes after 2 chunks`));
          firstURL = up.url;
          up.abort().then(resolveUp, rejectUp);
        }
      },
    });
    up.start();
  });
  console.log(`aborted after 2 chunks at ${firstURL}`);

  // Upload 2: a new Upload finds the stored URL and resumes from 2 MiB.
  let headOffset = null;
  let assetId = null;
  await new Promise((resolveUp, rejectUp) => {
    const up = new tus.Upload(content, {
      ...common,
      onError: rejectUp,
      onSuccess: resolveUp,
      onAfterResponse: (req, res) => {
        if (req.getMethod() === "HEAD") headOffset = Number(res.getHeader("Upload-Offset"));
        const id = res.getHeader("PicTunnel-Asset-Id");
        if (id) assetId = id;
      },
    });
    up.findPreviousUploads()
      .then((previous) => {
        if (previous.length !== 1) throw new Error(`findPreviousUploads: ${previous.length} uploads`);
        up.resumeFromPreviousUpload(previous[0]);
        up.start();
        if (up.url !== null && up.url !== firstURL) throw new Error(`resumed ${up.url}, want ${firstURL}`);
      })
      .catch(rejectUp);
  });
  if (headOffset !== 2 * CHUNK) fail(`resume HEAD offset ${headOffset}, want ${2 * CHUNK}`);
  if (!assetId) fail("the final PATCH carried no PicTunnel-Asset-Id");
  console.log(`resumed from ${headOffset} and finished: asset ${assetId}`);

  const check = await json(
    await fetch(`${base}/api/v1/sync/check`, {
      method: "POST",
      headers: { ...auth, "Content-Type": "application/json" },
      body: JSON.stringify({ items: [{ sha256: PAYLOAD_C_SHA256, size_bytes: PAYLOAD_C_LENGTH }] }),
    }),
    200,
    "sync check",
  );
  const r = check.results?.[0];
  if (r?.verdict !== "exists" || r.asset_id !== assetId) fail(`sync check: ${JSON.stringify(check)}`);
  console.log("sync check: exists");
}

// ---- Phase 1: build and run the server, then run the client phase. ----
function waitForLine(proc, pattern, timeoutMs, log) {
  return new Promise((resolveLine, rejectLine) => {
    let buf = "";
    const timer = setTimeout(() => rejectLine(new Error(`server did not print ${pattern} within ${timeoutMs} ms\n${log()}`)), timeoutMs);
    const onData = (d) => {
      buf += d;
      const m = buf.match(pattern);
      if (m) {
        clearTimeout(timer);
        proc.stdout.off("data", onData);
        resolveLine(m);
      }
    };
    proc.stdout.on("data", onData);
    proc.once("exit", (code) => {
      clearTimeout(timer);
      rejectLine(new Error(`server exited (${code}) before ${pattern}\n${log()}`));
    });
  });
}

function stopServer(proc) {
  return new Promise((resolveStop) => {
    if (proc.exitCode !== null || proc.signalCode !== null) return resolveStop();
    const hard = setTimeout(() => proc.kill("SIGKILL"), 10000);
    proc.once("exit", () => {
      clearTimeout(hard);
      resolveStop();
    });
    // Closing stdin plus SIGTERM: Windows has no SIGTERM, kill() terminates.
    proc.stdin.end();
    proc.kill("SIGTERM");
  });
}

async function main() {
  const dataDir = mkdtempSync(join(tmpdir(), "pictunnel-interop-"));
  const exe = join(dataDir, process.platform === "win32" ? "pictunnel.exe" : "pictunnel");
  let server = null;
  let output = "";
  try {
    // Build once and run the binary directly, so stopping it stops the
    // server (a `go run` wrapper would leave its child running on Windows).
    const build = spawnSync("go", ["build", "-o", exe, "./cmd/pictunnel"], { cwd: serverDir, stdio: "inherit" });
    if (build.status !== 0) fail(`go build failed (${build.status ?? build.error})`);
    const serverData = join(dataDir, "data");
    server = spawn(
      exe,
      [
        "serve",
        `--data-dir=${serverData}`,
        `--server.https-addr=127.0.0.1:${httpsPort}`,
        `--server.local-addr=127.0.0.1:${localPort}`,
        "--discovery.mdns=false",
        "--log.format=text",
        "--log.level=warn",
      ],
      { cwd: dataDir, stdio: ["pipe", "pipe", "pipe"] },
    );
    server.stdout.setEncoding("utf8");
    server.stderr.setEncoding("utf8");
    server.stdout.on("data", (d) => (output += d));
    server.stderr.on("data", (d) => (output += d));
    await waitForLine(server, /PicTunnel-Setup-Token: (\S+)/, 60000, () => output);
    const ca = join(serverData, "tls", "ca.crt");
    if (!existsSync(ca)) fail(`no CA certificate at ${ca}`);

    const child = spawnSync(process.execPath, [fileURLToPath(import.meta.url)], {
      stdio: "inherit",
      env: { ...process.env, INTEROP_PHASE: "client", INTEROP_DATA_DIR: dataDir, NODE_EXTRA_CA_CERTS: ca },
    });
    if (child.status !== 0) fail(`client phase failed (exit ${child.status ?? child.error})`);
    console.log("PASS tus-js-client interop");
  } catch (err) {
    process.exitCode = 1;
    throw err;
  } finally {
    if (server) await stopServer(server);
    if (process.exitCode && output) console.error(`--- server output ---\n${output}`);
    if (process.env.INTEROP_KEEP === "1") {
      console.log(`kept ${dataDir}`);
    } else {
      rmSync(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    }
  }
}

const phase = process.env.INTEROP_PHASE === "client" ? client : main;
phase().catch((err) => {
  console.error(`FAIL: ${err?.stack ?? err}`);
  process.exitCode = 1;
});
