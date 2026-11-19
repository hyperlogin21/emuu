# Emuu memory governor

The memory governor keeps an instance's memory use low and steady over sessions that last hours
or days. It lives in `Sources/EmuuMemory` and has four parts:

| Layer | Type(s) | I/O |
| --- | --- | --- |
| Samplers | `GuestSampler`, `HostSampler`, `HostPressureMonitor` | one `adb shell` per guest sample; syscalls only on the host |
| Policy | `GovernorPolicy`, `GovernorConfig` | none. It is a pure, deterministic state machine |
| Effectors | `GuestEffector`, `EngineEffector`, `EffectorRouter`, `MaintenanceRunner` | `DeviceShell` (adb) and `EngineControl` |
| Driver | `MemoryGovernor` (actor) | runs the loop, keeps history, emits events, writes the CSV log |

Wire it up in the app or CLI like this:

```swift
let gov = MemoryGovernor.standard(
    instanceID: id, config: .preset(config.memoryProfile, guestRAMMB: config.ramMB),
    engine: engineControl, shell: deviceShell, activity: activitySource,
    csvLog: SampleCSVLog(url: paths.logsDirectory.appendingPathComponent("memory-\(id).csv")))
await gov.start()
for await event in await gov.events() { … }      // UI, or `emuu mem watch`
gov.nudge()                                       // on window show/hide, user input, host pressure
```

## 1. Sampling

### Guest

Each guest sample is a single `adb shell` round trip (`GuestSampler.combinedCommand`). It reads:

* `/proc/meminfo`, giving total, free, available, cached, buffers and swap (zram).
* `/proc/pressure/memory` (PSI). **This file is not readable by the shell uid on the API 36
  Play Store image** (`Permission denied`, verified on emulator-5580). The parser treats a missing
  value as "no PSI", and the PSI thresholds only apply on images where the file can be read.
* Selected `/proc/vmstat` counters, turned into per-second rates: major faults, swap in/out,
  workingset refaults and alloc stalls.
* A scan of `/proc/<pid>/oom_score_adj` that uses only shell builtins (no forks). It counts cached
  processes (adj ≥ 900) and lists the foreground processes (adj 0) by `argv[0]`. mksh's `read` stops
  at the NUL in `cmdline`, and kernel threads have an empty cmdline, so they are skipped.

Measured on the device, a round trip takes 29–57 ms with typically about 35 processes cached.
`dumpsys meminfo -c` costs too much to run on every sample, so it only runs on demand through
`MemoryGovernor.appBreakdown()`.

### Host

The host side is all syscalls. No subprocesses are started.

* Engine tree: `proc_pid_rusage(RUSAGE_INFO_V4)` on the QEMU pid and its descendants
  (`proc_listchildpids`). It records:
  * `ri_phys_footprint`, the same number as Activity Monitor's "Memory" and `top`'s MEM. The
    `footprint(1)` tool reports less because it leaves out compressed pages. Verified: rusage gave
    4384 MiB and `top` gave 4385M.
  * `ri_lifetime_max_phys_footprint`, `ri_resident_size`, and CPU time converted with
    `mach_timebase_info` into CPU% between samples.
* Mac: `host_statistics64(HOST_VM_INFO64)` (free and compressor pages), `vm.swapusage`, and
  `kern.memorystatus_vm_pressure_level` (1/2/4 map to normal/high/critical).
  `HostPressureMonitor` wraps `DispatchSource.makeMemoryPressureSource` for push notifications. Feed
  it to `HostSampler(pressureHint:)` and call `nudge()` from its `onChange`.

## 2. Pressure levels (with hysteresis)

There are **two** levels, and they drive different things.

**Guest level** — the only input of the guest-side tiers T1–T3. It is the maximum over:

| Signal | balanced: elevated / high / critical | exit margin |
| --- | --- | --- |
| guest MemAvailable / MemTotal | ≤ 22 % / 14 % / 7 % | +4 points |
| PSI `some avg10` (if readable) | ≥ 8 / 20 / 40 % | −3 points |
| PSI `full avg10` | ≥ 15 % → critical | −3 points |

