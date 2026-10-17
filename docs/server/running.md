# Running the PicTunnel server

The server is one binary, `pictunnel`. This page covers how to start it, how
to configure it, the first-run setup, TLS and certificate pinning, LAN
discovery, the ffmpeg requirement, and what lives in the data directory.
The design behind it is
[`docs/superpowers/specs/2026-10-12-server-sync-core-design.md`](../superpowers/specs/2026-10-12-server-sync-core-design.md)
(S§ below); the wire contract is [`api/openapi.yaml`](../../api/openapi.yaml)
with [`api/protocol/sync-protocol.md`](../../api/protocol/sync-protocol.md).

## Commands

```sh
pictunnel serve [flags]                    # run the server
pictunnel version                          # print the version
pictunnel reset-password <user> [flags]    # offline: new random password, signs out the user's devices
```

From a checkout: `cd server && go run ./cmd/pictunnel serve --data-dir ./data`.

`reset-password` takes the data-dir lock, so it refuses to run while the
server is running. It prints the new password once.

`serve` shuts down gracefully on Ctrl+C or `SIGTERM`.

## Configuration

Every setting has a dotted key. Sources are applied in this order, and later
sources win:

1. Built-in defaults.
2. `<data_dir>/config.toml`, which is optional.
3. Environment variables `PICTUNNEL_<SECTION>_<KEY>`, for example
   `PICTUNNEL_SERVER_HTTPS_ADDR=:9443` or `PICTUNNEL_DATA_DIR=/srv/pictunnel`.
4. Flags, with dots kept and underscores replaced by dashes, for example
   `--server.https-addr=:9443` or `--discovery.mdns=false`.

`data_dir` is resolved first, because it locates `config.toml`.

| Key | Default | Meaning |
|---|---|---|
| `data_dir` | Windows `%ProgramData%\PicTunnel`, macOS `~/Library/Application Support/PicTunnel`, Linux `/var/lib/pictunnel`, in Docker `/data` | Database, keys, TLS material, staging and derived files |
| `library_dir` | `<data_dir>/library` | The readable photo library (`<user>/YYYY/MM/<file>`). A library outside the data dir must already exist, so an unmounted volume is never taken for an empty library. |
| `server.name` | host name | Name advertised over mDNS |
| `server.https_addr` | `:8443` | HTTPS listener (all interfaces), the full API |
| `server.local_addr` | `127.0.0.1:8080` | Loopback HTTP listener; empty turns it off |
| `server.public_urls` | none | Extra endpoints (comma-separated) put into pairing QR codes after the LAN ones |
| `tls.mode` | `self-signed` | `self-signed`, `files` (with `tls.cert_file`, `tls.key_file`) or `off` |
| `discovery.mdns` | `true` | Advertise `_pictunnel._tcp` on the LAN |
| `upload.max_file_bytes` | `53687091200` (50 GiB) | Largest accepted file |
| `upload.recommended_chunk_bytes` | `8388608` | Chunk size advertised to clients |
| `storage.reserve_bytes` | `1073741824` (1 GiB) | Free space kept on the staging and library volumes |
| `trash.retention_days` | `30` | Trashed assets are purged after this |
| `clients.min_version.android` / `.ios` / `.web` | `0.1.0` | Below this an app gets `426 client_too_old` |
| `rate_limit.enabled` | `true` | Login, pairing redeem and setup rate limits |
| `media.ffmpeg_path`, `media.ffprobe_path` | found on `PATH` | ffmpeg tools (see below) |
| `media.workers`, `jobs.workers` | half the CPUs, `2` | Background workers |
| `log.level`, `log.format` | `info`, `text` on a terminal or `json` otherwise | Logs go to stderr |

Example `config.toml`:

```toml
library_dir = "D:/Photos/PicTunnel"

[server]
https_addr = ":8443"
public_urls = ["https://photos.example.org"]

[discovery]
mdns = true
```

## First run: creating the admin

On the first start the database has no user. The server then prints a
one-time setup token to stdout and logs it at `WARN`:

```
PicTunnel dev listening on https://:8443 (local http://127.0.0.1:8080)
First-run setup: open http://127.0.0.1:8080 on this machine to create the admin account.
From another machine, send the header PicTunnel-Setup-Token: 1P0Lq…
(the token changes on every start until setup is done)
```

- **On the server machine,** `POST /api/v1/auth/setup` to the loopback
  listener needs no token. This is the path the first-run page and the future
  tray app use.
- **From another machine,** the same request over HTTPS must carry
  `PicTunnel-Setup-Token: <token>`. Without it, or with a wrong one, the
  response is `403 forbidden`. This guards against a LAN neighbour claiming a
  fresh server first (sync-protocol §6.3).

The token is replaced on every start until an account exists. After that, no
token is printed and setup answers `409 setup_already_done`.

### The loopback listener

`server.local_addr` (default `127.0.0.1:8080`) serves the full API over plain
HTTP, but only to this machine:

- The server refuses to start if the address is not a loopback address.
- A request whose peer is not a loopback IP gets `403 forbidden`.
- A request whose `Host` header is not `localhost`, `127.0.0.1` or `[::1]`
  (any port) gets `403 forbidden`. This blocks DNS rebinding: a web page on
  another site that resolves its name to 127.0.0.1 cannot reach the
  token-less setup or the session cookie.

Session cookies set on this listener are not `Secure`, because it is plain
HTTP. Everything else, including every device, uses HTTPS.

## TLS, the fingerprint and pinning

With the default `tls.mode=self-signed`, the first start creates:

