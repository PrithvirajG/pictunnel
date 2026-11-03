#!/usr/bin/env bash
# The first real backup end to end, on a booted API 34+ emulator (ci-mobile's android-e2e job,
# or `task test:e2e:android` with a local emulator):
#
#   1. Starts `pictunnel serve` (built from this checkout, .cache/pictunnel) on the host. Its
#      HTTPS listener is bound to 127.0.0.1, so the LAN addresses in the pairing QR code refuse
#      and the engine must fall back to https://10.0.2.2:8443, the emulator's alias for the
#      host's loopback (the same fallback a phone makes past a Docker container's own IP).
#   2. Creates the admin and a pairing code with `pictunnel pair --create --uri-only`.
#   3. Pushes a JPEG with EXIF date and GPS into MediaStore (adb push + media scan).
#   4. Installs the engine test APK with every runtime permission and instruments
#      RealServerBackupInstrumentedTest: pairing through the real EngineHost, start, Back up now,
#      until the item is BackedUp.
#   5. Checks through the server API that the asset exists with the file's SHA-256, size, name,
#      EXIF date and location, that its original downloads byte for byte, that the library file
#      is identical, that a thumbnail is served, and that the emulator is a paired device.
#
# Needs: .cache/pictunnel, the engine test APK (:engine:assembleDebugAndroidTest), adb, curl, jq.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$root/.cache/e2e"
rm -rf "$out"
mkdir -p "$out"

bin="$root/.cache/pictunnel"
apk="$root/mobile/android/engine/build/outputs/apk/androidTest/debug/engine-debug-androidTest.apk"
jpeg="$root/server/internal/media/testdata/exif_rot6.jpg"
test_pkg=io.github.prithvirajg.pictunnel.engine.test
runner="$test_pkg/androidx.test.runner.AndroidJUnitRunner"
local_url=http://127.0.0.1:8080

fail() {
  echo "::error::$*"
  exit 1
}

data="$(mktemp -d)"
sha="$(sha256sum "$jpeg" | cut -d' ' -f1)"
size="$(stat -c %s "$jpeg")"
name="pt-e2e-$(date +%s).jpg"
echo "test photo $name: $size bytes, sha256 $sha"

echo "::group::start the server"
"$bin" serve --data-dir "$data" \
  --server.https-addr 127.0.0.1:8443 \
  --server.public-urls https://10.0.2.2:8443 \
  --discovery.mdns=false --log.format text --log.level debug \
  > "$out/server.log" 2>&1 &
server_pid=$!
cleanup() {
  kill "$server_pid" 2> /dev/null || true
  wait "$server_pid" 2> /dev/null || true
  adb logcat -d > "$out/logcat.txt" 2> /dev/null || true
}
trap cleanup EXIT
for _ in $(seq 1 60); do
  curl -sf "$local_url/healthz" > /dev/null && break
  kill -0 "$server_pid" 2> /dev/null || { cat "$out/server.log"; fail "the server exited"; }
  sleep 1
done
curl -sf "$local_url/healthz" > /dev/null || fail "the server did not become healthy"
grep -E 'certificate pin|listening' "$out/server.log" || true
echo "::endgroup::"

echo "::group::admin and pairing code"
password="e2e-$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
qr="$("$bin" pair --url "$local_url" --create --password "$password" --uri-only)"
echo "$qr" | sed -E 's/code=[^&]+/code=<redacted>/'
case "$qr" in
  pictunnel://pair\?*u=https%3A%2F%2F10.0.2.2%3A8443*) ;;
  *) fail "the pairing link has no 10.0.2.2 endpoint: $qr" ;;
esac
echo "::endgroup::"

echo "::group::push the photo into MediaStore"
adb shell mkdir -p /sdcard/Pictures
adb push "$jpeg" "/sdcard/Pictures/$name"
adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file:///sdcard/Pictures/$name" > /dev/null
indexed=""
for _ in $(seq 1 30); do
  adb shell content query --uri content://media/external/images/media --projection _id:_display_name:_size \
    | tr -d '\r' > "$out/mediastore.txt" || true
  if grep -q "_display_name=$name," "$out/mediastore.txt"; then
    indexed=yes
    break
  fi
  sleep 1
