#!/bin/bash
# Two-device farm soak: the acceptance test for "two emulators, reliably, for long sessions".
#
#   EMUU_HOME=<scratch> scripts/farm-soak.sh <golden> <minutes> [fault-at-minute|0] [size]
#
# Starts `emuu farm up --size <size, default 2>`, then one worker per device loops:
#   acquire (--wait) → scripts/farm-workload.sh for 45 s (install, launch, taps/swipes, uiautomator dump,
#   screencap, Settings, logcat, uninstall) → heartbeat (exit 75 = device lost) → release (reset to golden)
# A sampler records both engines' phys_footprint and real footprint (footprint(1)), host memory and the farm
# counters every 30 s. At fault-at-minute (default: a third of the run; 0 = none) it SIGSTOPs the first device's
# engine from outside and kill -9s the second one, then measures time to detect and time until the pool is back
# to <size> healthy devices. Raw logs go to $OUT (default $EMUU_HOME/logs/farm-soak-<time>); a summary to stdout.
set -u
GOLDEN="$1"; MINUTES="$2"; FAULT="${3:-$(( $2 / 3 ))}"; SIZE="${4:-2}"
HERE="$(cd "$(dirname "$0")" && pwd)"
EMUU="${EMUU:-$HERE/../.build/debug/emuu}"
: "${EMUU_HOME:?set EMUU_HOME}"
export ADB_TIMEOUT="${ADB_TIMEOUT:-20}"
PY=/usr/bin/python3
OUT="${OUT:-$EMUU_HOME/logs/farm-soak-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
END=$(( $(date +%s) + MINUTES * 60 ))
jsonq() { $PY -I -c "import json,sys; d=json.load(sys.stdin); $1"; }
status() { "$EMUU" farm status --json 2>/dev/null; }
hostmem() {
  vm_stat | awk '/page size of/ {ps=$8} /Anonymous pages/ {a=$3} /Pages wired down/ {w=$4} /occupied by compressor/ {c=$5}
    END {gsub("\\.","",a);gsub("\\.","",w);gsub("\\.","",c); printf "nonfile=%dMiB compressor=%dMiB", (a+w+c)*ps/1048576, c*ps/1048576}'
  printf " swap=%s pressure_level=%s free=%s%%\n" "$(sysctl -n vm.swapusage | awk '{print $6}')" \
    "$(sysctl -n kern.memorystatus_vm_pressure_level)" "$(sysctl -n kern.memorystatus_level)"
}
fp() { printf "%s/real %s" "$(top -l 1 -pid "$1" -stats mem 2>/dev/null | tail -1 | tr -d ' ')" \
  "$(footprint -p "$1" 2>/dev/null | sed -n 's/.*Footprint: \([0-9]* [MG]B\).*/\1/p' | head -1 | tr -d ' ')"; }

echo "== farm-soak: golden $GOLDEN, $SIZE devices, $MINUTES min, fault at minute $FAULT, $(date '+%F %T')" | tee "$OUT/summary.txt"
echo "host before: $(hostmem)" | tee -a "$OUT/summary.txt"
diskfree() { df -k "$EMUU_HOME" | tail -1 | awk '{print $4}'; }   # KiB available on the volume
DF0=$(diskfree)
"$EMUU" farm up --golden "$GOLDEN" --size "$SIZE" --override-capacity >"$OUT/farm-up.txt" 2>&1 || { cat "$OUT/farm-up.txt"; exit 1; }
grep -E "ready in" "$OUT/farm-up.txt" | tee -a "$OUT/summary.txt"
echo "disk: volume free fell by $(( (DF0 - $(diskfree)) / 1024 )) MiB after cloning + resuming $SIZE devices (APFS clones share the golden's blocks)" | tee -a "$OUT/summary.txt"

