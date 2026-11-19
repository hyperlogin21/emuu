# Benchmarks

Measured on 2026-11-18 on the development Mac: Apple Silicon, 10 cores, 16 GiB RAM, macOS 26.6.2, Android
Emulator engine 36.4.9, image `system-images;android-36.1;google_apis_playstore;arm64-v8a`. All numbers come
from real runs. One run per configuration, so treat differences of ~200 MiB as noise (the two Emuu runs
below differ by that much after the same app launches).

## What was compared

| | Stock-style | Emuu lite (as shipped before this run) | Emuu lite, tuned |
| --- | --- | --- | --- |
| AVD config | Copy of Android Studio's "Medium Phone" config: 1080x2400 @ 420 dpi, 2048 MB, 4 cores, `gpu auto`, mic on, virtual-scene + emulated cameras, 512 MB sdcard, VM heap 336 | `emuu create --preset lite`: 720x1600 @ 320 dpi, 1536 MB requested (the engine raises it to 2048 MB), 2 cores, `gpu host`, no mic, cameras off, unused sensors off, no sdcard | same |
| Launch | `emulator -avd stock -no-snapshot-load` (stock Qt window) | `emuu start --detach --idle-freeze 2` (headless) | same |
| Governor | none | frugal; freeze after 2 min idle, **hibernate 30 min** into a freeze | frugal; freeze after 2 min idle, **hibernate 5 min** into a freeze |

Each run did the same thing: cold boot; wait 60 s; install two small F-Droid APKs (Editor, Level); launch 8
apps 10 s apart (Settings, Messages, Play Store, Editor, Level, Phone, Contacts, Chrome); press Home; wait
60 s; then 10 minutes of idle, sampling every 30 s.

`--idle-freeze 2` stands in for "the window is hidden": headless Emuu treats the instance as hidden, and the
flag lets the governor freeze it after 2 minutes without Emuu commands. (With the app or `start --window`,
a minimised or covered window does the same, with the same profile timers.) The stock emulator has no
equivalent; its window stayed open and the engine kept running.

**Metric.** Engine `phys_footprint` from `proc_pid_rusage` (the same number as Activity Monitor's
"Memory" column and `top`'s MEM; it includes the process's compressed pages), plus resident size. Only the
QEMU process is counted, for both. The Emuu supervisor process was 5-6 MiB throughout and is not included.

## Results

| Engine footprint (MiB) | Stock-style | Emuu lite | Emuu lite, tuned |
| --- | ---: | ---: | ---: |
| Cold boot to `sys.boot_completed` | 31 s | 20 s | 19 s |
| After boot (+60 s) | **4775** (resident 3678) | **4381** (resident 3863) | **4367** (resident 3699) |
| After launching 8 apps (+60 s) | **4995** (resident 3252) | **4304** (resident 2718) | **4496** (resident 3296) |
| Guest MemAvailable after the apps | 731 MiB | 729 MiB | 812 MiB |
| After 10 min idle / hidden | **4889** (resident 1008), running, ~5 % CPU | **4299** (resident 16), frozen, 0 % CPU | **0** (engine hibernated at 5 min into the freeze) |
| Getting back to a usable device | already running | thaw: instant | resume: 2 s |

Governor actions in the Emuu runs: two T1 trims of background apps during the app phase, then T4 freeze
about 2 minutes after the last command (run 1: 22:52:41; tuned: 23:07:17), and in the tuned run T5
hibernate at 5 min 01 s into the freeze (hibernate took 2 s). Resume after the tuned run took 2 s and the
previously open apps came back.

## What this shows, honestly

* **Lower footprint while in use, by about 8-14 %.** Emuu's tuned instance (smaller screen, no mic,
  cameras or sdcard, no Qt window) costs 400-700 MiB less than the stock-style AVD after boot and after
  launching apps. It is still about 4.3-4.5 GiB for a 2 GiB guest: most of the cost is the engine itself,
  which Emuu cannot change. The Emuu numbers do not include the display: at the time the scrcpy server added
  about 170 MB inside the guest while a window was visible; the current display (engine framebuffer over gRPC,
  see the last section) adds nothing in the guest.
