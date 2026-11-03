# Android prototype quickstart

This page gets PicTunnel running on your own network: the server in Docker on your
Windows PC, and the Android app on your phone backing up photos to it. The iPhone app
is parked for now. Plan for about 15 minutes.

You need:

- Docker Desktop and [Task](https://taskfile.dev) on the PC, plus Node (for `task proto:up`).
- An Android 10+ phone on the **same Wi-Fi** as the PC.
- To install the APK over USB: `adb`, from `winget install Google.PlatformTools`.

## 1. Start the server

From the repository root:

```powershell
task proto:up
```

This builds the server image, starts it in the background as the Compose project
`pictunnel-proto`, and prints the address phones will use, for example
`https://192.168.1.20:8443`. That address is your PC's LAN IP; Task finds it for you and
skips virtual adapters such as WSL, Hyper-V and Docker.

If Task picks the wrong address (for example Ethernet when the phone is on Wi-Fi), look
it up with `ipconfig` under your Wi-Fi adapter's **IPv4 Address** and pass it in:

```powershell
task proto:up LAN_IP=192.168.1.20
```

Your photos, accounts and keys live in the Docker volume `pictunnel-proto_pictunnel-data`.
`task proto:down` stops the server and keeps the volume. `task proto:logs` follows the logs.

## 2. Create the admin and a pairing code

```powershell
task proto:pair
```

The first time, this creates the account `admin` and prints its password **once**. Save it.
Then it shows:

- a QR code, also saved as `deploy/pairing-qr.png` (open that file if the terminal QR looks
  garbled, which happens in consoles that are not UTF-8);
- the pairing code, which can be used once and expires after 10 minutes;
- the security code, the first 16 characters of the server's certificate pin.

To pair another phone later, or when a code has expired, run it again with the password:

```powershell
task proto:pair -- --password <your admin password>
```

Forgot the password? `task proto:reset-password` prints a new one. It also signs out every
paired phone, so pair them again afterwards.

## 3. Install the app

Use the debug APK. It is signed with the Android debug key, so you can sideload it.

**From CI.** Every push to `feat/**` builds the APK. Download it from the latest green
[ci-mobile run](https://github.com/PrithvirajG/pictunnel/actions/workflows/ci-mobile.yml):
open the run, go to **Artifacts**, and get `pictunnel-android-debug-apk` (a zip containing
`app-debug.apk`). With the GitHub CLI:

```powershell
gh run list --workflow ci-mobile --branch feat/mobile-app --status success --limit 1
gh run download <run id> --name pictunnel-android-debug-apk --dir apk
```

There is also `pictunnel-android-release-apk` (`app-release.apk`). It is still signed with
the debug key, but it is minified and faster.

**Or build it yourself** (no local Flutter needed):

```powershell
docker run --rm -m 5g -v "${PWD}:/repo" -w /repo/mobile ghcr.io/cirruslabs/flutter:3.44.0 flutter build apk --debug
# -> mobile/build/app/outputs/flutter-apk/app-debug.apk
```

**Install it.** On the phone, turn on Developer options (tap *Build number* 7 times) and then
*USB debugging*. Plug the phone in, accept the prompt, then run:

```powershell
adb install -r apk\app-debug.apk
```

You can also copy the APK to the phone and open it in Files, allowing "Install unknown apps"
when Android asks.

## 4. Pair the phone

1. Open **PicTunnel**. On *Pair with your server*, allow camera access and point the
   camera at the QR code (the terminal one or `deploy/pairing-qr.png`).
2. The app shows *Server found*. Tap **Connect and start backup**.
3. Allow photo and video access with **Allow all**. With *Select photos*, only the photos you
   pick are backed up. Allow notifications as well, so the upload progress shows.

No camera, or the QR code will not scan? Tap **Enter a server address instead**. Type
`https://<LAN IP>:8443`, check that the security code matches the one `task proto:pair`
printed, then enter the pairing code.

## 5. Watch the first photos back up

- The **Backup** tab counts items while they are hashed, queued and uploaded. Pull down to
  refresh, or open *Activity* to see each step.
- The **Photos** tab shows what is on the server next to what is on the phone. Backed-up
  photos get their server thumbnails.
- On the PC, `task proto:logs` shows each upload (`POST /api/v1/uploads`). To list the files:

  ```powershell
  $env:PICTUNNEL_LAN_IP="0.0.0.0"; docker compose -f deploy/docker-compose.yml exec pictunnel ls -R /data/library
  ```

  To copy the library out of the volume, use `docker compose ... cp pictunnel:/data/library .\library`.

New photos are picked up automatically: on MediaStore changes, every 6 hours, and when you
open the app.

## Troubleshooting

**The phone cannot reach the server** ("Can't reach your server", or pairing hangs). Work
through these in order:

1. Open `https://<LAN IP>:8443/healthz` in the phone's browser. After the certificate
   warning (expected, the certificate is self-signed) it should say `ok`.
2. Check the **Windows firewall.** Docker Desktop asks to allow *Docker Desktop Backend* the
   first time a port is published; allow it on private networks. If your Wi-Fi is set to
   *Public* in Windows (Settings > Network & internet > Wi-Fi > your network), either switch
   it to *Private* or open the port in an admin PowerShell:

   ```powershell
   New-NetFirewallRule -DisplayName "PicTunnel 8443" -Direction Inbound -Protocol TCP -LocalPort 8443 -Action Allow -Profile Private,Public
   ```

3. Check the network: both devices must be on the same Wi-Fi. Guest networks and some
   mesh or router setups ("AP/client isolation") block traffic between devices.
4. Check that the PC's IP has not changed. The pairing QR code stores the address. If DHCP
   gave the PC a new IP, run `task proto:up` again, then on the phone use Settings > Server >
   **Pair again** with a new `task proto:pair` code. A DHCP reservation in your router
   avoids this.

Each new connection may take about 3 seconds. The QR code also lists the container's
internal Docker address, which phones cannot reach, so the app tries it first and then
falls back to your LAN IP. That is expected.

**"Your server's security certificate changed".** The app pins the server's certificate
key from the QR code. Restarts and certificate renewals keep the key, so the pin stays the
same. Only a new data volume (`task proto:wipe`, or deleting the volume) creates a new key.
After that, use Settings > Server > **Pair again** with a fresh `task proto:pair` code.

**Pairing code rejected.** Codes are single-use and last 10 minutes. After 5 wrong codes, the
server cancels every open code. Run `task proto:pair -- --password …` for a new one.

**Backups wait for Wi-Fi, or never start on mobile data.** Settings > Backup > *Use mobile
data* is on by default. When it is off, backups wait for Wi-Fi. This prototype server is only
reachable on your home network anyway, so away from home the app reports it is offline and
continues when you are back. *Only while charging* also holds backups back.

**Backups only run while the app is open.** Android delays background work for
battery-optimised apps. In PicTunnel, open Settings and tap **Allow in background** on the
*Battery optimisation* card. Alternatively, go to Android Settings > Apps > PicTunnel >
Battery and choose *Unrestricted*. Some phones (Samsung, Xiaomi, OnePlus) have their own
extra "sleeping apps" lists; take PicTunnel off them.

**Some photos are missing.** If you chose *Select photos*, only the selected items are
backed up. Tap **Allow full access** on the Backup tab's banner to include the rest. Videos follow *Include videos*.
Items that failed 10 times appear under Backup > *Needs attention*, with a Retry button.

**HEIC or video thumbnails.** The image includes ffmpeg, so they work. A thumbnail can
take a few seconds after the upload.

**Start over.** `task proto:wipe` deletes the server's data volume, including every photo,
account and key. To reset the phone, uninstall the app or use Settings > Server > **Unpair this phone**.

## What CI checks

The `android-e2e` job in `ci-mobile` runs the real flow on every push: `pictunnel serve`
built from the commit, an API 34 emulator paired to it over `10.0.2.2` through the real
engine, a JPEG pushed into MediaStore and backed up, and then the asset is checked on the
server: SHA-256, size, EXIF date and location, the original bytes, the thumbnail and the
paired device. See [`tools/ci/android-e2e.sh`](../tools/ci/android-e2e.sh).
