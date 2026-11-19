# Emuu

Emuu is a lightweight Android emulator for Apple Silicon Macs, built for sessions that stay up for hours or
days. You can install APKs and games (including split APKs, XAPK with OBB data, APKS and APKM) and use the
Google Play Store.

It comes as a command-line tool (`emuu`) and a SwiftUI app (`Emuu.app`, built with `scripts/make-app.sh`).

## What it is, and what it is not

Emuu does **not** include its own virtual machine. It runs the **Android Emulator engine** from Google's
Android SDK (QEMU + Hypervisor.framework + gfxstream) **headless**, and adds the parts that make it light and
steady over long sessions:

* **No Qt emulator window.** The screen is the engine's own framebuffer, read through its gRPC service (the
  same mechanism as Android Studio's embedded emulator): frames arrive in shared memory only when the screen
  changes and go to the window with no decode and no copy beyond one pixel-format conversion. Nothing is
  installed in the guest, and secure screens (password fields, Play purchase sheets, banking apps) are shown,
  not blacked out. Without a window the engine runs fully headless.
* **A memory governor** that watches the guest and the Mac and steps in through escalating tiers, from asking
  apps to trim up to hibernating the whole VM. See [Memory governor](#memory-governor) below.
* **Tuned instances.** Emuu creates its own AVDs: no boot animation, no microphone, unused sensors and
  cameras off, a smaller default screen (720x1600), and quick-boot snapshots kept for 2-second resumes.

Honest limits:

* **Apple Silicon only** (arm64 macOS 14 or later). Images are arm64; x86-only apps will not install.
* **Requires the Android SDK** with the `emulator` and `platform-tools` packages, plus a **Google Play system
  image**: `system-images;android-36.1;google_apis_playstore;arm64-v8a`. Android Studio installs all of these.
  Emuu does not download or repackage Google software.
* **The Play Store works only on `google_apis_playstore` images**, the Google-certified ones. These images
  are not rooted, and Emuu never roots them or bypasses Play certification. Some apps (banking, a few games
  with strict integrity checks) still refuse to run on any emulator.
* **The memory cost is real.** On engine 36.4.9 a 2 GB guest costs about **4.3–4.5 GiB** of Mac memory
  (Activity Monitor "Memory", including compressed pages). The engine also raises guest RAM to at least
  2048 MB for the android-36.1 image, so the `lite` preset's 1536 MB becomes 2048 MB in practice.
* **Memory cannot be handed back from a running guest.** This image's kernel has no virtio-balloon driver,
  so the governor's "reclaim" tier reports `unsupported`. The way to get memory back is **hibernate**: it
  saves the VM and quits in about 2 s, frees everything, and resumes in about 2 s.
* The display carries no audio (sound is the engine's own audio output; `create --no-audio` turns it off), and
  there is no camera.
* Typing non-ASCII characters (é, ü, emoji) from the Mac keyboard does not reach Android (the engine's key
  injection handles printable ASCII); paste them with ⌘V instead.

Emuu keeps its state in `~/.emuu` (or `$EMUU_HOME`) and never touches `~/.android/avd` or your other AVDs.

## Install

```sh
git clone <this repo> emuu && cd emuu
scripts/install.sh          # release build → ~/.local/bin/emuu  (PREFIX=… to change)
emuu doctor                 # checks the host, SDK, engine, Play Store image and adb; prints fix commands
```

If `emuu doctor` reports a missing piece, it prints the command that fixes it, for example:

```sh
~/Library/Android/sdk/cmdline-tools/latest/bin/sdkmanager "system-images;android-36.1;google_apis_playstore;arm64-v8a"
```

## Quick start

```sh
emuu create phone                     # Play Store image, 2 GB, 4 cores, balanced governor
emuu start phone --window             # boot it with a display window (Ctrl-C saves and stops)
#   or headless in the background:
emuu start phone --detach

emuu playstore --sign-in              # opens Google sign-in on the device (you need a screen: --window or the app)
emuu playstore com.spotify.music      # opens the store listing; tap Install on the device

emuu install app.apk game.xapk ./split-dir/   # APK, split APKs (directory), XAPK (+OBB), APKS, APKM
emuu apps                             # installed user apps
emuu launch com.example.game
emuu screenshot shot.png

emuu status                           # state + one memory line
emuu mem                              # live governor view (samples, tier changes, actions)
emuu hibernate                        # free all host memory; `emuu resume` in ~2 s
emuu stop                             # quick-boot snapshot saved; the next start takes ~2 s
```

With exactly one instance you can leave out the name. Otherwise use `-i <name>`, a positional name, or set
`EMUU_INSTANCE`.

### Commands

| Command | What it does |
| --- | --- |
| `doctor` | Host, SDK, engine, Play Store image and adb checks, with fix commands (`--json`). |
| `create <name>` | New instance. `--preset standard\|lite\|gaming`; overrides: `--ram`, `--cores`, `--screen 1080x2400@420`, `--gpu`, `--no-audio`, `--port` (console port 5554–5584: adb only finds emulators there), `--profile`, `--video-decoder`. |
| `list`, `delete <name>` | List instances; delete one with all its data (`-y` to skip the prompt). |
| `start` | Boot and supervise. `--headless` (default) or `--window`; `--detach`; `--profile lite\|balanced\|performance`; `--cold-boot`; `--no-governor`; `--idle-freeze <min>`; `--automation`; `--video-decoder <mode>` (saved). |
| `stop`, `freeze`, `thaw`, `hibernate`, `resume` | Lifecycle. These go through the supervisor when one runs. `stop --no-snapshot` cold-boots next time; `stop --force` sends SIGKILL. |
| `status` | State, pids and a memory line (`--all`, `--json`). |
| `install <paths…>` | `.apk`, split sets (a directory with `base.apk` + `split_*.apk`, or `--split`), `.xapk` with OBB, `.apks`, `.apkm`. |
| `apps`, `launch`, `uninstall` | App management (`apps --system`, `uninstall --keep-data`). |
| `playstore [pkg]` | Store and account status; opens the store, a listing (`pkg`), a search (`--search`) or sign-in (`--sign-in`). |
| `screenshot <out.png>` | PNG of the device screen, from the engine's framebuffer (secure screens included; `adb screencap` fallback). |
| `record [<name>] <out.mp4>` | Screen recording to MP4 (hardware H.264 from the engine's framebuffer, secure screens included). `--duration <s>`; Ctrl-C stops. A rotation continues in `<out>-2.mp4`. |
| `rotate [<name>] [portrait\|landscape\|left\|right]` | Turns the device (its orientation sensors); no argument toggles portrait ↔ landscape. |
| `keyboard on\|off\|status [<name>]` | Android's on-screen keyboard (saved per instance; same as the app's Keyboard button). |
| `automation on\|off\|status [<name>]` | Automation mode for tests/scripts over adb (see [adb and automation](#adb-and-automation)). |
| `video-decoder auto\|software\|hardware\|host-software\|status [<name>]` | Where guest video is decoded (saved per instance; see [Video decoding](#video-decoding)). |
| `shell [-- cmd…]` | `adb shell` on the instance (interactive without a command). |
| `logs` | Engine log (default), `--supervisor`, `--app`, or `--samples` (the governor's CSV); `-f` follows. |
| `mem` | Live governor view (`--json`, `--once`, `--apps` for a per-app breakdown). `mem trim [--kill] [--level …]`, `mem reclaim`. |
| `bench` | Cold boot, hibernate and resume times, plus idle footprint with and without the governor, as a Markdown table. |
| `health`, `heal`, `reboot` | Health check, automatic recovery, soft/hard/cold reboot (see [Self-healing](#self-healing)). |
| `clone-instance <source> <name>` | Copy an instance with everything on it, Google sign-in included (see [Cloning an instance](#cloning-an-instance)). `--stop-source`, `--cold-boot`, `--port`, `--display-name`, `--json`. |
| `golden`, `clone`, `farm`, `run` | Automation farm (see [Automation farm](#automation-farm)). |

Device commands wake the instance first: a frozen engine is thawed and a hibernated one resumed.

## The app

```sh
scripts/make-app.sh          # release build → dist/Emuu.app (ad-hoc signed)
open dist/Emuu.app
```

The library window lists your instances; **Open** boots one (or attaches to one that is already running) in
its own window. Only one Emuu app runs at a time: launching it again (Finder, `open -n`, or running
`Emuu.app/Contents/MacOS/Emuu` directly) brings the running app forward, hands it any `.apk` files given on
the command line and exits. All emulator windows live in that one process (one Dock icon).

An emulator window is the device screen plus a **control strip** on its right edge. The strip is always
visible (if the window is short it scrolls), every button has a tooltip:

| Group | Buttons |
| --- | --- |
| Navigation | Back, Home, Recent apps |
| Device | Rotate, Volume up, Volume down, **Keyboard** (on-screen keyboard on/off, saved per instance) |
| Capture | **Screenshot** (clipboard + `~/.emuu/screenshots`), **Record** (red with elapsed time while recording; MP4 in `~/.emuu/recordings`, "Show in Finder" when done) |
| Apps | Install APK…, Play Store, Installed apps |
| Memory | Guest memory use coloured by pressure; opens the memory HUD (profile, automation mode, freeze/hibernate settings, actions) |

The title bar shows the instance name and its adb serial; click the serial to copy it. Drop
`.apk`/`.xapk`/`.apks`/`.apkm` files anywhere on the window, the device screen included, to install them. The
Device menu has the same actions with shortcuts (⌘B back, ⇧⌘H home, ⌘R rotate, ⌘↑/⌘↓ volume, ⌘K keyboard,
⇧⌘S screenshot, ⌥⌘R record, ⌥⌘C copy serial).

A minimised or fully covered window closes the frame stream after 1 s and the governor treats it as hidden;
showing it again reopens it and the current frame is back in about 0.15 s. A static screen costs nothing even
while visible: the engine only sends frames when something changes. While a recording runs the stream stays up
whatever the window does, and the instance counts as in use (no freeze, no hibernate).

**The window closes when the phone shuts down or hibernates.** Powering off from inside Android, `emuu stop`,
`adb emu kill`, Shut Down / Hibernate in the library, the window's Hibernate, and a hibernation by the memory
governor or a CLI supervisor (also while the window is minimised or on another Space) all close the instance's
window; a recording in progress is saved first. The library then shows the instance as Stopped or Hibernated, and
opening it starts or resumes it (about 2 s from hibernation). The window stays open for a guest reboot
(`emuu reboot`, a soft reboot), an engine restart (`emuu reboot --hard|--cold`, `emuu heal`, self-healing,
Restart Engine — the window reconnects to the new engine), freeze/thaw, a crash (the window shows the error with
Retry and Cold Boot) and a start that fails. When the engine is stopped by another process the window waits about
4 s to see whether a new engine comes up before it closes.

**Rotate** (button, ⌘R, `emuu rotate`) turns the virtual device itself, like turning a phone: Android's
auto-rotate is switched on, apps that support landscape (Settings, Chrome, the Play Store, games) re-lay out, and
the window re-shapes. Apps locked to portrait — the phone home screen among them — stay portrait and appear
sideways, exactly as on a real phone; Emuu does not force them (that would letterbox landscape games the other
way round).

**Updating from a scrcpy-based Emuu:** an instance that is already running was started without the engine's
display service; the window then offers **Restart Engine** (a quick-boot save and relaunch, about 5 s, nothing is
lost). Hibernated and stopped instances need nothing. If an `emuu start` supervisor already
governs the instance, the app only shows the screen and forwards visibility, recording and input hints to it.

**On-screen keyboard.** On the Play Store image Gboard shows its keyboard in text fields even with the
emulator's hardware keyboard, and there is no shell command to show or hide an IME. With the Keyboard button
off, Emuu closes the soft keyboard (BACK while it is shown, which only closes the IME) after taps that bring it
up; turning it on again shows it for the focused field (tapping it, found via `uiautomator dump` or your last
tap). It also mirrors Android's *Use on-screen keyboard* setting (`show_ime_with_hard_keyboard`). Typing on the
Mac keyboard works either way (keys go in as hardware key events). Recording note: the engine only sends frames
when the screen changes, so a static screen gives a low-frame-rate (but correctly timed) file.

## How a session runs

`emuu start` launches the engine and then stays running as its **supervisor**, in the foreground or, with
`--detach`, in the background. The supervisor:

* owns the engine, or adopts one that is already running and leaves it running when it exits;
* runs the memory governor;
* publishes `~/.emuu/run/<id>.supervisor.json` (state, pids, governor summary, last sample) and a control
  socket, `~/.emuu/run/<id>.sock`. Other `emuu` commands, and the app, use these to freeze, thaw,
  hibernate, resume, stop, trim, reclaim and read events.

Only one governor runs per instance. A supervisor holds an exclusive lock, and the Emuu app takes the same
lock while it governs an instance. The engine runs in its own process group, so pressing Ctrl-C in a
foreground `emuu start` reaches the supervisor only. The supervisor then saves a quick-boot snapshot and
stops the engine cleanly.

## Memory governor

Desktop emulators tend to grow over long sessions: the guest fills its RAM with caches, background apps pile
up, and the Mac starts compressing and swapping. Emuu's governor samples about every 30 s when calm (every
5–10 s under pressure). It reads the guest's `/proc/meminfo`, the engine process's `phys_footprint` and CPU,
and the Mac's memory pressure. It acts in tiers:

| Tier | Action | Mechanism |
| --- | --- | --- |
| T1 trim | Ask background apps to release memory | `cmd activity send-trim-memory` on background processes (`pm trim-caches` during maintenance) |
| T2 kill | Kill cached background apps | `cmd activity kill <pkg>` (never `kill-all`) |
| T3 reclaim | Give guest RAM back to the Mac | Reports `unsupported` on this engine/image (no balloon driver); disabled after the first try |
| T4 freeze | Pause the VM: 0% CPU | SIGSTOP on the engine, when the window has been hidden and idle (headless: only with `--idle-freeze`) |
| T5 hibernate | Free all host memory | Quick-boot snapshot plus quit, after a long freeze, on memory creep, or when the Mac is under critical pressure; resumes in about 2 s |

* **The policy is a pure state machine with tests.** It confirms pressure before acting, keeps separate
  enter and exit thresholds (hysteresis), has a cooldown for each tier that doubles after each failed
  attempt, and escalates one tier at a time, and only when the previous tier did not help. It also limits
  how many actions it takes per hour.
* **It protects what you are using.** The foreground app, launchers, system UI, Play services and the Play
  Store are never trimmed or killed. The `performance` profile only trims while the game is on screen.
* **It reacts to the right signal.** Trim and kill respond only to *guest* memory pressure, never in the first
  3 minutes after a boot or resume, and never while you are signing in, in the Play Store or installing. The
  Mac's own memory pressure only makes a hidden, idle instance freeze (and then hibernate) sooner — trimming
  guest apps does not give the Mac any memory back.
* **Long-run hygiene.** It fits a trend line to the engine footprint and to guest available memory to spot
  slow memory creep. It runs maintenance (trim, kill cached apps, compaction) when the session is idle.
  History and event buffers have a fixed size, so the governor itself never grows.
* **Profiles.** `lite` (frugal: acts early, freezes after 2 min hidden and hibernates 5 min later),
  `balanced` (the default: freezes after 5 min hidden, hibernates after 2 h frozen) and
  `performance` (for games: acts late and never kills while visible).

When there is no window (headless), Emuu does not freeze the engine on its own, because other tools may be
using it over adb. Pass `--idle-freeze <minutes>` to allow it. In that mode, "activity" means any Emuu
command that touches the device. Hibernate and resume are always available by hand.

`emuu mem` shows the governor's samples and actions as they happen. `emuu logs --samples` shows the CSV
history (rotated, at most 12 MiB). `emuu bench` measures the effect on your machine;
[docs/BENCHMARKS.md](docs/BENCHMARKS.md) has measured numbers against a stock-style AVD, including where
Emuu is not better (a frozen engine keeps its footprint until it hibernates).

## adb and automation

Every running instance is a normal adb device; nothing Emuu-specific is needed:

```sh
emuu status phone            # … running on emulator-5554 …
                             #   adb: adb -s emulator-5554 shell
adb -s emulator-5554 install app.apk
adb -s emulator-5554 shell uiautomator dump
```

Appium (UiAutomator2) and Maestro connect the same way: point them at the serial (`udid` / `--device`).
Emuu's display uses the engine's gRPC service, not adb, so it coexists with them (and with scrcpy, if you run
it yourself).

**Automation mode.** The governor normally freezes (SIGSTOP) a hidden, idle instance and later hibernates it.
A frozen engine makes adb hang, which breaks a test run that pauses between suites. Automation mode prevents
that while keeping memory hygiene:

* the engine is never frozen or hibernated by the governor;
* pressure handling stops at T2: background apps are still trimmed and cached processes killed;
* the foreground app and every package with a running instrumentation (`am instrument`: Espresso,
  UiAutomator, Appium's UiAutomator2 server, Maestro) are never trimmed or killed — this protection applies in
  every mode.

Turn it on per instance: `emuu start phone --automation`, `emuu automation on phone` (applied live to a
running supervisor or app window; `off` to undo), or the **Automation mode** toggle in the app's memory HUD.
The setting is stored with the instance.

Without automation mode Emuu still notices other tools as best it cheaply can: each governor sample counts adb
shell sessions besides its own and the guest's process-creation rate, and treats such adb traffic as user
activity (no idle freeze while it lasts). That is a heuristic — a runner that sits idle between suites still
gets frozen — so use automation mode for CI and long scripted runs. `scripts/automation-soak.sh` is the soak
test used to check this (results in `docs/evidence/automation-soak-*.txt`).

## Automation farm

Emuu can run a small device farm for automated tests on one Mac: devices are **APFS clones** of a prepared
**golden image** that resume from its quick-boot snapshot, so a fresh device is adb-ready in about 2 seconds and
costs only the disk blocks it changes. A pool daemon keeps devices warm, leases them to test runs and resets them
to the golden state afterwards.

### Quick start

```sh
emuu golden create base --seal          # once: farm profile, animations off, sealed after 120 s of uptime (~2.5 min)
#   or set it up first: `emuu golden create base`, install apps / sign in, then `emuu golden seal base [--lean]`
emuu farm up --size auto                # daemon keeps N warm devices (N from RAM, cores and ports; see Limits)
L=$(emuu farm acquire --wait --json)    # {"leaseID": "L-…", "serial": "emulator-5554", "instance": "farm-default-1", …}
adb -s emulator-5554 install app.apk …  # drive it over adb
emuu farm release L-…                   # back to the golden state (snapshot load in the running engine)
emuu farm status [--json]               # devices, leases, counters, recent events
emuu farm down                          # destroys every device
```

Or let Emuu do the lease handling around one command:

```sh
emuu run --apk app.apk --artifacts out/ -- ./gradlew connectedAndroidTest
```

`emuu run` uses a device from a running pool of that golden (otherwise a new clone it destroys afterwards;
`--ephemeral` forces that), sets `ANDROID_SERIAL`, `EMUU_SERIAL`, `EMUU_INSTANCE` (and `EMUU_LEASE`), returns the
command's exit status and gives the device back. `--timeout s` (exit 124), `--keep-on-failure` (keeps the
device and prints how to reach it), `--artifacts dir` (on failure: `logcat.txt`, `screenshot.png`,
`health.json`, and `screenrecord.mp4` with `--record`). Exit 69: no device; 75: the device was lost (hung or
dead) during the run. SIGINT/SIGTERM are forwarded to the command's process group and the device is still
returned; if the runner itself is killed, its lease ends with it (holder pid) and `emuu farm gc` removes an
orphaned ephemeral clone.

### Commands

| Command | What it does |
| --- | --- |
| `golden create <name> [--from <instance>] [--ram MB] [--cores n] [--gpu mode] [--image tag] [--lean] [--seal]` | New golden instance (farm profile) booted headless; `--from` copies a stopped instance's disks (read only). |
| `golden seal <name> [--lean] [--no-prep]` | Farm settings (animations off, no adb-install verification, stay awake), optional `pm disable-user` of 26 preinstalled apps tests rarely need (`--lean`, experimental: saves only ≈ 0.1 GB, and one benchmark run had unexplained command failures — see BENCHMARKS.md; Play Store/Play services/Chrome/WebView stay), waits for 120 s of uptime, records the guest boot id and saves the snapshot. |
| `golden list`, `golden delete <name> -y` | |
| `clone <golden> <name>` | A persistent instance from a golden (resumes its state, then keeps its own). |
| `farm up [--pool p] [--golden g] [--size N\|auto] [--override-capacity] [--release-mode reset\|recycle] [--heal-leased replace\|restart\|report] [--ttl s] [--freeze-idle s] [--no-self-heal]` | Start or resize a pool. |
| `farm acquire [--wait] [--timeout s] [--ttl s] [--holder-pid pid] [--json]` | Lease a ready device that just passed a health check. Exit 69 when none. |
| `farm release <lease> [--reset\|--recycle] [--wait]` | End a lease; the device is reset (default) or replaced by a fresh clone. |
| `farm heartbeat <lease> [--ttl s]` | Extend a lease (exit 75 when its device was lost). |
| `farm status [--json]`, `farm capacity [--json]`, `farm down`, `farm gc` | |
| `run [--golden g] [--pool p] [--ephemeral] [--apk x.apk …] [--timeout s] [--keep-on-failure] [--artifacts dir] [--record] -- cmd …` | One command on a fresh device. |

Idle warm devices are frozen (SIGSTOP, 0 % CPU) after 60 s without a lease and thawed by `acquire` (measured:
SIGCONT + health check 0.07–0.18 s, adb answers at once; an idle device otherwise used 47–113 % of a core right
after its resume). `--freeze-idle 0` turns this off. Leased devices are never frozen.

Leases end on `release`, when their TTL (default 30 min) passes without a `heartbeat`, or when the
`--holder-pid` process exits (`emuu run` always sets itself). Two `acquire` calls never get the same device: the
pool state is changed under an exclusive file lock. Ports are picked automatically among console ports
5554–5584 (adb's emulator scan range), skipping any port another emulator (Emuu or not) is using.

**Reset vs recycle.** Release resets by loading the golden snapshot into the running engine (console
`avd snapshot load`): RAM *and* disks go back to the golden state (an installed app, files in `/sdcard` and
`/data/local/tmp` and changed settings are gone, verified). Recycle kills the engine, re-clones and resumes.
Both are verified with a health check and a second one 3 s later (same guest boot id as the golden) before the
device is offered again. Measured times are in docs/BENCHMARKS.md ("Farm").

### JSON output (format version 1)

* `farm acquire --json`: `{"leaseID", "pool", "instance", "serial", "consolePort", "adbPort", "holderPID",
  "acquiredAt", "expiresAt", "ttlSeconds"}`.
* `farm status --json`: `{"formatVersion": 1, "pools": [{"daemonAlive", "capacity": CapacityReport, "state": FarmState}]}`.
  `FarmState`: `pool, golden, size, daemonPID, createdAt, updatedAt, policy{releaseMode, healLeased, defaultTTL,
  freezeIdleAfter, overrideCapacity, selfHeal}, devices[], leases[], counters{acquires, releases, resets,
  resetFailures, recycles, replacements, leasesExpired, hangsDetected, recoveries, rebootsDetected}, history[]
  (last 300 events: at, kind, device, lease, detail), stopRequested, capacityNote`. A device:
  `instance, serial, consolePort, state (starting|ready|frozen|leased|resetting|unhealthy|replacing|failed),
  enginePID, leaseID, since, resets, replacements, failedRecoveries, lastHealth{verdict, reason, at},
  recycleNext, note`. A lease: `id, device, serial, holderPID, acquiredAt, expiresAt, ttlSeconds,
  state (active|device_lost), lostReason`.
* `farm capacity --json`: `CapacityReport{ceiling, byMemory, byCPU, byPorts, limitedBy, reserveBytes,
  perDeviceBytes, physicalMemoryBytes, cpuCores, coresPerDevice, admitNow, admitReason, availableBytes, pressure}`.
* `health --json`: `{instance, serial, verdict, reason, fault, checkedAt, probes[{name, status, detail, millis}],
  bootID, suggestedStep}`; `heal --json` adds `before`, `steps[{step, ok, millis, error, after}]`, `after`, `healed`.

Field names are stable; new fields may be added.

### Examples

Shell script:

```sh
read -r LEASE SERIAL _ < <(emuu farm acquire --wait --timeout 600)
trap 'emuu farm release "$LEASE"' EXIT
adb -s "$SERIAL" install -r app.apk && adb -s "$SERIAL" shell am instrument -w com.example.test/androidx.test.runner.AndroidJUnitRunner
```

pytest + Appium (UiAutomator2) — `emuu run` exports `ANDROID_SERIAL`:

```python
# conftest.py
import os, pytest
from appium import webdriver
from appium.options.android import UiAutomator2Options

@pytest.fixture
def driver():
    opts = UiAutomator2Options().load_capabilities({"udid": os.environ["ANDROID_SERIAL"], "app": "app.apk"})
    d = webdriver.Remote("http://127.0.0.1:4723", options=opts)
    yield d
    d.quit()
```

```sh
emuu run --artifacts out/ -- pytest -q tests/
```

Maestro: `emuu run -- sh -c 'maestro --device "$ANDROID_SERIAL" test flows/'`.

GitHub Actions on a self-hosted macOS runner (the pool stays up between jobs):

```yaml
jobs:
  ui-tests:
    runs-on: [self-hosted, macOS, ARM64]
    steps:
      - uses: actions/checkout@v4
      - run: ./gradlew assembleDebug assembleAndroidTest
      - run: emuu farm status --json >/dev/null 2>&1 || emuu farm up --golden base --size auto
      - run: emuu run --timeout 1800 --artifacts artifacts/ -- ./gradlew connectedDebugAndroidTest
      - if: failure()
        uses: actions/upload-artifact@v4
        with: { name: device-artifacts, path: artifacts/ }
```

### Limits and capacity

* **How many devices.** `emuu farm capacity` (and `emuu doctor`) compute it for the current host:
  `min(⌊(RAM − reserve) ÷ per-device memory⌋, ⌊cores ÷ vCPUs per device⌋, 16)`, with
  reserve = max(8 GiB, 40 % of RAM) for macOS and your own apps, and per-device memory = guest RAM + ~850 MiB
  engine overhead (measured). On a 16 GB Mac that is **2 devices** of the default profile. `--size auto` uses
  it; a bigger `--size` needs `--override-capacity`. A new device additionally waits while macOS memory
  pressure is not normal or less than one device plus 10 % of RAM is available. Estimates for 24–48 GB Macs are
  in docs/BENCHMARKS.md (estimates, not measurements).
* **16 devices per Mac at most:** adb only discovers emulators on console ports 5554–5584. Emuu does not use
  `adb connect` to go beyond that.
* **Activity Monitor shows about 4.7–5.1 GB per device** (2048 MB guest). That number counts the guest RAM twice
  (the QEMU mapping and the Hypervisor.framework mapping of the same pages); the real cost (`footprint`, and the
  rise of the Mac's used memory) is 2.8–3.1 GB (+0.1 GB over 23 minutes and ~40 resets in the soak).
* **Disk:** a golden image is ~3–4 GB (userdata + a ~1 GB RAM snapshot); a clone shares all of it and only
  grows by what the device writes: 84 MiB for two fresh devices, ≈ 0.3 GB per device after a 35-minute soak
  (BENCHMARKS.md). The volume must be APFS (`emuu doctor` checks).
* **Identity:** clones share the golden's Android ID (`settings get secure android_id`), boot id and the
  emulator's fixed serial number; adb serials and ports differ. A non-root Play image offers no way to change
  these from the shell. A Google account signed in on the golden is signed in on every clone.
* **Headless:** farm devices run without a window. Their gRPC display service is on (an idle listener costs
  nothing measurable), so `emuu screenshot -i farm-default-1` works and the app could show them.

## Self-healing

`emuu health <instance> [--deep] [--json] [--history]` runs layered probes, each with its own timeout and
reported separately:

| Probe | Detects |
| --- | --- |
| process | engine gone (→ dead), SIGSTOPped by someone other than Emuu (→ hung; Emuu's own freeze → `frozen`) |
| console | engine main loop not answering `ping` within 3 s |
| adb | transport `offline`, `unauthorized` or missing |
| shell | one `adb shell` round trip within 10 s: `sys.boot_completed`, guest `boot_id` (unexpected reboot), uptime, `/data` free (< 256 MiB → degraded) |
| framework | a system_server binder call (`cmd package resolve-activity`) within 15 s (framework deadlock while the shell still works) |
| ui (`--deep`) | an "isn't responding" / "keeps stopping" system dialog in front |

Verdicts: healthy, degraded, hung, dead (plus frozen/stopped). Exit status 0/1/2/3/4.

Recovery, smallest step first:

* `emuu reboot <instance> [--soft|--hard|--cold] [--wait] [--json]`: soft = `adb reboot` (engine keeps
  running); hard = engine stopped (console kill → SIGTERM → SIGKILL) and started from the quick-boot snapshot;
  cold = engine restarted with a cold boot (snapshot discarded).
* `emuu heal <instance> [--wait] [--json]`: checks, confirms the fault 3 s later (a dropped adb transport comes
  back by itself), then walks the ladder for that fault: thaw (externally SIGSTOPped engine) → reconnect adb →
  soft reboot (framework hang) → hard restart → cold boot. Farm devices: reset to the golden snapshot → fresh
  clone (done by the pool daemon).
* `emuu start --self-heal` (saved per instance): the supervisor checks every 20 s (deep probe every 6th time),
  acts only after two bad checks in a row (a dead engine at once), backs off exponentially between attempts,
  and stops after 3 failed recoveries in 30 minutes (status shows `selfHeal.failed`; `emuu heal` resets it).
  It never acts while Emuu itself froze or hibernated the instance, or while the engine is booting.
* **Farm pools self-heal by default** (`--no-self-heal` to turn off): idle devices are checked every 15 s and
  healed (reset, else replaced); a device must pass a fresh check before `acquire` hands it out. A **leased**
  device that fails two checks in a row is handled per `--heal-leased`: `replace` (default) marks the lease
  `device_lost` (`farm status`, `farm heartbeat` exit 75, `emuu run` exit 75) and frees the engine; a fresh clone
  takes its place once the lease is released or expires. `restart` heals it in place, `report` only marks the lease.

Every detection and recovery is logged with time, reason, step and duration: `emuu health <instance> --history`
(last 200, `logs/health-<id>.jsonl`) and `emuu farm status` (pool history and counters).

## Cloning an instance

Sign in to Google once, then make copies that are already signed in. In the app: the **…** menu of an instance in
the library → **Clone…**, give the copy a name (proposed: "phone copy") and confirm; the copy appears in the list.
On the command line:

```sh
emuu clone-instance phone phone2                 # phone is stopped or hibernated
emuu clone-instance phone phone2 --stop-source   # phone is running: hibernated for the copy, then resumed
emuu start phone2                                # resumes where phone was (~2.5 s)
```

* **What comes along:** the whole data partition and device state: Google account, Play Store state, installed apps
  and their data, settings, files in shared storage, plus the quick-boot snapshot, so the copy resumes exactly where
  the source was (`--cold-boot` drops the snapshot; the copy then boots Android from its disks, ~11 s).
* **What is new:** the instance name and id, its own console/adb ports (when they start, or a new fixed port in
  5554–5584 if the source has a fixed one; `--port` picks one), gRPC port and token, logs and run files. No file is
  shared with the source: every file is an APFS clone with its own inode, and writes on either side stay there.
* **Disk and time:** made with APFS `clonefile`, so it takes well under a second and no extra disk until the two
  differ (measured: 1.8 MiB of private data right after the copy of a 3.5 GB instance; `du` still shows the full
  apparent size for each, because it does not know the blocks are shared). On a volume without clone support
  (not APFS) Emuu says so and makes a normal full copy.
* **A running source** cannot be copied consistently: its disks are open and partly in memory. Emuu never copies a
  live disk. The CLI refuses unless `--stop-source` is given; the app asks first ("phone is running. To copy it
  safely, Emuu hibernates it for a few seconds…"). Then the source is hibernated (quick-boot snapshot saved, the
  engine's own consistent point), copied and resumed from that snapshot: its apps continue where they were, and it
  is paused for a few seconds (measured: 5.8 s in total from the CLI with a supervisor, 3.5 s from the app). A
  source governed by an `emuu start` supervisor is hibernated and resumed through that supervisor (by
  `emuu clone-instance --stop-source`; the app asks you to stop it or use that command). A frozen source
  is frozen again afterwards (CLI). A source that is booting, stopping, or crashed last time is refused.

**Same device, same account.** A clone keeps the source's Android identity: the Android ID, the Google services
(GSF) id and the account tokens all live on the data partition, and that is what carries the sign-in across. Emuu
does not change or randomise any of these. So **Google sees every copy as the same device and the same account.**
Emuu cannot guarantee that Google keeps the session valid when several copies run at the same time (it may sign
some of them out or ask to verify the device). This was **not tested with a real Google account**: the copies were
checked with an installed app, changed settings, a file in shared storage and the Android ID, all of which came
across unchanged.

## Video decoding

Each instance has a video decoder setting (`emuu video-decoder`, `create/start --video-decoder`, or the app's
memory panel):

| Mode | What decodes video | Notes |
| --- | --- | --- |
| `auto` (default) | currently `software` | Existing instances follow it without being recreated. |
| `software` | Android's own decoders inside the guest (`c2.android.*`) | Quick-boot snapshots stay loadable after video; ≈ 20–30 % of one core and ≈ 80 MB more than `hardware` per 1080p30 stream while playing. Very high-bitrate HEVC 1080p60 drops frames. |
| `hardware` | the Mac's VideoToolbox, via the guest's `c2.goldfish.*` codecs (the engine's default) | Cheapest for heavy 1080p60. **A quick-boot snapshot saved after any video was played cannot be loaded** (hibernate/resume cold-boots, the engine may hang or crash). |
| `host-software` | ffmpeg on the Mac, same guest codecs as `hardware` | For comparisons only. |

The guest picks its codecs when it boots, so switching between host and guest decoders cold-boots once at the next
start (the app's RAM state is lost; data on the device is kept). `EMUU_VIDEO_DECODER=<mode>` overrides every
instance for one command or app launch. Farm clones keep the codecs of their golden's snapshot; re-seal a golden
to change them. Measurements: docs/engine-findings.md, "Video decoding".

**Green video area (e.g. TikTok)?** `emuu video-decoder status <name>` shows which decoders the running guest
uses. With host decoders, switch: `emuu video-decoder software <name>`, then stop and start the instance.

## Play Store sign-in

Sign in **on the device**, the same way as on a phone: `emuu playstore --sign-in` opens the Google account
screen. Emuu never sees or stores your Google credentials. You need to see the screen to sign in, so use
`emuu start --window` or the Emuu app (password pages are shown; Emuu's display reads the engine's framebuffer). If Google asks you to verify the device, follow
its prompts. `emuu playstore --status-only` shows whether an account is signed in.

## Files

```
~/.emuu/avd/                 instances (ANDROID_AVD_HOME for the engine)
~/.emuu/instances/<id>.json  instance settings
~/.emuu/avd/<id>.avd/emuu-guest-codecs  host|guest: decoders of the last launch (and its quick-boot snapshot)
~/.emuu/run/                 pid files, supervisor status JSON, control sockets, locks
~/.emuu/logs/                emuu.log, engine-<id>.log, supervisor-<id>.log, memory-<id>.csv
~/.emuu/cache/               temporary install extraction (an old cache/scrcpy/ from earlier versions can be deleted)
~/.emuu/screenshots/         app screenshots
~/.emuu/recordings/          app screen recordings (MP4)
~/.emuu/farm/goldens/        sealed golden images (<name>.json; the instance itself is in avd/)
~/.emuu/farm/pools/<pool>/   pool state.json (+ lock), daemon.lock, daemon.log
~/.emuu/farm/ephemeral/      owners of `emuu run` clones (for `farm gc`)
~/.emuu/logs/health-<id>.jsonl  health detections and recoveries
```

Unified logging: `log stream --predicate 'subsystem == "dev.emuu"'`.

## Development

```sh
swift build --product emuu
swift test                           # all test targets (device/engine tests are opt-in via env vars)
EMUU_GRPC_PID=<qemu pid> swift test --filter "LiveEmulatorTests|LiveDisplaySessionTests"   # against a running engine
```

`docs/ARCHITECTURE.md` describes the modules. `docs/engine-findings.md` and `docs/memory-governor.md` hold
the measurements behind the defaults.

Display flicker, tearing or black frames: play the content, then run
`emuu debug display-probe <instance> --duration 60 --save ~/Desktop/emuu-flicker` (counts torn, blank, out-of-order
and flashing frames). Details and the test pattern/APK: "Diagnosing display artefacts" in `docs/ARCHITECTURE.md`.