| File | What |
|---|---|
| `<data>/tls/ca.crt`, `ca.key` | Local CA, ECDSA P-256, valid 10 years, named `PicTunnel Local CA <server_id[:8]>` |
| `<data>/tls/server.crt`, `server.key` | Leaf certificate signed by the CA, valid 825 days |

The leaf covers `localhost`, the host name, `<hostname>.local`, every
non-loopback interface IP, `127.0.0.1` and `::1`. At each start, the leaf is
renewed if it expires within 30 days or if an interface IP is missing from it.
The leaf **key is never replaced**, so the pin stays the same across renewals.

At every start the server prints the pin:

```
Server 01a148c7-…, certificate pin eg9IooIm8C08g9Mkc_WzsuVCupRAPoTEnrl5PUe3KEQ
```

The pin (`fp`) is the base64url SHA-256 of the leaf's SubjectPublicKeyInfo.
Pairing QR codes carry it (`pictunnel://pair?…&fp=…`). An app accepts the
certificate when it validates against the system trust store, or else when
its SPKI hash equals `fp` (sync-protocol §6.3). For manual setup without a
QR code, the app shows the first 16 characters for you to compare with the
server.

Other ways to handle TLS:

- **Browsers and tools** can trust `<data>/tls/ca.crt`. For Node, use
  `NODE_EXTRA_CA_CERTS=<data>/tls/ca.crt`. For curl, use `--cacert`.
- **Your own certificate:** set `tls.mode=files`, `tls.cert_file` and
  `tls.key_file`. The pin is then computed from that certificate.
- **Behind a TLS-terminating proxy:** `tls.mode=off` serves plain HTTP on
  `server.https_addr` and logs a warning at every start. Only use it when the
  proxy is the sole way in.

If `ca.crt` or `ca.key` is lost or unreadable, the CA is regenerated and an
error is logged. Devices that installed the old CA must trust the new one.
The pairing pin is unchanged, because the leaf key is kept.

## LAN discovery (mDNS)

The server advertises `<server.name>._pictunnel._tcp.local.` on the HTTPS
port. The TXT record holds `sid=<server_id>`, `v=<version>`, `api=1` and
`fp16=<first 16 characters of the pin>`, and no secrets. It re-announces
when interfaces change and says goodbye on shutdown. Turn it off with
`--discovery.mdns=false`. If the multicast port cannot be bound, the server
logs a warning and keeps running; it is never fatal.

| Environment | What to do |
|---|---|
| Windows | Allow **inbound UDP 5353** in Windows Defender Firewall for `pictunnel.exe` (the tray installer will add this rule later). Without it, phones cannot discover the server; pairing by QR code or URL still works. |
| Docker (bridge network) | mDNS does not cross the bridge. On Linux run with `--network host`, or pair by QR code / manual URL. |
| macOS | Works alongside mDNSResponder, which shares port 5353. |
| Other Linux | Needs inbound UDP 5353 if a firewall is active. |

The server logs a one-line hint for the detected environment when it starts
advertising.

## ffmpeg

Uploads, sync and downloads work without ffmpeg. Media processing needs it:

| Feature | Without ffmpeg |
|---|---|
| Thumbnails of JPEG, PNG, GIF, WebP | Made in Go; no ffmpeg needed |
| Thumbnails of HEIC, AVIF, TIFF, RAW and video frames | `thumbnail` and `preview` answer `404 not_ready` |
| Video metadata (duration, codec, size) and the playability check | Not extracted; `playback` answers `404 not_ready` |
| Transcoding non-browser-playable video (for example HEVC) to H.264 `web.mp4` | Not done |

Media jobs that need ffmpeg are retried with backoff, so installing ffmpeg
later fills the gaps without re-uploading. ffmpeg and ffprobe are found on
`PATH`, or set `media.ffmpeg_path` and `media.ffprobe_path`.

- Windows: `winget install Gyan.FFmpeg`
- macOS: `brew install ffmpeg`
- Debian or Ubuntu: `sudo apt-get install ffmpeg`

## The data directory

```
<data_dir>/
  config.toml            optional settings (see Configuration)
  pictunnel.db           SQLite database (WAL mode: also -wal and -shm files)
  pictunnel.lock         exclusive lock held while a server or reset-password runs
  secret.key             32-byte server secret (token derivation); back it up with the database
  tls/                   ca.crt, ca.key, server.crt, server.key (0600)
  uploads/               staging: <upload_id>.part for uploads in progress
  derived/<id[0:2]>/<id[2:4]>/<asset_id>/
                         thumb.jpg (320 px), preview.jpg (1600 px), web.mp4 (transcode)
  backups/               pictunnel-YYYYMMDD.db daily (newest 7 kept);
                         pre-migrate-<time>.db before every schema migration
  library/               default library_dir: <user>/YYYY/MM/<file>
    .pictunnel-tmp/      in-flight copies when staging and library are on different volumes
```

Notes:

- **Staging (`uploads/`).** An upload session expires 24 hours after its last
  activity. The expiry job deletes its `.part` file every 15 minutes. At
  boot, staging files without a session are removed.
- **`.pictunnel-tmp/`.** This lives on the library volume. When the library is
  on another volume, finalize copies the file there and then renames it into
  place. A crash can leave a partial copy there; boot recovery cleans it up. User
  folder names never start with a dot, so this folder never clashes with the
  library.
- **Backups.** `backup_database` runs daily with `VACUUM INTO` through a
  temporary file, so a crash never leaves a half-written backup under the
  final name. Copy `backups/` together with `secret.key` and `tls/` to keep a
  restorable server. The library itself is plain files; back it up with any
  file-level tool.
- Only one process may use a data dir. A second `serve` fails because the
  lock is held.