* **Freezing alone does not lower the footprint.** A frozen engine keeps its 4.3 GiB `phys_footprint`.
  macOS compresses or swaps the stopped process's pages (resident fell to 16 MiB), so it stops costing CPU
  and active RAM, but the memory is still charged to the Mac's compressor/swap: at the end of the first
  Emuu run, macOS reported **high** memory pressure. The stock engine kept its pages too (resident about
  1 GiB, footprint 4.9 GiB) and kept using about 5 % CPU.
* **Fix applied after the first run:** the lite profile hibernated only after 30 minutes frozen, so a
  10-minute idle period never got past "frozen". Hibernate frees everything and resumes in about 2 s, so
  the lite profile now hibernates 5 minutes into a freeze (`GovernorConfig.preset(.frugal)`:
  `hibernateWhenFrozenAfter` and `hibernateWhenFrozenUnderCreepAfter` 30/10 min → 5/5 min). Re-measured:
  the engine footprint after the idle period went from 4299 MiB to 0. The balanced profile keeps its 2 h
  timer, and performance still never hibernates on a timer.
* **Fix found while benchmarking:** the governor sized its footprint budget from the configured RAM
  (1536 MB for lite) instead of the RAM the engine really runs (2048 MB). The budget was therefore 4 GiB
  instead of 5 GiB, and a normal 4.4 GiB engine was reported as "elevated" pressure, which caused repeated
  T1 trims that freed nothing ("+0 B guest available"). The supervisor and the app now read the
  engine's `hardware-qemu.ini` after boot (`EngineEffectiveRAM`). Verified on a fresh lite instance: level
  stayed `normal` at 4.35 GiB.
* **Not measured here:** hours-long sessions (creep detection, scheduled maintenance), behaviour under
  real guest memory pressure, and the balanced and performance profiles.

## Other measurements from the same session

| Operation (instance `emuu-e2e`, standard preset, through `emuu`) | Time |
| --- | ---: |
| Cold boot (`start --detach`, first boot) | 19.2 s |
| Install a 263 KiB / 1.3 MiB APK | 0.7 s / 0.6 s |
| Freeze / thaw (SIGSTOP / SIGCONT via the supervisor) | < 0.03 s each |
| Hibernate (save + quit) | 1.1 s |
| Resume from hibernation | 2.1 s (engine footprint right after resume: 1.80 GiB, growing as pages are touched) |
| Stop | 6.2 s |
| Display (old scrcpy path): session start to first decoded frame | 0.42 s |
| Display (old scrcpy path): resume after pause | 0.90 s |

Manual tiers on `emuu-e2e` with 4 apps open (`emuu mem trim`, `mem trim --kill`, `mem reclaim`):
T1 trim MODERATE applied to 20/20 processes, +0 B guest MemAvailable; T2 kill of cached apps (19 packages)
+86 MiB; T3 reclaim `unsupported` (no balloon driver in the guest kernel); `compact system` +47 MiB. None of
these change the engine's host footprint measurably; only hibernate returns host memory.

## Display: engine framebuffer over gRPC vs the old scrcpy stream (2026-11-19)

Same Mac (16 GiB, other engines running, so ±20 %). Instance `agent-test` (lite, 720x1600 @ 320, 2 vCPUs,
`-gpu host`), isolated `EMUU_HOME`. New path measured inside the release app by its self-test
(`EMUU_APP_SELFTEST=cycle:agent-test:1 EMUU_APP_SELFTEST_ONLY=native`, the code is in `SelfTest.exerciseNativeDisplay`);
guest/engine A/B measured with the same 15 s swipe loop for "no display client", "scrcpy-server 5.0.1 (8 Mbit/s,
60 fps, as the old Emuu ran it)" and "gRPC streamScreenshot with shared memory".

