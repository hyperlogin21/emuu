#!/bin/bash
# Plays each test scenario on a running instance and runs `emuu debug display-probe` on it.
# Docs: "Diagnosing display artefacts" in docs/ARCHITECTURE.md. Setup (once per instance):
#   scripts/flicker-test/apk/build.sh && adb -s <serial> install -r scripts/flicker-test/apk/build/emuu-flickertest.apk
#   swiftc -O scripts/flicker-test/make-pattern-video.swift -o /tmp/mkvid
#   /tmp/mkvid 1080 1920 60 17 p1080x60.mp4   (also: p1080x30, p720x60 at 720 1280, p720x30, l1080x60 at 1920 1080 60,
#                                              n1080x30/n1080x60 with a trailing "noise"; h*/v* = ffmpeg re-encodes to HEVC/VP9,
#                                              e.g. ffmpeg -i p720x30.mp4 -c:v libx265 -tag:v hvc1 -crf 22 h720x30.mp4)
#   adb -s <serial> push *.mp4 /sdcard/Android/data/dev.emuu.flickertest/files/
#   scripts/flicker-test/run-scenarios.sh <instance> <adb-serial> <seconds> [extra probe args…]
# Example: scripts/flicker-test/run-scenarios.sh flick emulator-5570 30 --no-validate --compare-inline
# TikTok-like decoder scenarios (CodecActivity, needs h720x30/p720x30/h1080x30/p1080x30):
#   SCENARIOS="feed-swipe feed-flushloop feed-placeholder feed-preload feed-gl" scripts/flicker-test/run-scenarios.sh …
# Which decoder the guest uses: `emuu video-decoder status <instance>`.
set -uo pipefail
INST=$1; SERIAL=$2; SECS=$3; shift 3
EMUU="${EMUU:-$(dirname "$0")/../../.build/release/emuu}"
PKG=dev.emuu.flickertest
a() { adb -s "$SERIAL" "$@"; }
run() {
  local name=$1; shift
  a shell am force-stop $PKG
  a shell am start -W "$@" >/dev/null
  sleep 3
  echo "=== $name"
  "$EMUU" debug display-probe "$INST" --duration "$SECS" "${PROBE_ARGS[@]}" 2>/dev/null
}
PROBE_ARGS=("$@")
SCEN="${SCENARIOS:-surface1080x60 texture1080x60 surface1080x30-feed texture720x60-feed gl60 surface-landscape1080x60}"
for s in $SCEN; do
  case $s in
    surface1080x60) run "$s" -n $PKG/.VideoActivity --es file p1080x60.mp4 --es mode surface ;;
    texture1080x60) run "$s" -n $PKG/.VideoActivity --es file p1080x60.mp4 --es mode texture ;;
    surface1080x30-feed) run "$s" -n $PKG/.VideoActivity --es file p1080x30.mp4 --es mode surface --ef scale 0.6 ;;
    texture720x60-feed) run "$s" -n $PKG/.VideoActivity --es file p720x60.mp4 --es mode texture --ef scale 0.6 ;;
    surface720x30) run "$s" -n $PKG/.VideoActivity --es file p720x30.mp4 --es mode surface ;;
    hevc-surface1080x60) run "$s" -n $PKG/.VideoActivity --es file h1080x60.mp4 --es mode surface ;;
    hevc-texture1080x30) run "$s" -n $PKG/.VideoActivity --es file h1080x30.mp4 --es mode texture ;;
    vp9-surface1080x60) run "$s" -n $PKG/.VideoActivity --es file v1080x60.webm --es mode surface ;;
    noisy-surface1080x30) run "$s" -n $PKG/.VideoActivity --es file n1080x30.mp4 --es mode surface ;;
    noisy-surface1080x60) run "$s" -n $PKG/.VideoActivity --es file n1080x60.mp4 --es mode surface ;;
    noisy-texture1080x60) run "$s" -n $PKG/.VideoActivity --es file n1080x60.mp4 --es mode texture ;;
    noisy-hevc-surface1080x30) run "$s" -n $PKG/.VideoActivity --es file nh1080x30.mp4 --es mode surface ;;
    gl60) run "$s" -n $PKG/.GLActivity ;;
    feed-swipe) run "$s" -n $PKG/.CodecActivity --es files h1080x30.mp4,p720x30.mp4,h720x30.mp4,p1080x30.mp4 --ei swipe 2 ;;
    feed-flushloop) run "$s" -n $PKG/.CodecActivity --es files h1080x30.mp4 --ei loopAfter 30 ;;
    feed-placeholder) run "$s" -n $PKG/.CodecActivity --es files h720x30.mp4,p720x30.mp4 --ei swipe 3 --ei placeholder 300 ;;
    feed-preload) run "$s" -n $PKG/.CodecActivity --es files h720x30.mp4,p1080x30.mp4,h1080x30.mp4,p720x30.mp4 --ei preload 4 ;;
    feed-gl) run "$s" -n $PKG/.CodecActivity --es out gl --es files h1080x30.mp4 ;;
    gl-upload) run "$s" -n $PKG/.GLActivity --ez upload true ;;
    surface-landscape1080x60) run "$s" -n $PKG/.VideoActivity --es file l1080x60.mp4 --es mode surface ;;
    *) echo "unknown scenario $s" ;;
  esac
done
a shell am force-stop $PKG
