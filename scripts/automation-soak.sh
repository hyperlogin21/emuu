#!/bin/bash
# Drives an Emuu instance over plain adb the way a test runner does (install, launch, taps/swipes,
# uiautomator dump, screencap, logcat), with an idle pause in the middle, and records whether any command
# failed and whether the engine was ever frozen/hibernated (from the supervisor's status file).
#
#   scripts/automation-soak.sh <serial> <apk> <seconds-busy-1> <seconds-idle> <seconds-busy-2> [instance]
# Exit status: 0 when every adb command succeeded and the engine stayed running.
set -u
SERIAL="$1"; APK="$2"; BUSY1="$3"; IDLE="$4"; BUSY2="$5"; INST="${6:-}"
STATUS="${EMUU_HOME:-$HOME/.emuu}/run/${INST}.supervisor.json"
PKG="${PKG:-org.billthefarmer.editor}"
ok=0; fail=0; notrunning=0; iter=0; aborted=0
states=""
adbc() {   # every command gets a timeout: a frozen engine makes adb hang
  (( aborted )) && return
  if timeout "${ADB_TIMEOUT:-30}" adb -s "$SERIAL" "$@" >/dev/null 2>&1; then
    ok=$((ok+1))
  else
    fail=$((fail+1)); echo "  $(date '+%H:%M:%S') FAIL: adb $* (engine: $(engine_state))"
    # The engine was frozen/hibernated under us: every further command would hang too.
    local s; s="$(engine_state)"; [[ -n "$s" && "$s" != "running" ]] && { aborted=1; echo "  engine is $s — stopping this busy phase"; }
  fi
}
engine_state() {
  [[ -n "$INST" && -f "$STATUS" ]] && sed -n 's/.*"engineState" *: *"\([a-z]*\)".*/\1/p' "$STATUS" | head -1
}
check_state() {
  local s; s="$(engine_state)"
  [[ -n "$s" && "$s" != "running" ]] && notrunning=$((notrunning+1))
  [[ "$states" == *"$s"* ]] || states="$states $s"
}
busy() {
  local until=$(( $(date +%s) + $1 ))
  aborted=0
  while (( $(date +%s) < until && ! aborted )); do
    iter=$((iter+1))
    adbc install -r "$APK"
    adbc shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1
    adbc shell input tap 360 800
    adbc shell input swipe 360 1200 360 400 200
    adbc shell input swipe 360 400 360 1200 200
    adbc shell input keyevent 4
    adbc shell uiautomator dump /sdcard/emuu-soak.xml
    adbc exec-out screencap -p
    adbc logcat -d -t 50
    adbc shell input keyevent 3
    check_state
  done
}
idle() {   # no adb traffic at all (a runner waiting between suites); watch the engine state only
  local until=$(( $(date +%s) + $1 ))
  while (( $(date +%s) < until )); do check_state; sleep 5; done
}
t0=$(date +%s)
echo "$(date '+%H:%M:%S') busy ${BUSY1}s"; busy "$BUSY1"
echo "$(date '+%H:%M:%S') idle ${IDLE}s (no adb commands)"; idle "$IDLE"
echo "$(date '+%H:%M:%S') busy ${BUSY2}s"; busy "$BUSY2"
adbc uninstall "$PKG"
echo "$(date '+%H:%M:%S') done in $(( $(date +%s) - t0 ))s: iterations=$iter ok=$ok failed=$fail engine-not-running-observations=$notrunning engine-states-seen:${states}"
(( fail == 0 && notrunning == 0 ))