| | Old: scrcpy (H.264 in the guest → VideoToolbox) | New: engine framebuffer (gRPC + shm) |
| --- | --- | --- |
| Something in the guest | scrcpy-server `app_process`: **~171 MB RSS** (+2 small shells) | **nothing** |
| Guest CPU during animation (sum over vCPUs) | 71–74 % (no client: 63–65 %) → **+7–11 points** | 65–66 % → **+1 point (noise)** |
| Engine (QEMU) host CPU during animation | 86–93 % (no client: 83–84 %) | 94–95 % → **+10 points** (framebuffer readback + copy into shm at 60 fps) |
| App CPU, static screen (20 s, window "visible") | stream kept running (encoder repeat-frame every 0.5 s); not measured here | **0.12 %, 0–2 frames** (release; engine sends nothing) |
| App CPU during animation (10 s of swipes) | not measured (needs a visible window; this session's desktop could not show one) | **4.2 %** at 59.6 fps, 0 dropped (release); 2.8 % at 55 fps, 6 dropped in a run with the host busy |
| App footprint | 40–50 MB (earlier measurement) | 56–80 MB (release, window open; ~5 pooled 4.6 MB frame buffers) |
| Engine → app transport latency (frame timestamp → receipt) | – | 2.6–5.6 ms (30 ms once with the host busy) |
| Input → first changed frame (Recents key, n = 8) | – | **min 31, median 42–47, max 52–66 ms** (+ ≤ 1 vsync to glass) |
| Window shown → first frame | 0.90–0.99 s (stream restart) | **0.15 s** (reopen stream; current frame sent at once); first open 0.22–0.27 s |
| Focus changes | restarted the stream (60 ↔ 15 fps), every few seconds in the user's log | **no restarts**: only shown/hidden open/close the stream |
| Secure (`FLAG_SECURE`) windows | **black** | shown (docs/evidence/secure-window-native.png) |

Notes:

* The old path's per-frame host work was an H.264 decode (VideoToolbox, partly in `VTDecoderXPCService`); the new
  path's is one 4.6 MB RGBA→BGRA vImage permute into a pooled IOSurface (≈0.5 ms), then zero-copy to the window
  server. The engine pays the readback instead of the guest paying an encoder.
* With the window hidden both paths cost nothing (old: stream paused after 3 s; new: stream closed after 1 s).
* App binary: 4.0 MB bundle (was 3.9 MB); no third-party gRPC/protobuf/NIO packages (hand-written h2c client).

## Farm (2026-11-19)

Same Mac (Apple M5, 10 cores, 16 GiB, macOS 26.6.2), engine 36.4.9, image android-36.1 Play Store, isolated
`EMUU_HOME`. The user's own apps were running throughout (≈ 8–10 GiB of anonymous+wired+compressed memory and
≈ 4.7–5.1 GiB of swap in use before any engine started), so host-memory figures are for a busy laptop, not an idle
one. Raw logs: `docs/evidence/farm-bench-*.txt`, `docs/evidence/farm-soak-*.txt`.

### Which memory number

* `phys_footprint` (Activity Monitor "Memory", `top` MEM) **counts the guest RAM twice** on this engine: it is
  ≈ guest RAM larger than `footprint -p` (the sum of the process's dirty, compressed and swapped pages, each
  once). After a 10-minute loop: 2048 MB guest 4.9 GB vs 2.86 GB; 1536 MB guest 3.86 GB vs 2.35 GB.
* The **real** per-device cost is the `footprint` number: starting one engine on a quiet Mac raised
  anonymous+wired+compressor pages by ≈ 2.5 GB, not 4.4. Both are reported below as `phys / real`.

### Method (`scripts/farm-bench.sh`, one run per row unless noted)