done
[ -n "$indexed" ] || fail "MediaStore did not index $name"
grep "$name" "$out/mediastore.txt"
echo "::endgroup::"

echo "::group::pair and back up (RealServerBackupInstrumentedTest)"
adb install -r -t -g "$apk"
adb logcat -c
adb shell "am instrument -r -w -e class io.github.prithvirajg.pictunnel.engine.RealServerBackupInstrumentedTest -e qrUri '$qr' -e sha256 $sha $runner" \
  | tr -d '\r' | tee "$out/instrument.txt"
echo "::endgroup::"
# Status codes: 0 passed, -1 error, -2 failure, -3 ignored, -4 assumption failed (skipped).
if grep -Eq '^INSTRUMENTATION_STATUS_CODE: -[1-4]$|^INSTRUMENTATION_RESULT: shortMsg|^INSTRUMENTATION_FAILED' "$out/instrument.txt" \
  || ! grep -q '^INSTRUMENTATION_STATUS_CODE: 0$' "$out/instrument.txt"; then
  fail "RealServerBackupInstrumentedTest did not pass (see instrument.txt, logcat.txt and server.log)"
fi

echo "::group::check the server"
jar="$out/cookies.txt"
login="$(jq -nc --arg p "$password" '{username: "admin", password: $p, mode: "cookie"}')"
curl -sf -c "$jar" -H 'Content-Type: application/json' -d "$login" "$local_url/api/v1/auth/login" > /dev/null \
  || fail "admin login failed"
api() { curl -sf -b "$jar" "$local_url$1"; }

api "/api/v1/sync/snapshot?limit=500" > "$out/snapshot.json" || fail "snapshot failed"
matches="$(jq --arg s "$sha" '[.assets[] | select(.sha256 == $s)] | length' "$out/snapshot.json")"
[ "$matches" = 1 ] || fail "expected one asset with sha256 $sha, found $matches (see snapshot.json)"
asset="$(jq -c --arg s "$sha" '.assets[] | select(.sha256 == $s)' "$out/snapshot.json")"
echo "$asset" | jq .
check() { # <jq filter that must be true> <message>
  echo "$asset" | jq -e "$1" > /dev/null || fail "asset: $2 (got $asset)"
}
check '.state == "active"' "state is not active"
check ".size_bytes == $size" "size is not $size"
check '.mime == "image/jpeg" and .kind == "photo"' "not a JPEG photo"
check ".filename == \"$name\"" "filename is not $name"
check '.taken_at_source == "exif" and (.taken_at | startswith("2024-05-06T"))' "taken_at is not the EXIF date"
# The GPS tag survives only when the original bytes (ACCESS_MEDIA_LOCATION) were uploaded.
check '(.lat - 38.7223 | fabs) < 0.001 and (.lon + 9.1393 | fabs) < 0.001' "the EXIF location is missing"
id="$(echo "$asset" | jq -r .id)"

api "/api/v1/assets/$id/original" > "$out/original.jpg" || fail "original download failed"
[ "$(sha256sum "$out/original.jpg" | cut -d' ' -f1)" = "$sha" ] || fail "the downloaded original differs from the pushed file"
lib="$(find "$data/library" -type f -name "$name")"
[ -n "$lib" ] || fail "no $name in the library ($data/library)"
cmp "$lib" "$jpeg" || fail "the library file differs from the pushed file"
echo "library file: ${lib#"$data"/}"

thumb=""
for _ in $(seq 1 60); do
  if api "/api/v1/assets/$id/thumbnail" > "$out/thumb.jpg" 2> /dev/null && [ -s "$out/thumb.jpg" ]; then
    thumb=yes
    break
  fi
  sleep 1
done
[ -n "$thumb" ] || fail "no thumbnail for the asset within 60 s"

api "/api/v1/devices" > "$out/devices.json" || fail "device list failed"
jq -e '[.devices[] | select(.name == "CI emulator" and .platform == "android")] | length == 1' "$out/devices.json" > /dev/null \
  || fail "the emulator is not a paired android device (see devices.json)"
echo "::endgroup::"
echo "android e2e OK: $name backed up as asset $id with sha256 $sha"
