#!/usr/bin/env bash
# Instrumented engine tests on a booted emulator or device (API 34+), run by ci-mobile's
# engine-android-instrumented job and by `task test:engine:android:instrumented`.
#
#   1. :engine:connectedDebugAndroidTest with full media access. PartialAccessInstrumentedTest
#      skips itself here.
#   2. PartialAccessInstrumentedTest on its own. Revoking a permission kills the process, so the
#      permissions are set with pm before `am instrument` starts it (Task 9).
#   3. A smoke launch of the debug app (mobile/build/app/outputs/flutter-apk/app-debug.apk, built
#      beforehand): MainActivity registers the real EngineHost, the Flutter UI calls it at start-up,
#      and the run fails on a crash or a bridge error in logcat.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$root/.cache/instrumented"
mkdir -p "$out"

test_pkg=io.github.prithvirajg.pictunnel.engine.test
runner="$test_pkg/androidx.test.runner.AndroidJUnitRunner"
app_pkg=io.github.prithvirajg.pictunnel
apk="$root/mobile/build/app/outputs/flutter-apk/app-debug.apk"

cd "$root/mobile/android"

echo "::group::connectedDebugAndroidTest"
./gradlew :engine:connectedDebugAndroidTest --no-daemon
echo "::endgroup::"

echo "::group::partial media access"
./gradlew :engine:installDebugAndroidTest --no-daemon
adb shell pm revoke "$test_pkg" android.permission.READ_MEDIA_IMAGES || true
adb shell pm revoke "$test_pkg" android.permission.READ_MEDIA_VIDEO || true
adb shell pm grant "$test_pkg" android.permission.READ_MEDIA_VISUAL_USER_SELECTED
adb shell am instrument -r -w \
  -e class io.github.prithvirajg.pictunnel.engine.PartialAccessInstrumentedTest "$runner" \
  | tr -d '\r' | tee "$out/partial-access.txt"
adb uninstall "$test_pkg" || true
echo "::endgroup::"
# Status codes: 0 passed, -1 error, -2 failure, -3 ignored, -4 assumption failed (skipped).
if grep -Eq '^INSTRUMENTATION_STATUS_CODE: -[1-4]$|^INSTRUMENTATION_RESULT: shortMsg|^INSTRUMENTATION_FAILED' "$out/partial-access.txt" \
  || ! grep -q '^INSTRUMENTATION_STATUS_CODE: 0$' "$out/partial-access.txt"; then
  echo "::error::PartialAccessInstrumentedTest did not pass (see partial-access.txt)"
  exit 1
fi

echo "::group::bridge smoke launch"
adb install -r -g "$apk"
adb logcat -c
adb shell am start -W -n "$app_pkg/.MainActivity"
sleep 30
adb logcat -d > "$out/smoke-logcat.txt"
adb shell dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity' | tee "$out/smoke-activity.txt" || true
echo "::endgroup::"
if ! adb shell pidof "$app_pkg" > /dev/null; then
  echo "::error::the app is not running 30 s after launch (see smoke-logcat.txt)"
  exit 1
fi
if ! grep -q "$app_pkg/.MainActivity" "$out/smoke-activity.txt"; then
  echo "::error::MainActivity is not the resumed activity"
  exit 1
fi
if grep -E "FATAL EXCEPTION|channel-error|MissingPluginException|Unhandled Exception" "$out/smoke-logcat.txt"; then
  echo "::error::crash or bridge error in logcat during the smoke launch"
  exit 1
fi
echo "bridge smoke launch OK"
