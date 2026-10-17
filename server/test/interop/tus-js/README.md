# tus-js-client interop test

Checks that PicTunnel's own tus handler works with the reference client,
[`tus-js-client`](https://github.com/tus/tus-js-client) (pinned to an exact
version in `package.json`, locked by `pnpm-lock.yaml`). Spec: server-core
design S§11.6.

## What it does

1. Builds `./cmd/pictunnel` and starts `pictunnel serve` with a temporary
   `--data-dir`, HTTPS on `127.0.0.1:18443`, the loopback listener on
   `127.0.0.1:18080` and mDNS off. It waits for the setup-token line on stdout.
2. Re-runs itself with `NODE_EXTRA_CA_CERTS=<data>/tls/ca.crt`, so Node trusts
   the server's self-signed certificate.
3. Creates the admin over the loopback listener, logs in over HTTPS, creates a
   pairing code and redeems it; the paired device's bearer token is used from
   here on.
4. Uploads payload C (P§10.1: 3 MiB, byte *i* = *i* mod 256) with
   `chunkSize: 1048576` and aborts after the second `onChunkComplete`.
5. Starts a new `Upload`, finds the stored URL with `findPreviousUploads`,
   calls `resumeFromPreviousUpload` and finishes. It asserts that the resume
   HEAD reported offset 2 MiB and that the last PATCH carried
   `PicTunnel-Asset-Id`.
6. `POST /api/v1/sync/check` must answer `exists` with that asset id.

The script exits non-zero on any failure, prints the server output, and always
stops the server and removes the temp dir (`INTEROP_KEEP=1` keeps it).

## Running

Needs Go and Node 24 with pnpm.

```sh
cd server/test/interop/tus-js
pnpm install --frozen-lockfile
node upload.mjs
```

or `task test:interop` from the repository root. Change the ports with
`INTEROP_HTTPS_PORT` and `INTEROP_LOCAL_PORT` if 18443 or 18080 is taken.
