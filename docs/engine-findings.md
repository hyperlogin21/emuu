# Engine findings (EmuuEngine)

Measured on 2026-11-18 on the target machine: Apple M5, 10 cores, 16 GB RAM. Android Emulator **36.4.9**
(build 14788078). Image `system-images;android-36.1;google_apis_playstore;arm64-v8a` rev 4 (kernel
6.12.38-android16). Instance `emuu-dev`: 2048 MB, 4 vCPUs, 720x1600 @ 320 dpi, `-gpu host`, console 5580.
Other agents were building in parallel, so treat CPU and time figures as ±30%.

Every claim here comes from running the binaries, the console or the guest. Raw numbers come from
`Tests/EmuuEngineTests/RealEngineIntegrationTests.swift` (opt-in: `EMUU_ENGINE_IT=1`) and from shell experiments
with `nc`, `ps`, `top`, `footprint`, `vmmap` and `proc_pid_rusage`.

## Process model

* `emulator -avd X -no-window …` **execs** into
  `emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless` with the same pid (checked with `ps`). The pid
  Emuu spawns is therefore the QEMU pid that owns guest RAM, so `enginePID` needs no child lookup.
* The engine holds an exclusive `flock` on `<avd>/multiinstance.lock` for its lifetime, and the kernel drops it
  on exit. A non-blocking `flock` probe is a reliable "is this AVD running" test, including across processes.
  `hardware-qemu.ini.lock` contains the pid.
* Even after a **clean** exit the engine leaves `hardware-qemu.ini.lock` and `snapshot.lock.lock` behind.
  Launching with them present still worked, but Emuu deletes them after every stop, and before every launch when
  the flock is free.
* Hand-written `<id>.ini` (with only `path=` and no `path.rel`) plus `config.ini` under `ANDROID_AVD_HOME=~/.emuu/avd`
  work: `emulator -list-avds` lists the instance and it boots. avdmanager is not needed.
* The engine resolves config.ini into `hardware-qemu.ini`. Every key Emuu writes appeared there with the
  intended value. The one exception is `vm.heapSize`: 256 was requested and the **engine forced 512**
  (`androidboot.dalvik.vm.heapsize=512m`). This is a per-app ceiling, not reserved RAM.
* userdata is a qcow2 overlay (`userdata-qemu.img.qcow2` on top of the small `userdata-qemu.img`) that grows on demand:
  1.7 GB used of the 6 GB partition after first boot. The backing-file references are **relative**, so cloning the
  AVD directory (APFS clone) is safe.

## Command line used (all flags confirmed in `emulator -help`)

`-avd <id> -no-window -no-boot-anim -ports <c>,<c+1> -gpu host -memory <MB> -cores <n> -no-metrics -netfast`,
plus `-no-audio` when audio output is off and `-no-snapshot-load` for a forced cold boot.
Environment: `ANDROID_AVD_HOME=~/.emuu/avd`, plus `ANDROID_SDK_ROOT`/`ANDROID_HOME` set to the SDK in use.
Not used: `-lowram` (it sets `ro.config.low_ram`, which makes Play treat the device as Android Go and filters
apps), and `-no-snapshot-save` (it would disable the quick-boot path that hibernate relies on).

## Boot times (to `sys.boot_completed` = 1, polled through adb)

| Boot | Time |
| --- | --- |
| First cold boot of a fresh AVD (Play Store image) | **23 s** (engine log: "Boot completed in 18629 ms") |
| Later cold boot (`-no-snapshot-load`, or after a failed snapshot) | 9.5–11.6 s |
| Quick boot from `default_boot` (hibernate resume) | **1.7–2.1 s** (snapshot load 450–850 ms) |

## Steady-state cost, running and idle (home screen, nothing launched)

* CPU: 10–30% of one core (`top` and `proc_pid_rusage` deltas over 10 s, 20–40 s after boot; post-boot work such as
  Play services updates inflates the early figures).
* Memory, which depends on the tool:
  * `proc_pid_rusage` `ri_phys_footprint`, which equals `top` MEM and `vmmap` "Physical footprint": **4.3–4.5 GB**.
  * `footprint -p`: 2.3–2.5 GB (it sums regions; guest RAM shows as ~2.0 GB "untagged VM_ALLOCATE").
  * `vmmap --summary`: guest RAM is a 2.0 GB "shared memory" region. In one sample, 746 MB of it was resident and
    **1.2 GB already compressed by macOS**, with no Emuu action and the engine running normally.
  * RSS: 2.4–4.2 GB.
  * EmuuMemory: the kernel ledger (`ri_phys_footprint`) is about 2x the region sum for this process. Use one
    metric consistently for trends. The ledger is what macOS's own pressure accounting uses.
