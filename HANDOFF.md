# Emuu handoff

Written 2026-11-19. Repo: `/Users/leslie/dev/emuu` (git, origin = private GitHub; the orchestrator commits).

## Status update (2026-11-19, window closes on shutdown / hibernate)

- An instance's window now **closes by itself** when the device shuts down or hibernates: Android power-off,
  `emuu stop`, `adb emu kill`, library Shut Down / Hibernate, the window's Hibernate, the governor's or a CLI
  supervisor's hibernation (also minimised). The library shows Stopped/Hibernated; opening it starts/resumes it.
  It stays open for guest reboots, engine restarts (`emuu reboot --hard|--cold`, heal, self-heal, Restart Engine —
  it reconnects), freeze/thaw, crashes (error + Retry/Cold Boot) and failed starts.
- Logic: `Sources/EmuuApp/Model/WindowAutoClose.swift` (pure, `WindowAutoClosePolicyTests`), wired in
  `InstanceSession.engineStateChanged` / `AppModel.engineEnded`. Exits seen from outside are confirmed after 4 s
  (a restart brings a new engine within ~1 s). Engine 36.4.9 reports a guest power-off as a SIGKILL "crash" after a
  20 s hang; the app recognises it from the engine log line "… to shutdown gracefully before kill".
- Self-test: `EMUU_APP_SELFTEST_HIBERNATE=1` (hibernate from the app closes the window, recording finalised,
  reopen resumes), `EMUU_APP_SELFTEST_ONLY=none`, `EMUU_APP_SELFTEST_LEAVE_OPEN=1|minimized`.
- Verified on a scratch instance through the app's log; CGWindowList could not confirm closes (screen locked: closed
  windows — also ones closed the old way — stayed listed as on screen).

## Status update (2026-11-19, display flicker in HD video / TikTok)

- **Reported:** flicker in HD video (TikTok) in the native display. Investigated on an isolated instance with a
  machine-readable test pattern (scripts/flicker-test: H.264/HEVC/VP9 720p/1080p 30/60 fps, SurfaceView/TextureView,
  in-feed, GL, texture upload) and new diagnostics (`emuu debug display-probe`, `EMUU_DISPLAY_DIAG`; docs/ARCHITECTURE.md
  "Diagnosing display artefacts"). Numbers: docs/evidence/flicker-measurements-2026-11-19.txt.
- **Found:** the MMAP shared-memory region is not synchronised; under host load the engine writes into it (bottom row
  first) while Emuu reads it → torn frames (an older band at the top). Seen only in the window process under load:
  ~24–49 overlapping writes per 6 000 frames, about 40 % of those reads torn; 2 torn frames presented in one
  unvalidated run. **Fix:** every MMAP read is validated (convert, then compare with the region; retry/drop) —
  validated runs presented 0 torn frames. Cost ≈ +3.5 % of one core and +0.5 ms per frame at 60 fps.
- **Not Emuu:** frames from the engine were otherwise clean (≈ 25 000 frames, MMAP = inline). One presented A-B-A flash
  under load was a badly decoded video frame (guest/host decoder). Real TikTok was not tested (no Google sign-in);
  the WindowServer composite could not be observed (screen locked). Whether this race is what the user sees in TikTok
  is **unverified** — the user should run the probe/diag (below) and send the counts.
- **User check:** quit Emuu, then `EMUU_DISPLAY_DIAG=1 /Users/leslie/dev/emuu/dist/Emuu.app/Contents/MacOS/Emuu`, play
  TikTok for 2–3 minutes, then `grep display.diag ~/.emuu/logs/emuu.log | tail -5` (and the PNGs in
  `~/.emuu/logs/display-diag/`). Headless alternative: `emuu debug display-probe emuu-dev2 --duration 60 --save ~/Desktop/emuu-flicker`.

## Status update (2026-11-19, automation farm)