# Concurrency check: 3 × size acquire processes at the same moment; exactly <size> distinct devices must be leased.
for i in $(seq 1 $(( SIZE * 3 ))); do ("$EMUU" farm acquire > "$OUT/race-$i.txt" 2>/dev/null; echo "rc=$?" >> "$OUT/race-$i.txt") & done
wait
won=$(cat "$OUT"/race-*.txt | grep -c '^L-'); distinct=$(cat "$OUT"/race-*.txt | grep '^L-' | awk '{print $2}' | sort -u | wc -l | tr -d ' ')
echo "concurrent acquire: $(( SIZE * 3 )) processes, $won leases on $distinct distinct devices, $(grep -c 'rc=69' "$OUT"/race-*.txt | awk -F: '{s+=$2} END {print s}') got exit 69" | tee -a "$OUT/summary.txt"
for l in $(cat "$OUT"/race-*.txt | grep '^L-' | awk '{print $1}'); do "$EMUU" farm release "$l" --wait >/dev/null; done
rm -f "$OUT"/race-*.txt

sampler() {
  while (( $(date +%s) < END + 30 )); do
    s="$(status)"
    line=$(echo "$s" | jsonq '
p=d["pools"][0]["state"]; c=p["counters"]
devs=" ".join("%s:%s:%s" % (x["instance"][-1], x["state"], x.get("enginePID","-")) for x in p["devices"])
print(devs, "| resets=%d recycles/replacements=%d hangs=%d recoveries=%d reboots=%d lost-leases=%d" % (c["resets"], c["replacements"], c["hangsDetected"], c["recoveries"], c["rebootsDetected"], sum(1 for e in p["history"] if e["kind"]=="device_lost")))' 2>/dev/null)
    fps=""
    for pid in $(echo "$s" | jsonq 'print(" ".join(str(x["enginePID"]) for x in d["pools"][0]["state"]["devices"] if x.get("enginePID")))' 2>/dev/null); do
      kill -0 "$pid" 2>/dev/null && fps="$fps $pid=$(fp "$pid")"
    done
    echo "$(date +%T) $line |$fps | $(hostmem)"
    sleep 30
  done
}
sampler > "$OUT/samples.txt" 2>&1 &
SAMPLER=$!

worker() {
  local n=$1 cycles=0 lost=0
  while (( $(date +%s) < END )); do
    local j lease serial
    j="$("$EMUU" farm acquire --wait --timeout 300 --json 2>>"$OUT/worker-$n.txt")" || { echo "$(date +%T) acquire failed" >>"$OUT/worker-$n.txt"; sleep 2; continue; }
    lease=$(echo "$j" | jsonq 'print(d["leaseID"])'); serial=$(echo "$j" | jsonq 'print(d["serial"])')
    echo "$(date +%T) lease $lease $serial" >>"$OUT/worker-$n.txt"
    "$HERE/farm-workload.sh" "$serial" 45 >>"$OUT/worker-$n.txt" 2>&1
    "$EMUU" farm heartbeat "$lease" >/dev/null 2>&1
    if [[ $? == 75 ]]; then lost=$((lost+1)); echo "$(date +%T) lease $lease: device_lost" >>"$OUT/worker-$n.txt"; fi
    "$EMUU" farm release "$lease" >/dev/null 2>&1
    cycles=$((cycles+1))
  done
  echo "$(date +%T) worker $n done: cycles=$cycles device_lost=$lost" >>"$OUT/worker-$n.txt"
}
WORKERS=()
for n in $(seq 1 "$SIZE"); do worker "$n" & WORKERS+=($!); sleep 3; done

if (( FAULT > 0 )); then
  sleep $(( FAULT * 60 ))
  s="$(status)"
  read -r P1 P2 <<<"$(echo "$s" | jsonq 'print(" ".join(str(x["enginePID"]) for x in d["pools"][0]["state"]["devices"][:2]))')"
  read -r D1 D2 <<<"$(echo "$s" | jsonq 'print(" ".join(x["instance"] for x in d["pools"][0]["state"]["devices"][:2]))')"
  TF=$(date +%s)
  kill -STOP "$P1"; kill -9 "$P2"
  echo "$(date +%T) FAULT: SIGSTOP $D1 (engine pid $P1), kill -9 $D2 (engine pid $P2)" | tee -a "$OUT/summary.txt"
  # `am hang` is accepted from the shell user on android-36.1 but parks only one binder thread (no probe can see
  # it; measured), so it is not part of the injection.
  until s="$(status)"; echo "$s" | jsonq '
import sys
st=d["pools"][0]["state"]; ok=[x for x in st["devices"] if x["state"] in ("ready","leased") and x.get("enginePID") not in ('"$P1,$P2"')]
sys.exit(0 if len(ok) >= '"$SIZE"' else 1)' 2>/dev/null; do
    (( $(date +%s) - TF > 600 )) && { echo "pool did not recover within 600 s" | tee -a "$OUT/summary.txt"; break; }
    sleep 1
  done
  TR=$(date +%s)
  echo "$(date +%T) pool back to $SIZE healthy devices $((TR - TF)) s after the fault" | tee -a "$OUT/summary.txt"
  status | jsonq '
import datetime
st=d["pools"][0]["state"]; tf=datetime.datetime.fromtimestamp('"$TF"', datetime.timezone.utc)
for e in st["history"]:
    at=datetime.datetime.fromisoformat(e["at"].replace("Z","+00:00"))
    if at >= tf and e["kind"] in ("suspect","unhealthy","device_lost","heal","recovered","recycled","ready","provision-failed","heal-failed","give-up"):
        print("  +%5.1fs %-14s %s %s" % ((at-tf).total_seconds(), e["kind"], e.get("device",""), e["detail"]))' | tee -a "$OUT/summary.txt"
fi

wait "${WORKERS[@]}"
sleep 35; kill "$SAMPLER" 2>/dev/null
status > "$OUT/status.json"
echo "disk: volume free fell by $(( (DF0 - $(diskfree)) / 1024 )) MiB at the end of the run, before farm down (other processes write too: ±100 MiB)" | tee -a "$OUT/summary.txt"
"$EMUU" farm down >"$OUT/farm-down.txt" 2>&1
echo "host after farm down: $(hostmem)" | tee -a "$OUT/summary.txt"
for n in $(seq 1 "$SIZE"); do
  awk -v n="$n" '/iterations=/ { for (i=1;i<=NF;i++) { split($i,kv,"="); s[kv[1]]+=kv[2] } chunks++ }
    / FAIL: / { fails++ } /device_lost/ { lost++ } /boot_id changed/ { boots++ }
    END { printf "worker %s: chunks=%d iterations=%d adb_ok=%d adb_failed=%d device_lost=%d guest_boot_id_changes=%d\n", n, chunks, s["iterations"], s["ok"], s["failed"], lost, boots }' \
    "$OUT/worker-$n.txt" | tee -a "$OUT/summary.txt"
done
jsonq '
c=d["pools"][0]["state"]["counters"]
print("farm counters:", ", ".join("%s=%s" % kv for kv in sorted(c.items())))' <"$OUT/status.json" | tee -a "$OUT/summary.txt"
awk '{ for (i=1;i<=NF;i++) if ($i ~ /^pressure_level=/) { split($i,kv,"="); if (kv[2]>m) m=kv[2] } if ($0 ~ /free=/) { match($0,/free=[0-9]+/); f=substr($0,RSTART+5,RLENGTH-5)+0; if (min==""||f<min) min=f } }
  END { printf "host: max memorystatus_vm_pressure_level=%s (1 normal, 2 warn, 4 critical), min free=%s%%\n", m, min }' "$OUT/samples.txt" | tee -a "$OUT/summary.txt"
echo "raw logs: $OUT" | tee -a "$OUT/summary.txt"