* The guest touches nearly all of its RAM soon after boot: MemTotal 2017768 kB, MemFree ~45–65 MB,
  MemAvailable ~0.7–0.8 GB, the rest page cache. Without a balloon, host memory therefore approaches the full
  guest size within minutes.

## Freeze (T4): measured

| | SIGSTOP / SIGCONT on the QEMU pid | console `avd stop` / `avd start` |
| --- | --- | --- |
| Engine CPU while frozen | **0.00%** | 0.4–0.7% (QEMU main loop keeps running) |
| Freeze / thaw latency | < 1 ms each (`EngineInstance`, 3 runs) | `avd stop` returned within ~1 s in `nc` tests (includes nc's own sleep); not timed in-process |
| Console while frozen | does not answer (connection hangs) | answers (`avd status` → "virtual device is stopped") |
| `adb devices` while frozen | still lists `device` | still lists `device` |
| `adb shell` while frozen | hangs (killed after a 10 s timeout) | hangs |
| First `adb shell` after thaw | works immediately (0.03 s) | works immediately |
| Guest wall clock after thaw | correct (guest counter keeps running) | lagged 17 s after a 17 s stop, and the lag was still there ≥ 90 s later. After a 150 s stop it read correct 5 s after resume. Inconsistent, so assume it can lag. |
| 150 s freeze | system_server pid unchanged, boot_id unchanged, no Watchdog kill | system_server pid unchanged |
| Host footprint while frozen | unchanged (4524 → 4524 MB; second run 4247 → 4174 MB). Freezing releases no memory by itself; it only lets macOS compress or swap the idle pages under pressure. | unchanged (4170 MB) |

**Decision: `FreezeMechanism.signal` is the default.** It uses zero CPU, keeps the guest clock right, and survived
150 s with no watchdog fallout. The `.console` mechanism stays available. Consequences that consumers must handle:

* While frozen, adb and the console hang. EmuuMemory/EmuuADB must not sample a frozen instance (check `state()`).
* `EngineInstance` thaws automatically before `hibernate` and `stop(.graceful)`.
* `refresh()` detects a SIGSTOPped engine through the `SSTOP` process state, and a console-stopped one through `avd status`,
  so a different Emuu process sees `.frozen` correctly. This is verified both in the integration test and with fakes.

## Hibernate / resume (T5): measured

* Console `kill` → "OK: killing emulator, bye bye" → the engine saves `default_boot` and exits. Kill+save took 2.3 s and
  2.1 s of wall time in shell tests (engine log: "Saving snapshot 'default_boot' using 1564 ms" / "1030 ms"). Through
  `EngineInstance.hibernate()` the whole thing took 3.3 s.
* **SIGTERM also saves** `default_boot` before exiting (2.1 s), with a 20 s internal grace period
  ("ANDROID_EMULATOR_WAIT_TIME_BEFORE_KILL"). The only exit that skips the save is SIGKILL.
* Snapshot size for a 2 GB guest: `ram.bin` 1.04–1.13 GB, `textures.bin` 15 MB, `screenshot.png` 1 MB.
  `avd snapshot list` reports "VM SIZE 68M" (that column is not the RAM file size).
* Resume = normal launch (quick boot loads `default_boot`): **1.7–2.1 s** to `sys.boot_completed`.
  `avd snapshot get` then returns `default_boot` (`(null)` after a cold boot).
* Hibernating releases the whole engine footprint (4.8 GB ledger) back to the host. After resume the
  footprint is back to ~4.4 GB: a snapshot load writes every guest page, so RAM is **not** lazily file-backed
  (`QuickbootFileBacked=on` in advancedFeatures.ini has no visible effect on macOS here; `OnDemandSnapshotLoad=off`).
* Loading a snapshot rolls the qcow2 disks back to that snapshot. Emuu therefore deletes `default_boot` after
  `stop(.force)`, after a crash and after `stop(.graceful(saveQuickBoot: false))`, so the next start cold-boots from the
  current disks instead of silently rolling back user data.
* **A save on exit can fail.** Once (the engine had been idle ~15 min after a quick-boot resume, and had been
  inspected with `vmmap`/`footprint`, which suspend the task briefly) the console `kill` logged "USER_WARNING | The
  emulator was unable to save default_boot and will now erase it" and then "Saving snapshot 'default_boot' using 8 ms".
  The next launch could not load it ("Device 'encrypt' does not have the requested snapshot") and cold-booted with the
  disks intact. The cause was not established. `hibernate()` now treats the save as complete only if `snapshot.pb` is fresh,
  `ram.bin` is at least 16 MiB and the engine log since the kill contains no "unable to save default_boot". Otherwise it
  deletes the stub, reports `.stopped` and throws.
* **Root cause narrowed down (reproduced):** the failing sessions were all quick-booted from a `default_boot` written by a
  session that had also run `avd snapshot save emuu_it` + `avd snapshot delete emuu_it`. A controlled run on 13:16–13:18:
  stopping such a session → "unable to save" (step 1). Then a cold session → save OK (939 ms), and a quick-booted session
  of that clean lineage that ran 60 s → save OK (1042 ms). So **named snapshot operations break the quick-boot
  chain one generation later**. The governor must hibernate only through `hibernate()` (default_boot) and never create
  named snapshots. Whether save or delete is the trigger was not separated.
* Caution: if a snapshot was saved with a different device set (for example an extra `-qemu -device`), the next
  launch still printed "Successfully loaded snapshot". Do not change devices between hibernate and resume.

## Guest memory reclaim to host (T3): not available

* The console's `qemu monitor` → `KO: QEMU support no longer available`.
* QEMU itself (2.12.0) accepts `-qemu -device virtio-balloon-pci,id=balloon0 -monitor unix:<sock>,server,nowait`:
  `info balloon` → `balloon: actual=2048`.
* The guest has `CONFIG_VIRTIO_BALLOON=m`, but no `virtio_balloon.ko` ships in `/vendor/lib/modules` (the
  `/system_dlkm` listing is permission-denied for shell). After a **cold boot** with the device present, the guest
  enumerates it (20 instead of 19 PCI devices; `virtio24` appears) but it stays **unbound**. `balloon 1536` leaves
  `actual=2048`. Free-page reporting (`CONFIG_PAGE_REPORTING=y`) needs the same driver.
* `CONFIG_INIT_ON_FREE_DEFAULT_ON` is not set, so pages the guest frees keep stale data and cannot be dropped by zero-page
  detection either.
* → `reclaimGuestMemory` returns `.unsupported(reason:)`. The working way to give memory back is T5 (hibernate,
  3.3 s, resume about 2 s). T1/T2 (trim and kill in the guest) only move memory from apps to the guest page cache;
  they do not shrink the host footprint.

## Console protocol notes (verified)

* Greeting: "Android Console: Authentication required … type 'auth <auth_token>' … '<home>/.emulator_console_auth_token'"
  then `OK`. Every reply ends with `OK` or a line `KO: <message>`. Some help texts glue `OK` to the last line
  (`…not immediately needed.OK`).
* `avd` sub-commands on 36.4.9: stop, start, status, heartbeat, rewindaudio, name, grpc, snapshot, pause, hostmicon,
  hostmicoff, resume, bugreport, id, windowtype (`windowtype=headless`), path, discoverypath, snapshotspath, snapshotpath.
* `avd snapshot`: list, save, load, del/delete, remap, get, pull, push. Empty list → "There is no snapshot available."
* `avd snapshot remap 0|1` toggles quick-boot auto-save only when the session was loaded from `default_boot`, and
  deactivating it saves a snapshot, so it cannot provide a "stop without saving".
* Named snapshot save (`avd snapshot save emuu_it`) took 1.6 s with the guest running.

## Guest facts for other modules (observed with `adb shell` as the shell user)

* `/proc/pressure/memory` → **Permission denied** (the `cpu`, `io`, `irq` and `memory` files exist). PSI is not available to
  EmuuMemory over adb on this image.
* `/proc/swaps` and `/sys/block/zram0/*` → Permission denied. ZRAM is built (`CONFIG_ZRAM=m`, default lzo-rle).
* `/proc/meminfo` is readable. `ro.config.low_ram` is unset. `dalvik.vm.heapsize` = 512m.
* The engine logs failures of its own boot-time `adb -e shell settings put system screen_off_timeout 2147483647`
  ("no emulators found"), yet `settings get system screen_off_timeout` reads 2147483647 afterwards, so the screen never
  times out in the guest.

## gRPC display service (EmulatorController): measured 2026-11-19

Emuu's display uses the engine's own gRPC service, the one Android Studio's embedded emulator uses. Everything
below was checked against 36.4.9 with an isolated instance (lite, 720x1600) and a hand-written client.

* **Enabling it.** Not on by default: an engine started without `-grpc` has no gRPC listener and its discovery
  file has no `grpc.*` keys; the console's `avd grpc` only *prints* the port (`help avd grpc`: "will return grpc
  port of this virtual device"), it cannot start the service. Emuu now launches with
  `-grpc <port> -grpc-use-token` (port `console + 3000`, i.e. 5554 → 8554, else the first free port in 8554…8999).
  The listener binds **127.0.0.1 only** (`lsof`: `TCP 127.0.0.1:8584 (LISTEN)`).
* **Auth.** With `-grpc-use-token` every call needs `authorization: Bearer <token>`; a wrong token gets
  `UNAUTHENTICATED` (live test `badTokenIsRejected`). The engine generates the token and writes it, with
  `grpc.port`, to its discovery file `~/Library/Caches/TemporaryItems/avd/running/pid_<qemu pid>.ini` (directory
  mode 0700; the console's `avd discoverypath` prints the same path). Emuu reads it there and never logs it.
  `emulator_access.json` (the allow-list) lets token holders call every `EmulatorController` method.
* **Protocol.** Plain gRPC over cleartext HTTP/2 (h2c, prior knowledge). The server HPACK-encodes with Huffman
  and the dynamic table, uses trailers for `grpc-status`, honours `grpc-timeout`.
* **`streamScreenshot` with `ImageTransport.MMAP`.** The handle may be a POSIX shm name (`/emuu-<pid>-<n>`, created
  by the client with `shm_open` + `ftruncate`) or a `file://` URL; with MMAP the `Image.image` bytes are empty and
  the pixels are in the shared region. **Width and height must be set in the request**: a request with 0×0 and an
  MMAP handle crashed the engine (crashpad dump, 07:28 local). With a size the region must hold `width × height × 4`.
  Emuu requests a square `max(w,h)²` so both orientations fit without scaling.
* **Pixels.** RGBA8888, alpha 0xff, rows **top-down** (the proto comment says bottom-up; it is not).
* **Frames only on change.** A static screen produces no messages at all (20 s on the home screen: 0–1 frames).
  Animation runs at the guest's 60 Hz (`seq` contiguous with MMAP; without MMAP a 4.6 MB payload per frame kept a
  Node client at ~34 fps). Opening the stream delivers the current frame at once (~70–140 ms incl. connect).
* **Each `Image` carries `timestampUs`** (Unix µs when the engine produced the frame): engine → client transport
  measured 2.7–4.7 ms.
* **Rotation.** `setPhysicalModel(ROTATION, [0, 0, z])` turns the virtual device (sensors); with
  `accelerometer_rotation=1` Android follows (`dumpsys window displays`: `mDisplayRotation=ROTATION_90` for z=90,
  `ROTATION_270` for z=−90). Frames are delivered **already rotated** (1600x720 in landscape, `format.rotation` =
  LANDSCAPE). Apps locked to portrait (the Pixel launcher) stay portrait and the frame shows them sideways, like a
  phone held sideways.
* **Touch coordinates are physical (unrotated panel) pixels**, whatever the rotation: with `pointer_location` in
  landscape, a touch at physical (100, 600) appeared at frame pixel (600, 619). Pressure scale: 50 showed as 0.05,
  so 1024 ≈ 1.0. Touches use `identifier` per finger (multi-touch, protocol B).
* **Keys.** `KeyboardEvent` with `codeType = Mac` takes macOS virtual key codes directly (the engine converts with
  chromium's tables); W3C names `GoBack`, `GoHome`, `AppSwitch`, `Power`, `AudioVolumeUp/Down` work (volume
  verified with `dumpsys audio`).
* **Clipboard.** `setClipboard` from the host is not echoed on `streamClipboard`; opening `streamClipboard` sends the
  current (non-empty) clipboard immediately.
* **Secure windows.** The host framebuffer contains `FLAG_SECURE` windows; `adb exec-out screencap` of the same moment
  is black (docs/evidence/secure-window-native.png vs secure-window-adb-screencap.png).
* **Engine cost.** 60 fps MMAP streaming added roughly 10 points of one host core to the QEMU process during
  continuous swipes (≈84 % without a client, ≈94–95 % with one); guest CPU unchanged (see BENCHMARKS.md).

## Spontaneous guest restart after a quick-boot load (observed, cause open)

* On `agent-test` (2026-11-19 00:09 UTC), a quick-boot resume restarted the guest kernel by itself ~2–8 s after
  "Successfully loaded snapshot" — no Emuu action had run. Signs: the engine log prints `Boot completed in 8802 ms`
  after the snapshot load (a quick boot that does not restart prints no such line), the guest's `boot_id` changes,
  `/proc/uptime` restarts, dropbox gets `SYSTEM_BOOT` + `SYSTEM_FSCK` (fsck after an unclean stop), and
  `persist.sys.boot.reason.history` gains `reboot,<epoch>`. `ro.boot.bootreason` is `reboot` on every emulator boot,
  so the reason string carries no information.
* The user's `emuu-e2e` log shows the same signature twice: 17:02 (no governor action at all) and 23:21–23:22
  (`Boot completed in 9142 ms`, history `reboot,1795044157` = 23:22:37).
* Six further resume cycles did not restart (five from 1–2-minute sessions, one from a 20-minute busy session
  followed by the user's exact T1→T2 timeline). See docs/memory-governor.md ("Guest restarts").

## Unverified / open

* The `lite` preset (1536 MB, 2 vCPUs) has not been booted. Only `standard` (2048/4) was measured.
* SIGSTOP freezes longer than 150 s (hours) were not tested. The guest sees a forward time jump on thaw, and nothing
  broke at 150 s.
* Host-side compression of a frozen engine under real memory pressure was not provoked deliberately.