**Host level** — only shortens the way to freeze/hibernate of a hidden, idle instance (section 4). It never
triggers trim or kill: those move memory inside the guest and do not shrink the engine's host footprint
(measured, docs/BENCHMARKS.md). It is the maximum over:

| Signal | balanced: elevated / high / critical | exit margin |
| --- | --- | --- |
| engine footprint ÷ budget | ≥ 1.05 / 1.20 / 1.40, **capped at elevated** | −0.05 |
| macOS memory pressure | warning → high, critical → critical | none (the kernel already has hysteresis) |

Why: on 2026-11-18 (emuu-e2e, 23:21 UTC) the governor read the Mac's "pressure high" 30 s after a quick-boot
resume, with the guest at 39 % MemAvailable, and ran T1 trim and then T2 kill of 11 packages while the user was
signing in to the Play Store. Regression test: `HostVsGuestPolicyTests.regressionHostPressureAfterResumeTriggersNoGuestActions`.

**When guest actions are held** (T1–T3 and maintenance; the decision's notes say why):

* for `guestActionGraceAfterStart` (3 min) after the engine (re)enters running: cold boot, quick-boot resume,
  thaw, or the governor starting;
* while a sensitive package is in the foreground: `com.android.vending`, `com.google.android.gms` (and its
  `.ui`/`:` processes), `com.google.android.gsf`, the package installers, the permission controller, setup
  wizard (`GovernorConfig.sensitiveForegroundPackages`).

How the level moves:

* Entering a higher level uses the enter thresholds and needs `escalationConfirmSamples`
  consecutive samples (2 for balanced). Critical takes effect immediately.
* The level only drops once every signal has passed its threshold plus the exit margin. This stops
  the level flapping around a threshold.

**Footprint budget** = 2 × guest RAM + 1 GiB. This figure is empirical. A freshly booted 2 GiB guest
(engine 36.4.9, `-gpu host`) already showed a **4.3–4.4 GiB** footprint, of which about 1.5 GiB was
compressed and 2.8 GiB resident. A budget of "RAM + overhead" would have kept every healthy
instance at critical. Guest-side trimming barely changes the host footprint, so this signal alone
can only reach `elevated`, which buys cheap T1 trims. The real remedies for an over-budget engine
are reclaim (in maintenance) and a shorter path to hibernation (section 4).

## 3. Pressure tiers T1–T3

| Level | Tier the governor wants | Action |
| --- | --- | --- |
| elevated | T1 trim | `cmd activity send-trim-memory <proc> BACKGROUND` (MODERATE at high, COMPLETE at critical) for background processes (adj ≥ 300) |
| high | T2 kill background | `cmd activity kill <pkg>` for cached packages (adj ≥ 900) |
| critical | T3 reclaim | `EngineControl.reclaimGuestMemory` |

The rules:

* **One tier at a time.** The first action is always T1.
* **Escalate only if the previous tier did not help.** After a tier acts, the governor waits
  `evaluationDelay` (45 s; halved at critical) and then judges the result. The tier "helped" if the
  level fell or guest MemAvailable rose by at least `improvementFraction` (3 points). If it helped,
  the governor stays on that tier and repeats it after its cooldown. If the tier was a no-op (for
  example, no background apps), the governor escalates at once.
* **Per-tier cooldowns** for balanced: trim 3 min, kill 6 min, reclaim 15 min. Each failed attempt
  doubles the cooldown, up to 64×.
* **De-escalation** happens after the level has stayed below a tier for `deescalationCalm` (3 min).
* **Unsupported mechanisms are learned.** An `.unsupported` outcome disables that tier for the
  rest of the session (`resetCapabilities()` turns it back on). The guest has no `virtio_balloon`
  driver bound (`/sys/bus/virtio/drivers` lists none, and `balloon_inflate 0`), and
  `emulator -help-all` documents no balloon option, so T3 is expected to report unsupported on this
  engine. The `EngineControl` implementation in EmuuEngine decides.
* **Rate limit.** At most `maxActionsPerHour` escalating actions (24 for balanced) in any rolling
  hour, maintenance included. Reversals (thaw and resume) are never limited.
* **Tier caps.** `visibleTierCap` limits what runs while the window is visible.

### Safety (enforced by the effector, not only by policy)

* The foreground process(es) (adj 0) are never targeted. Processes bound to the foreground, such as
  Play services or the launcher, also sit at adj 0 and are therefore excluded too.
* `ProtectedPackages.default` is never targeted. It covers system UI, Play services
  (`com.google.android.gms*`), the Play Store (`com.android.vending`), GSF, providers, IMEs,
  launchers, permission controller, WebView and network stack. Matching uses the package name and
  any dotted prefix of it.
* `am kill-all` is **not** used, because it would also kill cached Play services processes.
* Commands go through `cmd activity` and `cmd package`, which are native binder clients. `am` and
  `pm` start a Java VM for each call, which would be expensive across dozens of targets.
* Before and after each trim or kill, MemAvailable is measured in the same round trip. The
  difference is reported as `reclaimedBytes`.

## 4. Freeze (T4) and hibernate (T5)

These two tiers depend on whether the user is present, not on memory pressure.

* **Freeze** happens once the display has been hidden for `freezeWhenHiddenAfter` and the user has
  been idle at least as long. The delay is 2 min for frugal, 5 min for balanced and 15 min for
  performance; under host pressure (host level high or critical) it is `hostPressureFreezeAfter` (1 min). A
  visible or recording window, user input, or automation mode always prevents it. After a thaw, the instance
  is not frozen again for `cooldowns.freeze`, to avoid flapping.
* **Thaw** happens as soon as the display is visible or there has been user input since the freeze.
* **Hibernate** applies to a frozen, hidden instance in these cases:
  * the host's memory pressure is critical: hibernate immediately;
  * the host level is high: after `hibernateWhenFrozenUnderHostPressureAfter` (2 min);
  * creep was detected, or the engine footprint is at or above the critical budget ratio: after
    `hibernateWhenFrozenUnderCreepAfter` (30 min for balanced);
  * otherwise: after `hibernateWhenFrozenAfter` (2 h for balanced, never for performance).
* **Resume** happens when the display becomes visible or there is input (`autoResume`).
* Hibernating and resuming starts a fresh engine process, which discards the footprint the engine
  has built up. That is why hibernation is the remedy for creep.

## 4b. Guest restarts (diagnostics)

Every guest sample also reads the guest kernel's `boot_id` and uptime. If the boot id changes under a running
engine, the governor logs a warning with its last 12 actions (wall-clock time, action, outcome — T2 logs the exact
package list) and emits `guestRebooted`; the app shows it in the HUD timeline and `emuu mem` prints `REBOOT`.

What is known (docs/engine-findings.md): the engine can restart the guest by itself a few seconds after a
quick-boot snapshot load, with no Emuu action (reproduced once on an isolated instance; seen twice in the user's
logs, once with no governor action at all). The user's 23:22 restart came ~0–3 s after a T2 kill; a T2 kill of 24
packages on the test instance (same command, same image) did not restart it. With the policy change above, that
T2 would not have run (host pressure, grace period, Play Store sign-in in the foreground).

## 5. Long-horizon hygiene

* **Creep detection.** The governor fits a least-squares line over a bounded window: one point
  per minute, 240 points (4 h). It fits two series:
  * the engine footprint. Creep is reported if it grows by at least 96 MiB/h (balanced);
  * guest MemAvailable. Creep is reported if it shrinks by at least 128 MiB/h.

  A report also needs a window of at least 1 h and r² ≥ 0.6, so noisy but flat data does not count.
  `creepDetected` is emitted at most once an hour. Trends reset when a new engine process starts.
* **Maintenance.** It runs when the guest level is at most elevated, guest actions are not held (section 2), the user has been idle for
  `maintenanceRequiresIdle` (10 min for balanced) and the run is due. Runs are due every 2 h, or
  every 45 min while creep is active. For performance, the window must also be hidden. The steps
  are:
  1. `trimBackground` (COMPLETE)
  2. `killCached`
  3. `trimCaches` (`cmd package trim-caches 2G`, which keeps the userdata image from growing)
  4. `compact` (`cmd activity compact system`; verified, it freed about 44 MiB of guest
     MemAvailable on the device)
  5. `reclaim`, unless that tier has been disabled

  A failing step does not stop the steps after it.

## 6. Profiles

| | frugal ("lite") | balanced | performance (gaming) |
| --- | --- | --- | --- |
| available elevated / high / critical | 30 / 20 / 10 % | 22 / 14 / 7 % | 15 / 9 / 5 % |
| confirm samples | 2 | 2 | 3 |
| cooldowns trim / kill / reclaim | 2 / 4 / 10 min | 3 / 6 / 15 min | 5 / 10 / 20 min |
| visible tier cap | T3 | T3 | **T1 (trim background only)** |
| freeze when hidden + idle | 2 min | 5 min | 15 min |
| hibernate after frozen | 5 min | 2 h | never (timer) |
| maintenance | every 1 h, idle 5 min | every 2 h, idle 10 min | every 4 h, idle 15 min, hidden only |
| max actions / h | 30 | 24 | 12 |

In the gaming profile, a visible game is never frozen, killed or reclaimed. The only thing that
happens is that background processes are asked to trim. The game itself is never targeted because
it is in the foreground.

## 7. Adaptive sampling and bounded memory

* **Sampling interval.** Calm: 30 s. Elevated, or a tier active: 10 s. High or critical: 5 s.
* **Frozen or hibernated.** No adb traffic at all. The governor polls activity every 1 s, which is
  in-process and cheap, and takes a host-only sample every 60 s.
* **`nudge()`** wakes the loop immediately.
* **Bounded memory.** The governor is O(1) in memory:
  * history is a `RingBuffer<HistoryPoint>` (default 2880 points, 24 h at 30 s);
  * recent events are a ring of 256;
  * each event subscriber buffers only the newest 256 events;
  * the policy's trend windows and action-rate window are fixed-capacity rings;
  * the CSV log (`SampleCSVLog`) rotates by size (4 MiB × 3 files).

A simulated three-day test with `FakeClock` (25,920 ticks) confirms that history stays at
capacity, there is one freeze per night, a hibernate 2 h after each freeze, a resume each morning,
and never more than `maxActionsPerHour` actions in any rolling hour.

## 8. Events

`GovernorEvent.Kind` is emitted for:

* `sampled` (each sample)
* `stateChanged` (engine state)
* `tierChanged` (from, to, reason)
* `actionPlanned`, `actionApplied` (with the `EffectorOutcome`) and `actionFailed`
* `creepDetected`
* `maintenanceRan` (a summary of each step)

## 9. Verification status

Verified on emulator-5580 (API 36.1 Play Store image, shell uid) with the exact commands in this
module:

* the combined sample command;
* `cmd activity help` and `cmd package help`, which list `send-trim-memory` with the AOSP level
  names, `kill`, `kill-all`, `compact system` and `trim-caches`;
* the per-process trim (applied 2/2);
* `cmd activity kill <cached pkg>` (applied);
* `compact system` (applied);
* `trim-caches 1` (applied);
* PSI not readable;
* the error format for a rejected trim: `Exception occurred while executing …` followed by the
  exception, exit 255.

Run the opt-in device tests with
`EMUU_DEVICE_SERIAL=emulator-5580 swift test --filter DeviceIntegrationTests`.

Not verified here:

* Real freeze/thaw and hibernate/resume. These belong to EmuuEngine's `EngineControl`, and this
  module only calls them.
* Whether any T3 mechanism works.
* Behaviour under real sustained guest memory pressure. The device never left the normal level
  during testing.
