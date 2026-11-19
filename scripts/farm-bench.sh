#!/bin/bash
# Farm profile benchmark: one candidate configuration, two devices, measured end to end.
#
#   EMUU_HOME=<scratch> scripts/farm-bench.sh <label> <guestRAM-MB> <cores> <gpu> <lean:0|1> [loop-seconds]
#
# Steps (raw engine commands, so every flag is visible in the log):
#   1. create a golden instance (emuu create) and cold-boot it; guest RAM below the engine's 2048 MB floor is
#      forced with `-qemu -m <MB>` (the engine prints "Increasing RAM size to 2048MB" and ignores -memory);
#   2. prepare it like `emuu golden seal` does (animations off, adb-install verifier off, stay awake;
#      lean=1 also disables the packages in scripts/farm-lean-packages.txt), wait until 150 s of uptime,
#      then seal it (console `kill` saves default_boot);
#   3. APFS-clone it twice (cp -c, snapshot hardware.ini rewritten), start both clones concurrently with
#      -no-snapshot-save and time each to sys.boot_completed;
#   4. run scripts/farm-workload.sh on both at once for loop-seconds (default 600), sampling engine
#      phys_footprint and host memory every 30 s;
#   5. reset device A three times with console `avd snapshot load default_boot` and time it to adb-ready;
#   6. kill both engines and delete everything it created.
# Output: a report on stdout (also used verbatim in docs/evidence/farm-bench-*.txt).
set -u
LABEL="$1"; RAM="$2"; CORES="$3"; GPU="$4"; LEAN="$5"; LOOP="${6:-600}"
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${EMUU_HOME:?set EMUU_HOME to a scratch directory}"
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
EM="$SDK/emulator/emulator"; ADB="$SDK/platform-tools/adb"
EMUU="${EMUU:-$HERE/../.build/debug/emuu}"
export ANDROID_AVD_HOME="$EMUU_HOME/avd" ANDROID_SDK_ROOT="$SDK"
G="fb-$LABEL"; PG=5576; PA=5578; PB=5580
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
# phys_footprint (Activity Monitor "Memory"; counts guest RAM twice) / real (footprint(1): dirty+compressed+swapped
# pages of the process, each page once)
fp() {
  [[ -n "${1:-}" ]] || return
  printf "%s/real %s" "$(top -l 1 -pid "$1" -stats mem 2>/dev/null | tail -1 | tr -d ' ')" \
    "$(footprint -p "$1" 2>/dev/null | sed -n 's/.*Footprint: \([0-9]* [MG]B\).*/\1/p' | head -1 | tr -d ' ')"
}
hostmem() {
  vm_stat | awk '/page size of/ {ps=$8} /Anonymous pages/ {a=$3} /Pages wired down/ {w=$4} /occupied by compressor/ {c=$5}
    END {gsub("\\.","",a);gsub("\\.","",w);gsub("\\.","",c); printf "nonfile=%dMiB compressor=%dMiB", (a+w+c)*ps/1048576, c*ps/1048576}'
  printf " swap=%s pressure=%s free=%s%%\n" "$(sysctl -n vm.swapusage | awk '{print $6}')" "$(sysctl -n kern.memorystatus_vm_pressure_level)" "$(sysctl -n kern.memorystatus_level)"
}
waitboot() { # serial timeout -> prints seconds
  local t0; t0=$(now)
  while true; do
    [[ "$(timeout 5 "$ADB" -s "$1" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] &&
      timeout 5 "$ADB" -s "$1" shell pm path android >/dev/null 2>&1 && break
    awk -v a="$(now)" -v b="$t0" -v t="$2" 'BEGIN{exit !(a-b>t)}' && { echo "timeout"; return 1; }
    sleep 0.1
  done
  awk -v a="$(now)" -v b="$t0" 'BEGIN{printf "%.2f\n", a-b}'
}
ramflags() { (( RAM < 2048 )) && echo "-qemu -m $RAM"; }
launch() { # avd port extra...
  local avd=$1 port=$2; shift 2
  "$EM" -avd "$avd" -no-window -no-boot-anim -ports "$port,$((port+1))" -gpu "$GPU" -memory 2048 -cores "$CORES" \
    -no-metrics -netfast -no-audio "$@" $(ramflags) >>"$EMUU_HOME/logs/bench-$avd.log" 2>&1 &
  echo $!
}
echo "== farm-bench $LABEL: guest ${RAM} MB, $CORES cores, gpu $GPU, lean=$LEAN, loop ${LOOP}s, $(date '+%F %T')"
echo "host before: $(hostmem)"
"$EMUU" create "$G" --preset lite --no-audio --ram 2048 --cores "$CORES" --gpu "$GPU" >/dev/null || exit 1
pg=$(launch "$G" $PG -no-snapshot-load)
echo "golden cold boot: $(waitboot emulator-$PG 300) s"
"$ADB" -s emulator-$PG shell 'settings put global window_animation_scale 0; settings put global transition_animation_scale 0;
  settings put global animator_duration_scale 0; settings put global verifier_verify_adb_installs 0; svc power stayon true' >/dev/null
if [[ "$LEAN" == 1 ]]; then
  n=0; for p in $(grep -v '^#' "$HERE/farm-lean-packages.txt"); do
    "$ADB" -s emulator-$PG shell pm disable-user --user 0 "$p" 2>/dev/null | grep -q disabled && n=$((n+1)); done
  echo "lean: disabled $n packages"
fi
while (( $("$ADB" -s emulator-$PG shell cut -d. -f1 /proc/uptime | tr -d '\r') < 150 )); do sleep 5; done
echo "golden after settle: engine $(fp $pg), guest $("$ADB" -s emulator-$PG shell grep MemAvailable /proc/meminfo | tr -s ' ')"
"$ADB" -s emulator-$PG emu kill >/dev/null 2>&1; while kill -0 $pg 2>/dev/null; do sleep 0.2; done
rm -f "$EMUU_HOME/avd/$G.avd/"*.lock
for c in a b; do
  C="$G-$c"; mkdir "$EMUU_HOME/avd/$C.avd"
  t0=$(now)
  for f in $(ls "$EMUU_HOME/avd/$G.avd"); do
    case $f in multiinstance.lock|hardware-qemu.ini|*.lock|emu-launch-params.txt|read-snapshot.txt|bootcompleted.ini|tmpAdbCmds|netsim.ini) continue;; esac
    cp -cR "$EMUU_HOME/avd/$G.avd/$f" "$EMUU_HOME/avd/$C.avd/"
  done
  sed -e "s/^AvdId=.*/AvdId=$C/" "$EMUU_HOME/avd/$G.avd/config.ini" > "$EMUU_HOME/avd/$C.avd/config.ini"
  sed -e "s#$G.avd#$C.avd#" "$EMUU_HOME/avd/$G.ini" > "$EMUU_HOME/avd/$C.ini"
  HW="$EMUU_HOME/avd/$C.avd/snapshots/default_boot/hardware.ini"
  sed -e "s#/$G.avd/#/$C.avd/#" -e "s/^avd.name = .*/avd.name = $C/" -e "s/^avd.id = .*/avd.id = $C/" "$HW" > "$HW.n" && mv "$HW.n" "$HW"
  echo "clone $c: $(awk -v a="$(now)" -v b="$t0" 'BEGIN{printf "%.2f", a-b}') s"
done
echo "clone disk: du (apparent sharing ignored) $(du -sh "$EMUU_HOME/avd/$G-a.avd" | cut -f1); volume free $(df -h "$EMUU_HOME" | tail -1 | awk '{print $4}')"
pa=$(launch "$G-a" $PA -no-snapshot-save); pb=$(launch "$G-b" $PB -no-snapshot-save)
(echo "resume a: $(waitboot emulator-$PA 120) s") & (echo "resume b: $(waitboot emulator-$PB 120) s") & wait
grep -h "snapshot 'default_boot'" "$EMUU_HOME/logs/bench-$G-a.log" "$EMUU_HOME/logs/bench-$G-b.log" | sed 's/^/  /'
sleep 30
echo "after boot+30s: engine a $(fp $pa) b $(fp $pb); host $(hostmem)"
( for i in $(seq 1 $(( LOOP / 30 ))); do sleep 30; echo "  t+$((i*30))s engine a $(fp $pa) b $(fp $pb); host $(hostmem)"; done ) &
sampler=$!
ABORT_AFTER=0 "$HERE/farm-workload.sh" emulator-$PA "$LOOP" > "$EMUU_HOME/logs/bench-$G-wa.txt" &
wa=$!
ABORT_AFTER=0 "$HERE/farm-workload.sh" emulator-$PB "$LOOP" > "$EMUU_HOME/logs/bench-$G-wb.txt" &
wb=$!
wait $wa $wb; kill $sampler 2>/dev/null; wait $sampler 2>/dev/null
cat "$EMUU_HOME/logs/bench-$G-wa.txt" "$EMUU_HOME/logs/bench-$G-wb.txt"
echo "after loop: engine a $(fp $pa) b $(fp $pb); host $(hostmem)"
for i in 1 2 3; do
  "$ADB" -s emulator-$PA install -r "$HERE/secure-test-apk/build/emuu-securetest.apk" >/dev/null 2>&1
  t0=$(now); "$ADB" -s emulator-$PA emu avd snapshot load default_boot >/dev/null 2>&1
  r=$(waitboot emulator-$PA 60)
  left=$("$ADB" -s emulator-$PA shell pm list packages dev.emuu.securetest | tr -d '\r')
  echo "reset $i (snapshot load → adb-ready): $(awk -v a="$(now)" -v b="$t0" 'BEGIN{printf "%.2f", a-b}') s; test app after reset: ${left:-gone}"
done
echo "after resets: engine a $(fp $pa)"
kill -9 $pa $pb 2>/dev/null; sleep 2
for a in "$G" "$G-a" "$G-b"; do rm -rf "$EMUU_HOME/avd/$a.avd" "$EMUU_HOME/avd/$a.ini" "$EMUU_HOME/instances/$a.json"; done
echo "host after cleanup: $(hostmem)"