Goal now: an automation test farm on this MacBook (16 GB, 10 cores): **2 emulators at once**, reliably, for long
sessions, Mac stays usable; scalable to Macs with up to 48 GB; self-healing. Built by one agent under an isolated
`EMUU_HOME` (scratch); the real `~/.emuu` (incl. `emuu-dev2` with the user's Google sign-in) was not touched.

- **New target `EmuuFarm`** + CLI: `golden create|seal|list|delete`, `clone`, `farm up|down|acquire|release|heartbeat|status|capacity|gc`
  (hidden `farm daemon`), `run`, `health`, `heal`, `reboot`, `start --self-heal`. README sections "Automation farm" and
  "Self-healing"; ARCHITECTURE.md section; measurements in BENCHMARKS.md "Farm" and engine-findings.md "Farm findings".
- **Clones:** APFS `clonefile` of the golden AVD incl. its quick-boot snapshot; resume to adb-ready ≈ 2 s. The snapshot's
  `hardware.ini` must be rewritten and the golden's own `config.ini` kept, otherwise the engine cold-boots.
  Engine `-read-only` was measured and rejected (it writes into the golden's directory, leaks /tmp overlays).
- **Reset** = console `avd snapshot load default_boot` in the running engine (≈ 1–1.8 s, app data verified gone) +
  a 3 s settle check of the guest boot id; recycle (kill + re-clone + resume) ≈ 2 s + check.
- **Memory:** Activity Monitor's 4.5 GB per engine double-counts guest RAM; real cost ≈ guest RAM + 0.8 GB
  (2048 MB guest: 2.86 GB after a 10-minute loop). Capacity guard: min(memory, cores/2, 16 ports); 2 devices on 16 GB.
- **Soak (acceptance):** 2 devices, 35 min, 13 528 adb commands OK, 4 failed (all at injected faults), 84 resets,
  0 guest reboots, memory pressure normal throughout, swap flat; SIGSTOP + kill -9 injected → pool back to 2 healthy
  devices in 13 s. Details and the profile table in BENCHMARKS.md "Farm".
- **Default farm profile:** 2048 MB / 2 vCPUs / host GPU (fastest measured: 17 loop iterations/min per device;
  1536 MB is ≈ 20 % slower for 0.5 GB less, 1024 MB half as fast, swiftshader slower and bigger).
- **Self-healing:** `emuu health` (layered probes), `emuu heal` (confirm, then thaw → reconnect adb → soft reboot → hard
  restart → cold boot), `emuu reboot --soft|--hard|--cold`, `emuu start --self-heal` (20 s checks, 2 confirmations,
  backoff, circuit breaker after 3 attempts / 30 min). Pools self-heal by default; leased devices that fail two checks are
  marked `device_lost` and replaced. Verified for real: external SIGSTOP, kill -9, adb transport drop (see
  docs/evidence/farm-integration-2026-11-19.txt and the soak).
- **Open / not verified:** `--lean` (one benchmark run had simultaneous command failures on both devices, cause not
  found; not the default); a framework deadlock could not be provoked as the shell user (`am hang` parks one binder
  thread only; `am crash` on system_server does nothing), so the framework probe is verified on healthy devices and in
  unit tests only; no "engine CPU pegged without progress" probe; clones share the golden's android_id; capacity on
  24–48 GB Macs is an estimate; the app has no health badge (CLI only).
- A `swiftpm-testing-helper … EmuuDisplayTests` process started 2026-11-18 23:48 (before this agent) is still running;
  left alone.

## Status update (2026-11-19, later)

The display agent described under "In progress" has finished; that section is now history. `swift build` and `swift test` (378 tests) pass.

- **Display** now uses the engine's host framebuffer over gRPC (`Sources/EmuuGRPC`, own client, no external packages). scrcpy is removed. Secure windows are visible (`docs/evidence/secure-window-native.png`).
- **Rotation** turns the virtual device; `emuu rotate` added. Portrait-locked apps (home screen) stay portrait, shown sideways, by choice.
- **Governor:** Mac memory pressure no longer triggers guest trim/kill; guest tiers wait 3 minutes after boot/resume and never run during Play Store, sign-in or installer screens.
- **Guest reboot not root-caused.** It was not reproduced as caused by the kill tier; one of 7 resumes restarted the guest by itself right after a snapshot load. Reboots are now detected and logged with the governor's last 12 actions.
- **`emuu-e2e` deletion:** the agent states it did not delete it; the log line is consistent with a delete from the app's library. The user has not yet said whether they did it.
- **`emuu-dev2`** is the only instance. The user signed in to Google on it. It had a console port (5600) outside adb's scan range and could not boot; the `ports` entry was removed from `~/.emuu/instances/emuu-dev2.json` (backup beside it, `.bak-ports`). Its quick-boot snapshot was discarded, so the next start is a cold boot. Not yet booted since the fix.
- **Not verified on screen:** minimise/restore with real window events, trackpad pinch/scroll, device-to-Mac clipboard. Non-ASCII typing from the Mac keyboard does not reach Android (paste works).
- **Next:** user relaunches `dist/Emuu.app` and tries sign-in screens, rotation and un-minimise; then start the automation-farm work below once the user answers the three farm questions.

## Goal

A lightweight Android emulator for macOS (Apple Silicon) with:

- better memory behaviour over long active sessions,
- APK and game installs (including drag and drop),
- Play Store support,
- adb access for automations,
- a native window with side controls (screenshot, recording, keyboard, volume, rotate).

The user asked for implementation to be delegated to Opus subagents, using workflows.

**Goal update (2026-11-19):** the primary use is now **automation farms for testing** — spinning up emulators on demand and driving them over adb. The interactive window stays, but headless, many-instance operation takes priority. Not started; planned after the display agent finishes:

- on-demand instances from a prepared "golden" instance (APFS copy-on-write clone + quick-boot snapshot, so a new emulator is ready in seconds and costs little disk),
- ephemeral instances that are destroyed or reset to the clean snapshot after a test,
- a pool with automatic port allocation, acquire/release leases, and a capacity limit derived from host RAM,
- machine-readable control (JSON output, and a local API if needed) so CI or a test runner can request devices,
- lowest possible per-instance footprint when headless: today an engine uses about 4.3 GiB, so a 16 GB Mac fits roughly 2–3 at once. Reducing this (guest RAM, GPU mode, no display pipeline) is the key measurement.

Unanswered by the user: where the farm runs (this Mac, dedicated Macs, or Linux servers — Emuu is macOS-only today), how many emulators at once, and whether farm devices need Play Store / a signed-in Google account.

## Key decisions and why

- **Wrap Google's Android Emulator engine, do not write a hypervisor.** Emuu is a native Swift front end plus memory governor around the QEMU-based engine in `~/Library/Android/sdk` (emulator 36.4.9), run headless. Play Store only works on Google-certified images, and games need the engine's GPU forwarding. Apple's Virtualization.framework would lose both.
- **Play Store image:** `system-images/android-36.1/google_apis_playstore/arm64-v8a`. Non-root, so every guest-side command must work as the shell user.
- **State lives in `~/.emuu`** (instances in `~/.emuu/avd` via `ANDROID_AVD_HOME`). Never touch `~/.android/avd` or the user's `Medium_Phone` AVD.
- **Display is being switched from scrcpy video streaming to the engine's host framebuffer over gRPC** (shared-memory `streamScreenshot`, input via gRPC). Reason: Android blanks FLAG_SECURE windows for guest-side capture, so Play Store password/purchase sheets were black. Confirmed on the user's instance: `adb exec-out screencap` was black while `adb emu screenrecord screenshot` showed the sheet. The user explicitly asked for "as native as possible", no video streaming.
- **Memory:** trim/kill tiers do not lower the engine's host footprint and there is no balloon. Only hibernate (snapshot + quit) returns memory to macOS; freeze only saves CPU. The lite profile hibernates 5 minutes into a freeze.
- **Emulator windows are plain AppKit windows**, not a SwiftUI `WindowGroup`, because SwiftUI retained closed windows.
- **One Opus agent for follow-ups instead of a workflow**, because the changes all touch the same app files.

## Done

Initial workflow (11 Opus agents) plus one follow-up agent. At the end of the follow-up: `swift build`, `swift build -c release`, `swift test` (426 tests) and `scripts/make-app.sh` all passed.

- SwiftPM package: `EmuuBase`, `EmuuEngine`, `EmuuADB`, `EmuuMemory`, `EmuuDisplay`, `EmuuTestSupport`, the `emuu` CLI, `EmuuApp`.
- CLI verified end to end on a real instance: doctor, create, start, install, apps, launch, screenshot, playstore, mem, freeze/thaw, hibernate/resume, stop, record, keyboard, automation.
- App: instance library, emulator window with a vertical control strip on the right (SVG icons in `Sources/EmuuApp/Resources/Icons`), drag-and-drop install, memory HUD, click-to-copy adb serial, single-instance guard.
- Recording to MP4 (currently H.264 passthrough from the scrcpy stream).
- Automation mode (`emuu start --automation`, `emuu automation on|off`): never freezes or hibernates. Proven with paired 6-minute soak runs (`scripts/automation-soak.sh`).
- Code review: 19 findings, all fixed.
- Benchmarks in `docs/BENCHMARKS.md`: about 8–14% less engine memory than a stock-style AVD while running; 0 MiB after idle hibernate with about 2 s resume. One run per configuration.

## In progress

A background Opus agent ("Native display via gRPC framebuffer") is working on four problems. Its result had not arrived when this note was written.

1. **Native display:** replace scrcpy with the gRPC host framebuffer; re-implement screenshot, recording (hardware encode only while recording), keyboard toggle, input and lifecycle on it; remove the scrcpy path.
2. **Guest reboot:** on the user's instance the guest fully rebooted about 3 s after the governor's T2 `killBackground(all)` (emuu.log 2026-11-18T23:22:28Z; `sys.boot.reason=reboot`). Causation is not proven. The agent is to reproduce and root-cause it on its own instance.
3. **Governor policy:** host memory pressure must not trigger guest trim/kill; guest tiers respond only to guest pressure, with a grace period after boot/resume, and never during Play Store or sign-in flows.
4. **Rotation:** the user reports Rotate does not work. It currently sends scrcpy's `rotateDevice`. To be re-done through the engine (sensors / gRPC), with window resize, correct touch mapping and `emuu rotate`.

Agent constraints: never touch the user's `emuu-e2e` instance or running app; test on its own instance; delete that instance and leave no processes at the end.

Observed at 08:30 local, from the file system only (no report yet): a new `Sources/EmuuGRPC` target with tests, new `Sources/EmuuDisplay/Render` and `Input` files, a FLAG_SECURE test APK under `scripts/secure-test-apk`, governor policy and test edits, CLI command edits. Two test engines were running (`agent-test` with `-grpc 8584 -grpc-use-token`, and `emuu-dev2`). No secure-window or rotation evidence files existed yet.

## Files and places that matter

- `docs/ARCHITECTURE.md`, `docs/engine-findings.md`, `docs/memory-governor.md`, `docs/BENCHMARKS.md`, `README.md`
- `docs/evidence/` — screenshots, recordings, soak logs
- `Sources/EmuuDisplay/` — being rewritten (scrcpy session, decoder, `MP4StreamRecorder`, `EmulatorDisplayView`, `EmulatorDisplayController`)
- `Sources/EmuuApp/` — `Views/ControlStrip.swift`, `Views/InstanceWindow.swift`, `Windows/InstanceWindowController.swift`, `Model/InstanceSession.swift`, `Support/IconLibrary.swift`
- `Sources/EmuuMemory/Policy/GovernorPolicy.swift`, `GovernorConfig.swift`
- `Sources/EmuuEngine/Engine/EngineInstance.swift`, `Console/ConsoleClient.swift`, `Config/EffectiveRAM.swift`
- `Sources/emuu/` — CLI commands and supervisor
- `scripts/make-app.sh`, `scripts/install.sh`, `scripts/automation-soak.sh`; built app in `dist/Emuu.app`
- Logs: `~/.emuu/logs/emuu.log`, `engine-<id>.log`, `supervisor-<id>.log`

## Open questions and blockers

- **`emuu-e2e` (which held the user's Google sign-in) no longer exists.** `~/.emuu/logs/emuu.log` records `deleted instance emuu-e2e` at 2026-11-18T23:32:29Z (07:32 local). The log does not show whether the app UI or the CLI did it. The display agent was told never to delete it and has been asked; the user has been asked too. Only `emuu-dev2` (the agent's test instance) is in `~/.emuu/avd`, and the user's app has had a window attached to it.
- **No on-screen verification by agents.** They had no Screen Recording permission and the screen was locked, so window behaviour (un-minimise resume, the strip in a live window) is evidenced by unit tests and in-process renders only. The user needs to try these.
- **Keyboard button is imperfect:** Android has no shell command to show or hide the IME. A field an app focuses by itself keeps its keyboard until the next tap.
- **Instrumentation detection** in the governor is tested only against hand-written sample output.
- **Strip memory percentage** stays empty until the HUD is opened when a CLI supervisor governs the instance.
- **Long-run behaviour is unmeasured:** no multi-hour runs; balanced and performance profiles were not benchmarked.
- **Engine exit writes a macOS crash report** each time, even on a clean stop (engine behaviour).
- **Scratch screenshot:** one diagnostic screenshot of the user's Play Store password sheet (email visible, password as dots) is in the session scratchpad under `sec/`. Offered to delete; no answer yet.
- **Usage budget:** the user allotted 50% of their weekly limit. It cannot be measured from inside the session. Spend so far: about 3.0M subagent tokens for the workflow, about 0.56M for the follow-up, plus the agent in progress.

## Next steps

1. Wait for the display agent's completion notice (or, in a fresh session, check whether `Sources/EmuuDisplay` still contains scrcpy code and whether `docs/evidence/secure-window-native.png` and `rotate-*.png` exist).
2. Run `swift build`, `swift build -c release`, `swift test`, `scripts/make-app.sh` and confirm they pass.
3. Read the agent's evidence: secure window visible on the native path, rotation captures, the reboot root cause, the updated governor policy tests.
4. Check nothing of the agent's is left running: `pgrep -fl "qemu-system|Emuu.app/Contents/MacOS|emuu "` and `adb devices`.
5. Tell the user to relaunch `dist/Emuu.app` and try: Play Store sign-in (no black screen), Rotate both ways, un-minimise, the keyboard button, recording.
6. If the reboot was not root-caused, keep the governor's kill tier disabled by default until it is.
7. Ask whether to delete the scratch screenshot, whether to `git init` and commit, and whether to benchmark multi-hour sessions.