For each configuration: create and cold-boot a golden, apply the farm settings (animations off etc.), seal it after
150 s of uptime, APFS-clone it twice, resume both clones at once (`-no-snapshot-save`), run
`scripts/farm-workload.sh` on both **concurrently for 10 minutes** (per iteration: install, `am start -W`, tap,
swipe, uiautomator dump, screencap, Settings, 2 swipes, back, logcat, home, uninstall = 13 adb commands), then
reset device A three times with `avd snapshot load` and check the test app is gone. Throughput = loop iterations
per minute per device (both devices ran the same loop at the same time, so it is "per device with a neighbour").

### Profiles (two devices running the loop concurrently)

| Config (guest RAM / vCPUs / GPU) | Engine after resume +30 s, phys / real (MiB) | After the 10-min loop, phys / real (MiB) | Clone + resume to adb-ready (both at once) | Reset (snapshot load → adb-ready, 3×) | Loop iterations / min per device | adb commands failed | Host during the loop |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **2048 / 2 / host** | 4506, 4516 / – ¹ | 4924, 4924 / 2858, 2854 ¹ | 0.03 s + 2.40, 2.41 s | 1.43, 1.51, 1.67 s | **17.1, 17.1** | 0 of 4472 | pressure normal throughout; swap 4.76–4.90 GiB (flat) |
| 1536 / 2 / host | 3589, 3589 / 2164, 2164 | 3862, 3858 / 2354, 2350 | 0.03 s + 2.46, 2.53 s | 1.26, 1.53, 1.84 s | 14.0, 14.0 ² | 0 of 3640 | normal; free 44–55 % ² |
| 1536 / 2 / host, repeat | 3588, 3522 / 2155, 2088 | 3877, 3640 / 2370, 2134 | 0.03 s + 3.29, 2.08 s | 0.65, 1.40, 1.48 s | 13.3, 13.5 ⁴ | 0 of 3497 | normal; free 45–58 % ⁴ |
| 1536 / 2 / host, `--lean` | 3486, 3484 / 2155, 2154 ⁵ | 3820, 3821 / 2230, 2303 ⁵ | 0.03 s + 1.51–1.65 s | 0.99–1.40 s | (18.9, 19.1 over the first ~100 s) ⁵ | 2 + 2 ⁵ | normal; free 53–57 % |
| 1024 / 2 / host | 2421, 2363 / 1490, 1433 | 2716, 2558 / 1693, 1551 | 0.04 s + 1.73, 1.85 s | 0.66, 0.78, 1.47 s | 6.6, 7.1 | 0 of 1794 | normal ³ (guest zram nearly full: MemAvailable 270 MB after settle) |
| 1536 / 2 / swiftshader_indirect | 3666, 3669 / 2238, 2239 | 3990, 4002 / 2483, 2494 | 0.03 s + 1.95, 2.14 s | 1.33, 1.40, 1.47 s | 12.8, 12.8 | 0 of 3354 | normal, free 55–58 %; engine CPU 160–300 % each (host GPU: see soak) |
| 1536 / 1 / host | 3429, 3475 / 1987, 2032 | 3624, 3746 / 2106, 2228 | 0.03 s + 2.02, 2.11 s | 0.74, 1.18, 1.54 s | 12.8, 12.8 | 0 of 3341 | normal, free 54–56 %; engine CPU ≈ 81 % each |

¹ The first run predates the `real` column; `footprint -p` taken by hand at minute 9 of the loop gave 2858 and
2854 MB. ² A third engine (the `base` golden being created) booted during the last 2 minutes of this run; host
free fell to 36 % and pressure reached "warn" once, so the throughput may be slightly low (repeat below).
³ My fault-injection tests ran a third engine during part of this run (pressure "warn" twice).
⁴ A third engine (lean investigation) ran during minutes 1–7 of this loop.
⁵ Two runs, neither a valid 10-minute loop: the first was broken by editing the workload script mid-run; in the
second both devices failed two commands in a row at the same moment (`input swipe`, `uiautomator dump`; quick
failures) about 2.5 minutes after resume, and the loop stopped there. A 4-minute rerun on one lean clone had 0
failures and no crash/ANR. Not enough evidence that `--lean` is stable, and the memory saving is small (≈ 0.1 GB
real per device), so it stays an option, not the default. Details: `docs/evidence/farm-bench-NOTES.txt`.

