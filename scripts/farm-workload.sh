#!/bin/bash
# One device's scripted adb test loop, the way a UI test runner drives a device: install, launch, taps and
# swipes, uiautomator dump, screencap, logcat, Settings, uninstall. Every command has a timeout.
#
#   scripts/farm-workload.sh <serial> <seconds> [apk] [package/activity]
#
# Prints one summary line at the end:
#   <serial> iterations=N ok=N failed=N secs=N iter_per_min=X boot_id_changes=N aborted=0|1
# (aborted=1: two commands in a row failed, so the device is treated as gone and the run stops early)
# and a FAIL line (with time) for every failed command. Exit 0 when nothing failed.
# Used by scripts/farm-soak.sh and the farm profile benchmarks (docs/BENCHMARKS.md, "Farm").
# Needs `timeout` (GNU coreutils: `brew install coreutils`) and adb on PATH (or ADB=<path>).
set -u
SERIAL="$1"; SECS="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
APK="${3:-$HERE/secure-test-apk/build/emuu-securetest.apk}"
ACT="${4:-dev.emuu.securetest/.SecureActivity}"
PKG="${ACT%%/*}"
ADB="${ADB:-adb}"
T="${ADB_TIMEOUT:-60}"
ok=0; fail=0; iter=0; bootchanges=0; streak=0; aborted=0
adbc() {
  (( aborted )) && return 1
  if timeout "$T" "$ADB" -s "$SERIAL" "$@" >/dev/null 2>&1; then ok=$((ok+1)); streak=0; return 0; fi
  fail=$((fail+1)); streak=$((streak+1)); echo "  $(date '+%H:%M:%S') $SERIAL FAIL: adb $*"
  # ABORT_AFTER failures in a row (default 2; 0 = never): the device is gone or hung; stop this run instead of
  # timing out on every command. farm-soak.sh relies on it; benchmarks set ABORT_AFTER=0.
  if (( ${ABORT_AFTER:-2} > 0 && streak >= ${ABORT_AFTER:-2} )); then aborted=1; echo "  $(date '+%H:%M:%S') $SERIAL aborting: device not answering"; fi
  return 1
}
bootid() { timeout 10 "$ADB" -s "$SERIAL" shell cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r'; }
b0="$(bootid)"
t0=$(date +%s); until=$(( t0 + SECS ))
while (( $(date +%s) < until && ! aborted )); do
  iter=$((iter+1))
  adbc install -r -g "$APK"
  adbc shell am start -W -n "$ACT"
  adbc shell input tap 360 800
  adbc shell input swipe 360 1200 360 400 150
  adbc shell uiautomator dump /sdcard/emuu-ui.xml
  adbc exec-out screencap -p
  adbc shell am start -W -a android.settings.SETTINGS
  adbc shell input swipe 360 1200 360 400 150
  adbc shell input swipe 360 400 360 1200 150
  adbc shell input keyevent 4
  adbc logcat -d -t 100
  adbc shell input keyevent 3
  adbc uninstall "$PKG"
  b="$(bootid)"
  if [[ -n "$b" && -n "$b0" && "$b" != "$b0" ]]; then
    bootchanges=$((bootchanges+1)); echo "  $(date '+%H:%M:%S') $SERIAL guest boot_id changed ($b0 -> $b)"; b0="$b"
  fi
done
secs=$(( $(date +%s) - t0 ))
ipm=$(awk -v i="$iter" -v s="$secs" 'BEGIN { printf "%.1f", (s > 0 ? i * 60 / s : 0) }')
echo "$SERIAL iterations=$iter ok=$ok failed=$fail secs=$secs iter_per_min=$ipm boot_id_changes=$bootchanges aborted=$aborted"
(( fail == 0 ))
