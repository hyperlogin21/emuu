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