Run-to-run noise: the two 1536 runs differ by 0.5–0.7 iterations/min and ≈ 0.2 GB real footprint per device; the
two devices of one run differ by up to 0.2 GB. Treat smaller differences as noise.

### What was not changed, and why

* **Guest RAM below 2048 MB** works (`-qemu -m`, see engine-findings.md) and saves ≈ 0.5 GB real per device per
  512 MB, but throughput drops: 1536 MB ran the loop 18–22 % slower than 2048 MB, 1024 MB ran it at less than half
  the speed (zram nearly full in the guest). 1024 MB is not usable for this image.
* **swiftshader_indirect** (CPU rendering) used *more* memory than the host GPU (≈ +0.13 GB real), 160–300 % CPU
  per engine, and 9 % lower throughput. The host GPU (`-gpu host`) stays.
* **1 vCPU** saves ≈ 0.15 GB and caps the engine near one core (≈ 81 %), at 9 % lower throughput than 2 vCPUs.
  Useful only when cores, not memory, limit capacity (`golden create --cores 1`).
* **No audio** (`-no-audio`) is already the farm default; **`-no-snapshot-save`** is used by every farm clone
  (the golden's snapshot is never overwritten; reset = snapshot load).
* **zram/swappiness**: `/proc/sys/vm/swappiness` and `/sys/block/zram0/*` are permission-denied for the shell
  user on this image; nothing to tune.
* **gRPC display service**: farm devices keep it. Per-device real footprint with it on (soak, below: 2.79–2.88 GB
  at start) matches the bench run without it (2.86 GB) within the noise, and it lets `emuu screenshot` (verified on a farm device) and the app
  show a device on demand.

### Default farm profile

**2048 MB guest, 2 vCPUs, `-gpu host`, no audio, animations off, not lean** (`emuu golden create` defaults; see
`FarmProfile`): the fastest configuration measured (17.1 iterations/min per device with two running), 0 failed adb
commands, ≈ 2.9 GB real memory per device. Two of them fit a 16 GB Mac with the user's apps open (soak below).
Smaller guests are an explicit choice (`--ram 1536`): ≈ 0.5 GB less per device for ≈ 20 % less throughput.

### Capacity: formula and ESTIMATES for other Macs

Only the 16 GB Mac was measured. The capacity guard computes, for the host it runs on:

    reserve   = max(8 GiB, 40 % of RAM)            macOS + the user's own apps
    per device = guest RAM + 850 MiB                (measured real cost: 2048 → 2.86 GB, 1536 → 2.35 GB after the loop)
    devices   = min(⌊(RAM − reserve) ÷ per device⌋, ⌊logical cores ÷ vCPUs per device⌋, 16)

plus a live check before each new device (macOS pressure normal, available ≥ one device + 10 % of RAM).

**ESTIMATES (not measured):**

| Mac RAM | reserve | left for devices | 2048 MB guests | 1536 MB guests | 1024 MB guests | CPU limit (2 vCPUs each) |
| --- | --- | --- | ---: | ---: | ---: | --- |
| 16 GB (measured host) | 8.0 GiB | 8.0 GiB | **2** | 3 | 4 | 10 cores → 5 |
| 24 GB | 9.6 GiB | 14.4 GiB | 5 | 6 | 7 | 8–12 cores → 4–6 |
| 32 GB | 12.8 GiB | 19.2 GiB | 6 | 8 | 10 | 10–14 cores → 5–7 |
| 48 GB | 19.2 GiB | 28.8 GiB | 10 | 12 | 15 | 12–16 cores → 6–8 |

So on 24–48 GB Macs with 2-vCPU devices the **CPU limit** usually wins (`farm capacity` prints which factor
limits). Whether that many devices keep the 17 iterations/min each was not measured; expect contention for the
GPU and I/O. Disk per device: see the soak (the clone itself costs ≈ 0; the device's writes during a session are
the cost).


### Two-device soak (acceptance test), 35 minutes

`EMUU_HOME=<scratch> scripts/farm-soak.sh base 35 12` on 2026-11-19 11:18–11:54: `emuu farm up --size 2` from the
default-profile golden `base` (2048 MB, 2 vCPUs, host GPU), two workers each looping *acquire → 45 s of the
workload → heartbeat → release (reset)*, a sampler every 30 s, and a fault injection at minute 12. The user's apps
were open the whole time. One run. Raw logs: `docs/evidence/farm-soak-*.txt` (+ `farm-soak-status.json`, the final
`farm status --json` with the full event history).

| | Result |
| --- | --- |
| Pool start (2 clones + resume + health/settle check) | 5.7 s to both ready (adb-ready 5.23 / 5.24 s incl. the 3 s settle check) |
| Concurrent acquire (6 processes, 2 ready devices) | 2 leases on 2 distinct devices, 4 × exit 69 |
| Work done | 1042 loop iterations, **13 528 adb commands OK, 4 failed** — all 4 at the injected faults (2 per device, after which the worker stopped that run) |
| Throughput | 16.0–17.3 iterations/min per device per 45 s chunk (same as the 10-minute bench) |
| Leases / resets | 86 acquires, 86 releases, 84 resets (release → ready **4.18–5.01 s, median 4.45 s**, of which 3 s is the settle check; the snapshot load itself 0.65–1.84 s in the bench), 1 failed reset → recycled, 0 expired leases |
| Guest reboots after a snapshot load | **0** (settle checks: 84 resets + 4 resumes; the workload's own boot-id check: 0 changes) |
| Engine memory over time (both devices) | real 2.79–2.88 GB at start, 3.13 GB after 23 minutes and ≈ 40 resets each (+0.1 GB); `phys_footprint` 4.73–5.13 GB |
| Host | macOS memory pressure **normal at every sample** (69 samples), "free" 46–60 %, swap flat at 5.33–5.41 GB (it fell slightly); Mac usable throughout (this session's own work continued on it) |
| Disk | volume free space fell by 84 MiB after cloning + resuming both devices, by 579 MiB at the end (writes of 2 devices over 35 minutes, plus other processes ±100 MiB) |

**Fault injection** at 11:30:55: SIGSTOP of device 1's engine from outside (a hung engine) and `kill -9` of
device 2's engine (a dead one), both while leased. From the pool's event history:

| t after fault | Event |
| --- | --- |
| +2.0 s | device 1: health check "hung: engine is SIGSTOPped but Emuu did not freeze it" → suspect (confirming) |
| +5.0 s | device 2: its worker had seen 2 failed commands and released it; the reset failed (engine gone) → recycled, adb-ready 4.72 s |
| +7.0 s | device 1: confirmed → lease marked `device_lost` (the worker's `farm heartbeat` exited 75), engine destroyed |
| +12.0 s | device 1: released by its worker → recycled, adb-ready 4.54 s |
| **+13 s** | **pool back to 2 healthy devices** |

Time to detect: 2 s to suspect and 7 s to confirm the hang (leased devices are checked every 15 s and need two bad
checks 5 s apart, so the worst case is ≈ 20 s); the dead engine was noticed first by the test itself. Time to
recover: 13 s for both. `am hang` was not used: on this image it does not hang anything a probe can see
(engine-findings.md, "Farm findings").

What this does not cover: runs longer than 35 minutes, more than one soak run, a guest that hangs *inside*
Android while the shell keeps working (not provocable as the shell user), and Macs other than this one.
