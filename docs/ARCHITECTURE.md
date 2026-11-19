# Emuu architecture

Emuu is a lightweight Android emulator **front end** for macOS on Apple Silicon. It does not
implement a hypervisor. It drives the Android Emulator engine that is already installed
(QEMU + Hypervisor.framework + gfxstream), runs it **headless**, shows the engine's own framebuffer
through its gRPC service (like Android Studio's embedded emulator), and adds a **memory governor** for sessions
that stay up for hours or days.

Read this whole file before you write code in any module. The contract types it describes live
in `Sources/EmuuBase` and are the only things modules share.

## Product goals

1. Lightweight: no Qt window, small default guest, low idle CPU.
2. Better memory behaviour over long sessions (the main thing that sets Emuu apart).
3. Users can install APKs, split APKs (XAPK/APKS/APKM) and games.
4. Play Store support, through the Google-certified `google_apis_playstore` system image. This
   is the only legitimate way to get the Play Store. It is a non-root image.

## Environment on the target machine

| Item | Value |
| --- | --- |
| Host | M-series, 10 cores, 16 GB RAM. Be frugal. |
| SDK | `~/Library/Android/sdk` (search order in `SDKDiscovery.candidateRoots`: `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, `~/Library/Android/sdk`) |
| Engine | `emulator/emulator` v36.4.9 |
| adb | `platform-tools/adb`, also `/opt/homebrew/bin/adb` (`SDKDiscovery.fallbackADBPaths`) |
| Image | `system-images/android-36.1/google_apis_playstore/arm64-v8a` (`SystemImageRef.playStoreDefault`) |
| Emuu state | `~/.emuu` (`EmuuPaths`; override with `$EMUU_HOME`) |

**Never touch `~/.android/avd` or the user's existing `Medium_Phone` AVD.** Emuu instances live in
`~/.emuu/avd`, and every engine launch sets `ANDROID_AVD_HOME=<EmuuPaths.avdHome>`.

## Runtime picture

```
 ┌──────────── EmuuApp (SwiftUI) / emuu (CLI) ────────────┐
 │  instance list · install · play store · memory panel     │
 └───┬───────────────┬────────────────┬──────────────┬─────┘
     │               │                │              │
 EmuuEngine       EmuuADB         EmuuMemory      EmuuDisplay ── EmuuGRPC
 SDK locator      adb client      samplers        display session   h2c + HPACK client
 instance store   install (apk/   policy (pure    shm frames →      gRPC framing
 config.ini gen   xapk/apks/apkm) state machine)  IOSurface → CALayer EmulatorController
 launcher         packages        effectors       input/clipboard/   messages (hand-coded)
 console client   play store      maintenance     rotation, recorder shm_open (CEmuuShim)
     │  implements      │ implements      │ uses            │
     │  EngineControl   │ DeviceShell     │ both            │ gRPC 127.0.0.1:<port>, bearer token
     ▼                  ▼                 ▼                 ▼
 emulator -avd <id> -no-window -grpc <port> -grpc-use-token …   adb -s emulator-NNNN …
```

* The engine runs with `-no-window -grpc <port> -grpc-use-token`. Emuu reads the port and the engine's random
  token from the engine's discovery file and calls `EmulatorController.streamScreenshot` with the shared-memory
  transport: the engine writes RGBA frames from its **host-side** framebuffer into a POSIX shm region and sends
  ~100 bytes of metadata per frame, only when the screen changes. Emuu copies each frame once (vImage
  RGBA→BGRA) into a pooled IOSurface-backed `CVPixelBuffer` and sets it as a `CALayer`'s contents (zero-copy to the
  window server). Nothing runs in the guest, and secure (`FLAG_SECURE`) windows are visible, which guest-side
  capture (screencap, scrcpy) cannot do. Input (touch, keys, wheel) goes through one ordered `streamInputEvent`
  stream; clipboard and rotation are gRPC calls too. Details and measurements: docs/engine-findings.md.
* Emuu's modules talk to each other only through the `EmuuBase` protocols. `EmuuMemory` never
  imports `EmuuEngine` or `EmuuADB`. The app/CLI wires the concrete types together.

## Package layout

One SwiftPM package. `Package.swift` is at the repo root. It uses tools 6.0 and **Swift 6 language
mode** (strict concurrency). It targets macOS 14 on arm64.

| Target | Kind | Depends on | Owns |
| --- | --- | --- | --- |
| `EmuuBase` | library | – | models, protocols, ProcessRunner, logging, paths, clock |
| `EmuuTestSupport` | library | EmuuBase | fakes for tests (`FakeProcessRunner`, `FakeSpawnedProcess`, `FakeClock`, `FakeDeviceShell`, `FakeEngineControl`) |
| `EmuuEngine` | library | EmuuBase | SDK locator, instance store, AVD config generation, launcher/lifecycle, console client, `EngineControl` impl |
| `EmuuADB` | library | EmuuBase | adb client, `DeviceShell` impl, APK/split/XAPK/APKS/APKM install, package mgmt, Play Store helpers |
| `EmuuMemory` | library | EmuuBase | guest/host samplers, governor policy, effectors, maintenance, creep detection |
| `CEmuuShim` | C library | – | `shm_open` wrapper (variadic in C) |
| `EmuuGRPC` | library | EmuuBase, CEmuuShim | minimal gRPC/HTTP/2 (h2c) client with HPACK, protobuf wire codec, the `EmulatorController` messages Emuu uses (hand-written, no protoc), discovery-file reader, shared-memory region |
| `EmuuDisplay` | library | EmuuBase, EmuuGRPC | display session (frames, input, clipboard, rotation), frame converter, layer sink, H.264 recorder, input translation, NSView |
| `EmuuFarm` | library | EmuuBase, EmuuEngine | farm: golden records, pool state + leases (flock), capacity guard, port plan, pool controller, health probes, self-heal state machine, live driver |
| `emuu` | executable | all + swift-argument-parser | CLI |
| `EmuuApp` | executable | all | SwiftUI app |
| `Emuu<X>Tests` | test | `<X>` + EmuuTestSupport | one per library (swift-testing: `import Testing`) |
| `EmuuAppTests`, `emuuTests` | test | the executables (`@testable import`) | app/CLI pure logic (window geometry, single-instance policy, command parsing) |

Each library starts with a marker file (`Emuu<X>Module.swift`) and each test target with a
`moduleLinks` test. Module agents replace or extend these files.

### Rules for parallel module work

* Edit only your own `Sources/<Target>` and `Tests/<Target>Tests`. `EmuuBase` is shared. If a
  contract there is missing something, **add a new file** (additive only, do not change existing
  signatures) and say so in your report.
* Build and test only your own target, with your own scratch dir:
  `swift build --target EmuuADB --scratch-path .build-adb` and
  `swift test --filter EmuuADBTests --scratch-path .build-adb`.
* Shell out only through `ProcessRunner`. Use `SystemProcessRunner` in production and
  `FakeProcessRunner` in tests. Use `EmuuClock` for time, never `Date()` or `Task.sleep` directly in
  logic you want to test.
* Check emulator/adb behaviour against the binaries themselves (`emulator -help-all`,
  `adb help`, console `help`). Do not rely on memory.

## Contract reference (`Sources/EmuuBase`)

### Paths: `Paths/EmuuPaths.swift`

```
~/.emuu/
  avd/                 ANDROID_AVD_HOME   (<id>.ini + <id>.avd/)
  instances/<id>.json  persisted InstanceConfig (source of truth)
  run/<id>.pid         engine pid files, locks, sockets
  logs/emuu.log        app log (rotated emuu.1.log, emuu.2.log)
  logs/engine-<id>.log engine stdout/stderr
  cache/               derived/extracted data, safe to delete
  tools/               unused (the display installs nothing in the guest)
  screenshots/, recordings/  app screenshots / screen recordings
  config.json          global settings
```

* `EmuuPaths(root:)` builds the layout, `EmuuPaths.default(environment:home:)` gives the default,
  and `ensureDirectories()` creates every directory.
* Path helpers: `avdDirectory(for:)`, `avdIniFile(for:)`, `instanceConfigFile(for:)`,
  `engineLogFile(for:)`, `pidFile(for:)`.
* `SDKDiscovery.candidateRoots(environment:home:)`, `emulatorBinary(in:)`, `adbBinary(in:)` and
  `fallbackADBPaths` only define the search inputs. Validation belongs to EmuuEngine's locator.

### Processes: `Process/`

```swift
protocol ProcessRunner: Sendable {
  func run(_ request: ProcessRequest) async throws -> ProcessResult      // to completion
  func spawn(_ request: ProcessRequest) async throws -> any SpawnedProcess // long-running
}
```

* `ProcessRequest` holds `executable` (URL), `arguments`, `environment` (merged over the parent's
  unless `inheritEnvironment == false`), `workingDirectory`, `stdin: Data?`, `timeout: Duration?`
  (run only), and `stdout`/`stderr: OutputDisposition` (`.pipe`, `.discard` or `.file(URL)`, which
  appends).
* `run` returns a `ProcessResult` with `termination` (`.exited(code:)` or `.signaled(signal:)`),
  `stdout`, `stderr`, `duration`, `trimmedStdout` and `checked()`.
  * A non-zero exit is returned, not thrown. Call `.checked()` to turn it into
    `EmuuError.processFailed`.
  * On timeout the child gets SIGTERM, then SIGKILL 2 s later, and `run` throws
    `EmuuError.processTimedOut`.
  * If the calling task is cancelled, the child is terminated and `run` throws `CancellationError`.
  * If a grandchild keeps the pipe open (for example the adb server forking), output is collected
    for at most `pipeDrainGrace` (2 s) after exit, so `run` cannot hang.
  * stdin writes never raise SIGPIPE (`F_SETNOSIGPIPE`).
* `SpawnedProcess` provides `pid`, `stdoutLines`/`stderrLines` (single-consumer `AsyncStream<String>`
  that keeps only the newest 2000 lines, so memory stays bounded when nobody reads),
  `recentOutput()` (the last 200 lines, for crash reports), `termination`, `isRunning`,
  `waitForExit()`, `send(signal:)`, `terminate()`, `kill()`, `terminate(grace:clock:)`,
  `writeStdin` and `closeStdin`.
  * `send(signal:)` does nothing after exit, so a recycled pid is never signalled.
  * SIGSTOP and SIGCONT work on spawned children. The tests check this with `ps` state `T`.
  * For the engine, use `stdout: .file(paths.engineLogFile(for:))` unless you actually parse its
    output.
* `LineSplitter` is a reusable incremental line splitter (CRLF-aware, 64 KiB line cap).
* `ExecutableLocator.find(_:)` does a PATH lookup.

### Models: `Models/`

| Type | Notes |
| --- | --- |
| `InstanceID` | Also the AVD name. `[A-Za-z0-9._-]{1,64}` starting with an alphanumeric. `init?(rawValue:)`, `init(validating:) throws`, `sanitized(from:)`. |
| `SystemImageRef` | `apiDirectory/tag/abi`, `sdkRelativePath` (`image.sysdir.1` form, trailing `/`), `sdkManagerPackage`, `hasPlayStore`. `.playStoreDefault`. |
| `GPUMode` | Raw values are `-gpu` flag values: `auto host swiftshader_indirect angle_indirect guest`. |
| `MemoryProfile` | `frugal / balanced / performance`, with `suggestedRAMMB` (2048/3072/4096) and `suggestedVMHeapMB` (228/256/512). Governor thresholds per profile are defined in EmuuMemory. |
| `DisplaySpec` | width, height, density. Default `.lightweightPhone` is 720x1600 @ 320. |
| `InstancePorts` | `console` (even, 5554…5682), `adb = console+1`, `serial`, `portsArgument` (`"5554,5555"` for `-ports`). |
| `InstanceConfig` | id, displayName, systemImage, ramMB, cores, vmHeapMB, display, dataPartitionMB, ports? (nil means pick at launch), gpu, memoryProfile, audioOutput (the mic is always off), createdAt. `validate()` reports every bound that is violated. Codable. |
| `InstanceState` | `stopped booting running frozen hibernating hibernated stopping crashed(reason:)`, plus `isRunningEngine`. |
| `DeviceSerial` | `emulator-NNNN`, with `.emulator(consolePort:)` and `consolePort`. |
| `MemoryPressureLevel` | `normal < elevated < high < critical`. |
| `GuestMemory` | Bytes (meminfo kB × 1024): total/free/available/cached/buffers/swap, `pressureStall: PressureStall?` (PSI % avgs), `cachedProcessCount?`, `apps: [AppMemoryUsage]`. Derived: `availableFraction`, `usedBytes`, `swapUsedBytes`. |
| `HostMemory` | `engineFootprintBytes` (phys_footprint), `engineResidentBytes`, `systemPressure`, `physicalMemoryBytes`. |
| `MemorySample` | instanceID, `timestamp: Date` (for display), `monotonic: Duration` (for policy timing), guest?, host?. |
| `TrimMemoryLevel` | `am send-trim-memory` level names (AOSP). **Verify on device** with `adb shell am help`. |
| `GovernorTier` | `none, trim (T1), killBackground (T2), reclaim (T3), freeze (T4), hibernate (T5)`. |
| `GovernorAction` | `trimMemory(level:packages:)`, `trimCaches(desiredFreeBytes:)`, `killBackground(packages:)`, `reclaimGuestMemory(targetBytes:)`, `freeze`, `thaw`, `hibernate`, `resume`; `.tier`, `.isReversal`. |
| `EffectorOutcome` | `status: applied/noop/unsupported`, detail, reclaimedBytes?. |
| `GovernorEvent` | instanceID, timestamp, `kind`: `sampled`, `tierChanged`, `actionPlanned`, `actionApplied`, `actionFailed`, `creepDetected(bytesPerHour:window:)`, `stateChanged`, `maintenanceRan`. Codable. |
| `PackageInfo` | packageName, versionName/Code, label, isSystem, isEnabled, installerPackage, apkPaths, `isFromPlayStore`. |
| `InstallSource` | `.apk`, `.splitAPKs([URL])`, `.xapk`, `.apks`, `.apkm`, `.playStore(packageName:)`; `detect(fileURL:)`. |
| `InstallResult` | source, packageName?, `status` (`installed`, `openedInPlayStore`, `failed(code:message:)`), apkCount, obbCount, duration, `succeeded`. Package-manager failures are returned. Infrastructure failures are thrown. |
| `EmuuError` | The single error type at module boundaries (see the file for cases). It is `LocalizedError`. |

All sizes in contracts are **bytes (`UInt64`)**. Times are `Duration` (monotonic) or `Date` (wall).
`ByteCount` provides helpers and formatting.

### Cross-module protocols: `Contracts/`

```swift
protocol DeviceShell: Sendable {              // implemented by EmuuADB
  var serial: DeviceSerial { get }
  func shell(_ command: String, timeout: Duration?) async throws -> ProcessResult  // adb -s S shell <command>
  func adb(_ arguments: [String], timeout: Duration?) async throws -> ProcessResult // adb -s S <args>
}
// + shell(_:), shellOutput(_:) (checked, trimmed), getprop(_:), DeviceShellQuoting.quote/join

protocol EngineControl: Sendable {            // implemented by EmuuEngine
  var instanceID: InstanceID { get }
  func state() async -> InstanceState
  func enginePID() async -> Int32?            // the QEMU process that holds guest RAM
  func serial() async -> DeviceSerial?
  func freeze() async throws; func thaw() async throws            // T4, idempotent
  func saveSnapshot(named:) async throws; func loadSnapshot(named:) async throws
  func listSnapshots() async throws -> [String]
  func reclaimGuestMemory(targetBytes: UInt64?) async throws -> ReclaimOutcome  // T3; .unsupported(reason:) rather than throw
  func hibernate() async throws; func resume() async throws       // T5
  func stop(_ mode: EngineStopMode) async throws                  // .graceful(saveQuickBoot:) / .force
}

protocol MemoryEffector: Sendable {           // implemented by EmuuMemory
  func handles(_ action: GovernorAction) -> Bool
  func apply(_ action: GovernorAction) async throws -> EffectorOutcome
}
protocol GovernorEventSink: Sendable { func record(_ event: GovernorEvent) }   // + CompositeEventSink, RingBufferEventSink
protocol GovernorActivitySource: Sendable {   // provided by app/display: visibility + last input
  func isDisplayVisible(_ id: InstanceID) async -> Bool
  func lastUserInteraction(_ id: InstanceID) async -> Duration?   // monotonic
}

protocol EmuuClock: Sendable { now() -> Date; monotonicNow() -> Duration; sleep(for:) async throws }
// SystemClock (ContinuousClock, so it counts Mac sleep); FakeClock in EmuuTestSupport
```

Impossible requests (for example `freeze` while stopped) must throw
`EmuuError.invalidStateTransition(from:action:)`.

### Logging: `Logging/EmuuLogger.swift`

* Create a logger with `EmuuLogger(category: "engine")` and call `.debug/.info/.notice/.warning/.error`.
  Messages are autoclosures. Output always goes to unified logging, subsystem `dev.emuu`
  (`log stream --predicate 'subsystem == "dev.emuu"'`).
* Call `EmuuLogging.bootstrap(fileSink: LogFileSink(url: paths.mainLogFile), minimumFileLevel: .info)`
  once at startup in the app/CLI to also write to the file.
* Rotation: the file is capped at 4 MiB, with 3 files (`emuu.log`, `emuu.1.log`, `emuu.2.log`).
* Never log secrets.

### Test support (`EmuuTestSupport`)

* `FakeProcessRunner` checks rules newest-first:
  * `on(executable:arguments:respond:)`, `on(executable:argumentsPrefix:respond:)` and
    `on(predicate, respond:, delay:)` register rules.
  * Responses are `.success(stdout)`, `.failure(code, stderr:)`, `.error(EmuuError)` or
    `.handler { req in … }`.
  * A rule with several responses returns them in order, then repeats the last one.
  * `delay` combined with a shorter request timeout simulates `processTimedOut`.
  * `invocations` and `commandLines` record what ran.
  * `onSpawn` scripts `FakeSpawnedProcess`. Drive it with `emit(stdout:)`, `exit(code:)` and
    `finish(_:)`. `receivedSignals` records signals, and `exitsOnTerminate` controls whether it
    exits on SIGTERM.
* `FakeClock`: tasks call `sleep` and park until `advance(by:)` moves time past their deadline.
  Use `waitForSleepers(n)` to synchronise with a background loop. `setWallClock` changes only the
  wall clock.
* `FakeDeviceShell` scripts replies with `onShell(_:)`, `onShell(prefix:)`, `onShell(where:)` and
  `onADB(prefix:)`. Unmatched calls get exit 127 (or throw when `throwOnUnmatched` is set).
  `calls` and `shellCommands` record what ran.
* `FakeEngineControl` models the state machine. `failNext(_:with:)` injects a failure,
  `reclaimOutcome` sets the T3 result, and `calls` holds the call log.

## Memory governor design (EmuuMemory)

The governor is what sets Emuu apart. It has three layers:

1. **Samplers**
   * Guest: `/proc/meminfo`, `/proc/pressure/memory` (PSI), and occasional, cheap per-app `dumpsys`,
     all through `DeviceShell`.
   * Host: engine `phys_footprint`/RSS via `proc_pid_rusage(enginePID)`, and the system pressure
     level via `DispatchSource.makeMemoryPressureSource`.
   * Samplers produce `MemorySample`s.
2. **Policy** is a pure, synchronous, unit-tested state machine.
   * Input: `(state, sample, activity, now: monotonic) -> (state', [GovernorAction])`.
   * It has hysteresis (separate enter and exit thresholds per tier), a cooldown per action, and
     escalates one tier at a time.
   * It reverses an action (`thaw`/`resume`) when the instance becomes visible or the user
     interacts with it.
   * Thresholds depend on `MemoryProfile`.
   * Two levels: the **guest** level (MemAvailable, PSI) is the only input of the guest-side tiers T1–T3; the
     **host** level (macOS pressure, engine footprint) only shortens the way to freeze/hibernate for a hidden,
     idle instance. Guest-side actions wait out a grace period after boot/resume and never run while sign-in,
     the Play Store or a package installer is in the foreground.
   * It performs no I/O.
3. **Effectors** (`MemoryEffector`) map each action to adb commands (`DeviceShell`) or engine
   calls (`EngineControl`).

Tiers:

| Tier | Action | Mechanism (to verify empirically) |
| --- | --- | --- |
| T1 | trim | `am send-trim-memory <pkg> <LEVEL>` for background apps; `pm trim-caches <bytes>` |
| T2 | kill background | `am kill-all` (cached/background only) or `am kill <pkg>` |
| T3 | reclaim to host | virtio-balloon or whatever this engine really supports. **Investigate; do not assume.** Report `.unsupported` if nothing works. |
| T4 | freeze | console `avd stop`/`avd start`, or SIGSTOP/SIGCONT on the engine pid. Choose the one that keeps adb sane after resume. |
| T5 | hibernate | snapshot save + quit; resume via quick-boot snapshot |

Long-run hygiene:

* Periodic maintenance runs while idle (`pm trim-caches`, `logcat -c`, dropping the guest page
  cache where allowed).
* Creep detection fits a linear regression over a window of engine footprint samples and emits
  `creepDetected`.
* All in-memory histories are ring buffers, so Emuu itself never grows.

AVD tuning (EmuuEngine config generation):

* RAM, `vm.heapSize` and cores come from the profile.
* `hw.audioInput=no`; audio output follows the config.
* No boot animation (`-no-boot-anim`).
* Turn off sensors and devices that are not needed (check each key against the engine's
  `hardware-properties.ini` / `-help-all`).
* Quick-boot snapshots stay on so resume is instant.

## App, display and automation notes

* **Windows.** Emulator windows are plain `NSWindow`s owned by `InstanceWindowController` (an
  `NSHostingView` with the screen and the control strip). SwiftUI's `WindowGroup` kept closed windows and their
  `InstanceSession` alive; the controller releases everything on close. Only the library and Settings are
  SwiftUI scenes. Menu commands act on `AppModel.activeSession` (the key emulator window).
* **Window closes with the engine.** A shutdown or hibernation closes the instance's window
  (`WindowAutoClosePolicy`, pure and unit-tested; there is no lasting "Stopped"/"Hibernated" placeholder, the
  library resumes the instance). `InstanceSession` decides on each engine state change: a stop/hibernate run in
  this process (window, library, governor) passes through `.stopping`/`.hibernating` and closes at once; an engine
  that vanishes from outside (CLI, supervisor, `adb emu kill`, guest power-off) is confirmed after 4 s with
  `EngineInstance.refresh()` — a new engine (hard/cold restart, heal, self-heal) keeps the window and reconnects
  it, a live CLI supervisor reporting `booting`/`stopping`/`hibernating` is asked again — and only then closes.
  Never closed for: crashes (the window shows the error), failed starts (session never reached `.ready`), the
  app's own Restart Engine / Retry / resume, guest reboots and freeze/thaw (the engine never stops).
  `AppModel.engineEnded` removes the session from `sessions` *before* `NSWindow.close()` (works minimised or on
  another Space), so `windowClosed` does not apply the window-close choice again, then `detach()` tears down the
  display, gRPC streams and governor and finalises a recording. A CLI supervisor is told `visibility: false` (before
  a window-initiated hibernate and on the close), otherwise its governor would resume the instance at once because
  a display is "visible". Engine 36.4.9 reports Android powering off as a SIGKILL "crash" (it saves, hangs 20 s and
  kills itself); the session recognises it from the engine log ("… to shutdown gracefully before kill" since the
  last `emuu launch` header) and closes as for a stop. Library Shut Down / Hibernate close the window the same way.
* **Single instance.** `EmuuLauncher` (the `@main`) takes `~/.emuu/run/app.lock` (`flock`) before AppKit starts;
  a second process posts a distributed notification to the holder (activate + forwarded files) and exits 0.
* **Icons.** `Sources/EmuuApp/Resources/Icons/*.svg`, SwiftPM resource bundle `Emuu_EmuuApp.bundle`, loaded by
  `IconLibrary` from `Contents/Resources` (app) or next to the executable (`swift build`) — not via
  `Bundle.module`, which traps when the bundle is in `Contents/Resources`.
* **Display lifecycle.** `EmulatorDisplayController` closes the frame stream 1 s after the window is hidden or
  minimised and reopens it when shown (the current frame arrives within ~0.15 s); there is no frame-rate switching.
  A failed stream (engine hibernated/restarted) reconnects with backoff while visible, re-reading the endpoint
  (new pid → new port and token). An engine adopted from an older Emuu (no `-grpc`) shows "Restart Engine"
  (hibernate + resume, state kept).
* **Recording.** `FrameRecorder` (EmuuDisplay) is a `DisplayFrameSink` teed next to the layer sink. It encodes the
  frames with `AVAssetWriter` (VideoToolbox H.264) only while recording, timestamps by arrival (a static screen
  gives few frames but a correctly timed file; the last frame is repeated at the stop time), starts a new segment
  file when the frame size changes (rotation) and always finalizes. While recording the frame stream stays open
  and `DisplayActivityTracker` reports the instance as visible to the governor.
* **Shared-memory frames are validated.** With `ImageTransport.MMAP` the engine has one region per stream and no
  lock or sequence word; under host load the engine was seen writing into the region (bottom row first) while Emuu
  read it, a few ms after sending the metadata, so Emuu read half-written frames (torn: an older band at the top, see
  docs/evidence/flicker-*.png). `FrameConverter.convertStable` converts the region into the output buffer and then
  compares the output with the region (channel-swapped, one pass, seqlock-style); a difference means a write
  overlapped the read, so it re-reads (up to 3 times) or drops the frame. Counters: `DisplayStats.racedFrames` /
  `unstableFrames`. Cost ≈ +0.5 ms per 720x1600 frame and ≈ +3.5 % of one core at 60 fps. It cannot detect an engine
  writer that was paused mid-frame for the whole read-and-compare. `EMUU_DISPLAY_SHM_VALIDATE=0` turns it off
  (diagnostics only).
* **Keyboard and text input** (`EmuuDisplay/Input/KeyMapping.swift`, `TypingSequencer.swift`,
  `View/EmulatorDisplayView+TextInput.swift`; README "Typing"). The device view is an `NSTextInputClient`.
  * *Route* (`KeyEventTranslator.route`): while an input method composes, every key goes to macOS text input;
    otherwise ⌘ chords are the view's or the menus' (`commandAction`), Shift/Control are forwarded as held
    modifiers, ⌃ chords and non-character keys (arrows, Return, Tab, ⌫, ⌦, Esc, Home/End/Page Up/Down) go
    **by key**, and everything else goes through `interpretKeyEvents`, so the layout, dead keys, press-and-hold,
    the emoji picker and input methods produce the **text**.
  * *Text → guest* (`typed`): each character Android's US key map can type becomes that key (+ Shift adjusted
    around it, the user's held Shift lifted if needed); a single character from a key is held while the Mac key is
    held. Anything else (é, 中文, emoji) and any single text longer than 64 characters is **pasted**: guest
    clipboard set, Ctrl+V, previous guest clipboard restored after 0.6 s of quiet. ⌘V pastes the Mac clipboard the
    same way and leaves it in the guest clipboard; ⌘C/⌘X send Ctrl+C/Ctrl+X and the clipboard stream copies the
    result to the Mac.
  * *Keys on the wire* are evdev codes (`KeyboardEvent.codeType = Evdev`). The engine's Mac key codes drop the A key
    (kVK 0 = protobuf default) and the engine auto-repeats a held Mac key; the `text`/`key` fields mangle non-ASCII and
    are not ordered with key codes. The guest keyboard is `qwerty2.kl` (phone layout): KEY_HOME is the HOME button,
    KEY_END is ENDCALL (sleep), F-keys are MENU/CALL/ENDCALL or nothing, Page Up/Down and the keypad are unknown, the
    grave key is 399 — so Home/End/Page keys are sent as Android's Alt+←/→/↑/↓ movements and F-keys are not sent.
  * *Ordering and pacing* (`TypingSequencer`, every input event of the view goes through it): key-downs at least 5 ms
    apart in bursts (back-to-back presses were dropped), pastes wait 250 ms after the previous Ctrl+V before
    changing the clipboard (Android reads it when it handles the key), and keys that Gboard handles (characters) vs
    keys that go straight to the app (arrows, chords, Return, BACK) are separated by 80 ms, with ⌫ waiting for both
    — otherwise either path overtakes the other. A lone Shift tap is inserted before an app key when the field's
    Shift is "sticky" (a Shift press whose letter Gboard took looks like a lone tap to `MetaKeyKeyListener`, and
    the next ← would select).
  * *Key-up bookkeeping*: the translator knows every key it holds in the guest; key-up releases it, ⌘ going down
    releases held characters (macOS sends no key-up under ⌘), focus loss / window resigning key / app deactivation
    release everything, and Shift/Control are reconciled with the event's flags on every key.
  * *Focus*: a click, the window becoming key or opening it makes the view first responder (unless a text field
    has focus); strip buttons are not focusable.
  * *Soft keyboard*: the view reports the start of Mac typing (`onMacTyping`); `InstanceSession` checks
    `dumpsys input_method` and sends BACK on the input stream only if no click or Return/Tab/Esc happened since
    (`hideSoftKeyboardIfFocusUnchanged`). Gboard ignores `show_ime_with_hard_keyboard` for the emulator's built-in
    keyboard, and `accessibility_soft_keyboard_mode` is reset by the system at once (both measured).
  * Self-test: `EMUU_APP_SELFTEST=cycle:<id>:1 EMUU_APP_SELFTEST_ONLY=keyboard` with scripts/typing-test-apk
    installed drives the view with synthesized events and checks the device's text and pressed-key state.
* **Rotation.** `setPhysicalModel(ROTATION)` turns the virtual device (sensors), with Android's auto-rotate set on
  attach; frames arrive rotated, the window re-aspects, and touches are mapped back to physical panel coordinates
  (`DeviceTouchMapper`). Portrait-locked apps (the phone launcher) appear sideways, as on a real phone.
* **Automation mode** is `GovernorConfig.automationMode` (policy: no T4/T5, pressure tiers capped at T2),
  stored as `InstanceConfig.automationMode`. `GuestEffector` always excludes packages with running
  instrumentation (`InstrumentationProbe`). `ADBActivityDetector` turns other tools' adb traffic (extra adbd
  children, guest pid rate) into "user activity".

### Diagnosing display artefacts

Tools (all off by default) for "the window flickers / tears / shows black frames":

* **`emuu debug display-probe <instance> [--duration 60] [--save DIR] [--csv FILE]`** (hidden command) opens the
  same frame stream the window uses (same session, transport and converter) and analyses every frame
  (`Sources/EmuuDisplay/Diagnostics/FrameAnalyzer.swift`). Generic checks, for any content (e.g. TikTok):
  **blank** (≥ 97 % black after a non-black frame), **green** (mostly pure green), **flash** (a frame unlike both
  neighbours while they match each other: A-B-A), arrival gaps and late frames, engine→Emuu latency, read+convert
  time. With the test pattern on screen it also reads a frame counter in five places: **torn** (two counters, each
  in ≥ 2 markers), **out-of-order**, **pattern-lost**, duplicates and skipped counters. `--no-validate` reads the
  shared memory the pre-fix way; `--transport inline` / `--compare-inline` add the engine's inline (atomic) frames
  as ground truth (the same artefact in both = produced by the engine, only in mmap = Emuu's read);
  `--tap-latency N` measures tap → first changed frame (turn on pointer location first:
  `adb shell settings put system pointer_location 1`). PNGs of offending frames go to `--save`.
* **`EMUU_DISPLAY_DIAG=1`** for the app (`EMUU_DISPLAY_DIAG=1 open -n dist/Emuu.app` does not pass the variable;
  quit Emuu and run `EMUU_DISPLAY_DIAG=1 dist/Emuu.app/Contents/MacOS/Emuu` from a terminal instead) or `emuu start --window`: the window analyses
  every frame it **presents** and logs a `display.diag` line every 10 s to `~/.emuu/logs/emuu.log` (presented,
  coalesced, artefact counts, shared-memory races); offending frames are saved under `~/.emuu/logs/display-diag/`
  (any other value is used as the directory). The stream then also stays open while the window is covered.
* **Test content:** `scripts/flicker-test/` — `make-pattern-video.swift` (H.264/HEVC/VP9 via ffmpeg; `noise` for
  realistic decoder load), the test APK in `apk/` (`VideoActivity`: MediaPlayer in a SurfaceView or TextureView,
  full screen or in-feed, with animated UI over it; `GLActivity`: 60 fps GL pattern, `--ez upload true` for a
  per-frame texture upload) and `run-scenarios.sh` (plays each scenario and runs the probe).
  `CodecActivity` drives MediaCodec the way a short-video feed player does (TikTok's TTVideoEngine, from the
  user's logcat): asynchronous MediaCodec straight to a Surface, `KEY_PRIORITY` 0, `flush()` right after
  `start()` (with the codec-specific data resubmitted), looping by `flush()` + seek on the same codec
  (`loopAfter`), swipes that create the next codec while the previous one is released on another thread
  (`swipe`, `async`), pre-warming on an off-screen surface then `setOutputSurface()` (`placeholder`,
  `pingpong`), hidden concurrent decoders (`preload`) and decoding into the app's own GL pipeline (`out gl`:
  SurfaceTexture + `samplerExternalOES`). Scenarios with an `EmuuCodec` log line per codec event.
* **Green video** (a video area of solid ≈ (0, 135, 0) under intact UI) is a decoded frame whose YUV planes
  were never written (Y = U = V = 0). It comes from the decode path, not Emuu's frame reading. The probe's
  `green` check counts it when ≥ 25 % of the screen has that colour (G ≥ 60, R and B < 40). First check which
  codec the guest uses (`c2.goldfish.*` = host decoding, `c2.android.*` = guest software) and switch with
  `emuu video-decoder` (next section).

### Video decoder setting (`InstanceConfig.videoDecoder`, `emuu video-decoder`)

```
 setting (instance JSON, nil = auto) ─┐                  ┌─ software:      -feature -HardwareDecoder → guest c2.android.*
 EMUU_VIDEO_DECODER (overrides all) ──┼─ effective mode ─┼─ hardware:      engine default, c2.goldfish.* → host VideoToolbox
                                      │   (auto→software) └─ host-software: c2.goldfish.* → host ffmpeg (ANDROID_EMU_MEDIA_DECODER_VTB=0)
 <avd>/emuu-guest-codecs (host|guest) ┴─ EngineInstance.videoDecoderPlan → cold boot once if the snapshot's codecs differ
```

* The guest registers its codecs once, at boot, from the kernel command line
  (`androidboot.qemu.hwcodec.{avc,hevc,vpx}dec=2` when the engine feature `HardwareDecoder` is on). A quick-boot
  snapshot therefore keeps the codec set it was saved with, whatever the next launch passes. Every launch writes
  the codec set to `<avd>/emuu-guest-codecs`; a snapshot without the file predates the setting and has host
  codecs. When the snapshot's set differs from the wanted one, the launch adds `-no-snapshot-load` (one cold boot;
  the next save matches). Farm clones never save, so they keep the golden's set instead and log that the golden
  should be re-sealed. `hardware` ↔ `host-software` needs no cold boot (same guest codecs; the variable is read
  when the host creates a decoder).
* `EngineInstance` re-reads the stored setting at every launch, so a change from the app's picker (memory HUD) or
  the CLI applies at the next start/resume without recreating the controller.


## Automation farm and self-healing (EmuuFarm, `emuu golden|clone|farm|run|health|heal|reboot`)

```
 emuu farm acquire/release/heartbeat/status ─┐            emuu run ──┬─ lease from a pool, or
                                             │  flock      (holder =  └─ ephemeral clone (farm/ephemeral/<id>.json)
                       farm/pools/<p>/state.json ◄──────── runner pid)
                                             │
 emuu farm daemon (one per pool, daemon.lock) └─ PoolController.tick() every 0.5 s
     ├─ LeaseBook.expire (TTL / holder pid)            ├─ CapacityGuard (RAM, cores, ports, live pressure)
     ├─ provision: InstanceStore.clone(golden, includeSnapshots) → EngineInstance.start (quick boot) → settle check
     ├─ reset: console `avd snapshot load default_boot` → settle check;  recycle: kill -9 + re-clone + resume
     └─ health (HealthProber) → SelfHealState → thaw / reconnect-adb / reset / replace;  leased: --heal-leased
```

* **Golden image** = an ordinary instance whose quick-boot snapshot was saved by `golden seal` after the farm
  settings and ≥ 120 s of uptime; `farm/goldens/<name>.json` records its guest boot id, RAM, cores, image.
* **Clone** (`InstanceStore.clone(includeSnapshots: true)`): `clonefile(2)` of every AVD file except per-launch
  artifacts, the source's `config.ini` kept (the engine rewrites it on first boot, e.g. the 6 GiB userdata size)
  with only `AvdId`/display name changed, and each `snapshots/*/hardware.ini` rewritten (AVD paths, `avd.name`,
  `avd.id`): without that the engine refuses the snapshot ("hardware cannot load snapshot") and cold-boots.
  `snapshot.pb` still names the golden's disks; the engine does not check them. Farm clones set
  `discardStateOnExit` (`-no-snapshot-save`), `guestRAMEnforced` (`-qemu -m <MB>`, below the engine's 2048 MB
  floor), fixed `ports`, `automationMode`.
* **Engine `-read-only`** (several engines on one AVD) was measured and rejected: same resume time and
  footprint, but each engine rewrote files in the golden's directory (`userdata-qemu.img.qcow2` mtime/size,
  `hardware-qemu.ini`, `emu-launch-params.txt`) and a SIGKILLed engine left its temporary overlays in
  `/tmp/android-<user>/`. Clones keep the golden immutable and clean up with the clone directory.
* **Leases** (`LeaseBook`, pure, on `FarmState`): acquire takes the longest-idle ready device that passes a
  fresh health check (frozen ones are SIGCONTed first); release → `resetting`; TTL and holder-pid expiry;
  `device_lost` for leased devices that fail two checks. All mutation happens in `FarmStateStore.update` under an
  exclusive `flock`, so concurrent `acquire` processes never share a device (unit test: 40 threads, 12 devices).
* **Ports**: console 5554–5584 only (adb's scan range, 16 devices); allocation skips bound ports (any emulator)
  and ports planned for other pools or ephemeral runs; `emuu run` allocates under `farm/ports.lock`.
* **Capacity** (`CapacityGuard`, pure): ceiling = min(memory, CPU, ports); memory = (RAM − max(8 GiB, 40 %)) ÷
  (guest RAM + 850 MiB); admission of one more device also needs macOS pressure normal and enough available
  memory (`kern.memorystatus_level`). `emuu doctor` and `emuu farm capacity` print it.
* **Health** (`HealthProber` → `HealthFacts` → `HealthEvaluator`, pure): process/SIGSTOP (Emuu's own freeze is
  marked by `run/<id>.frozen`), console ping, `adb get-state`, one shell round trip (boot_completed, boot_id,
  uptime, /data free), a system_server binder call, optional UI focus (ANR dialogs). A crash seen by any Emuu
  process leaves `run/<id>.crashed` so a later `emuu health` still says `dead`. Farm devices compare the boot id
  with the golden's (every clone resumes the golden's running kernel, so a different id means a guest reboot).
* **Self-heal** (`SelfHealState`, pure): confirmations (2, dead: 1), exponential backoff (20 s doubling, max
  10 min), circuit breaker (3 attempts / 30 min → failed). Ladders per fault (`HealLadder`); interactive
  instances never restart automatically for informational faults (ANR dialog, disk full, completed reboot).
  The supervisor runs it with `--self-heal`; `emuu heal` runs one ladder pass; the pool daemon for its devices.

## Instance-to-instance clone (`emuu clone-instance`, library "Clone…")

Copies an ordinary instance (Google sign-in, apps, settings) into a new one with the farm's machinery; pure logic in
`Sources/EmuuFarm/InstanceClone.swift`, CLI in `Sources/emuu/Commands/CloneInstanceCommand.swift`, app in
`Sources/EmuuApp/Model/AppModel+Clone.swift` + `Views/CloneInstanceSheet.swift`.

* **Copy** = `InstanceCloner.clone` → `InstanceStore.clone(includeSnapshots:)` (clonefile of the AVD minus per-launch
  files, the source's engine-written `config.ini` kept with `AvdId`/display name changed, each snapshot
  `hardware.ini` rewritten). Then `sharedFiles` checks that no file of the clone is the same inode as (or a symlink
  into) the source; the clone is deleted if one is. The qcow2 overlays name their backing files relatively
  (`userdata-qemu.img`, verified with `qemu-img info`), so a clone never reads the source's directory. The clone's
  record drops `goldenSource`/`discardStateOnExit`. A stub `default_boot` (`ram.bin` < 16 MiB) is not carried.
* **Snapshot carried by default:** measured on the same source, the clone with the snapshot was adb-ready in 2.35 s
  (engine: "Successfully loaded snapshot 'default_boot'", same guest boot id and uptime as the source at the save);
  without it (`--cold-boot`) a cold boot took 10.7 s. Both had every marker. If the engine ever refuses the
  snapshot it cold-boots from the same disks, so carrying it is never worse.
* **Source state** (`CloneSourcePlan.decide`, pure): stopped/hibernated → copy now; running/frozen → refuse unless
  the user consented (`--stop-source` / the sheet's "Hibernate, Clone & Resume"), then hibernate → copy → resume
  (re-freeze if it was frozen); booting/stopping/hibernating/crashed → refuse; governed by another front end that
  this caller cannot route through → refuse. Why hibernate: a running engine holds the qcow2 files open with
  metadata cached in QEMU and guest data in RAM, and the engine has no "flush and keep running" for its disks; the
  quick-boot save on console `kill` is its own consistent point (VM paused, RAM + devices saved, disk state as a
  qcow2 internal snapshot, files closed), and resuming from it keeps the source's apps running. The CLI routes
  hibernate/resume through `EngineCommand.perform` (supervisor if one runs); the app through `AppModel.finish(.hibernate)`
  and `openWindow` (or the engine directly when no session is attached), and resumes even if the copy failed.
* **Ports** (`ClonePorts.choose`): `--port` must be in 5554–5584, not fixed for another instance, and free; a
  source with fixed ports gives the clone its own fixed port (`FarmPorts.allocate`, skipping ports other records
  fix); otherwise nil like the source (picked at each launch). gRPC port and token are per launch anyway.
* **Naming** (`CloneNaming`): the app proposes "<name> copy" (then "… 2"), the id is the sanitized name made unique
  with "-2", "-3"; the CLI takes an explicit id and refuses a taken or invalid one.
* **Identity:** Android ID, GSF id and account tokens are on the data partition and are copied unchanged; Emuu does
  not touch them (README "Cloning an instance").
* **App self-test:** `EMUU_APP_CLONETEST=<source>:<new name>` (`CloneSelfTest.swift`) opens the source, renders the
  sheet, runs `cloneInstance`, waits for the source to stream again, hibernates it and quits.

## Security and safety

* Emuu never modifies `~/.android`. The only exception is adb's own key files, which adb manages.
* Emuu never roots the Play Store image and never bypasses Play certification.
* Files the user installs (XAPK and similar) are extracted into `~/.emuu/cache` and removed after
  install.
