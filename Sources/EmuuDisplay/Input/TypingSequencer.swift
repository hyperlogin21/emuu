import Foundation
import EmuuGRPC

/// Keeps keyboard (and pointer) input in order when some of it has to go through the guest clipboard, and paces
/// key presses so the guest does not drop them.
///
/// Pacing: key-downs sent back to back are lost — 200 presses in one burst arrived as 168–192 characters, with
/// ≥ 1 ms between presses all 200 arrived (engine 36.4.9, docs/engine-findings.md "Keyboard"). Bursts (input
/// method commits, the emoji picker, held-key repeats while something is queued) therefore leave at most one
/// key-down per `minKeyInterval`; a person typing is far slower and never waits.
///
/// Input-method catch-up: Gboard takes character keys from the hardware keyboard and commits the text
/// asynchronously, while arrows, chords (Ctrl+A, Ctrl+V…), Return and BACK go straight to the app. Sent within
/// ~25 ms of a character they overtook it ("bc" ⌥← "a" became "cab"); with 50 ms between them 4 of 4 runs were
/// right; a character typed right after an arrow could likewise land before the cursor moved. A key therefore
/// waits until `imeSettle` after the last key-down of the other kind (a person switching from letters to arrows
/// is slower than that and never notices).
///
/// Sticky Shift: Android's text fields (`MetaKeyKeyListener`) treat a Shift press whose key they never saw as a
/// lone Shift tap and keep Shift "sticky" for the next key they handle. Gboard takes the letters, so after "X"
/// (Shift+X) the next ← *selected* a character instead of moving (measured: "abcX" ← "a" gave "abca"). Another lone
/// Shift tap clears it, so before a key that goes to the app the sequencer sends one when its model of the field
/// says Shift is sticky (each Shift press without an app key in between toggles it; an app key consumes it).
///
/// Key events go straight to the input stream. Text the guest keyboard cannot type is set as the guest
/// clipboard and pasted with Ctrl+V; everything that arrives meanwhile waits in a queue, so "café au lait"
/// arrives as typed. Measured on engine 36.4.9 (docs/engine-findings.md "Keyboard"): Android reads the
/// clipboard when it *handles* Ctrl+V, which can be after `setClipboard` has returned for the next text; a new
/// clipboard value therefore waits `pasteSettle` after the previous Ctrl+V, and Ctrl+V waits `clipboardSettle`
/// after `setClipboard`.
///
/// Typed text does not leave the guest clipboard changed: the previous value is read before the first paste of a
/// burst and put back once typing has been quiet for `restoreDelay`. ⌘V (`paste(_:restoreClipboard: false)`)
/// keeps the Mac's text there, as before.
@MainActor
public final class TypingSequencer {
    public struct Timing: Sendable {
        public var clipboardSettle: Duration
        public var pasteSettle: Duration
        public var restoreDelay: Duration
        public var minKeyInterval: Duration
        public var imeSettle: Duration
        public init(clipboardSettle: Duration = .milliseconds(40), pasteSettle: Duration = .milliseconds(250),
                    restoreDelay: Duration = .milliseconds(600), minKeyInterval: Duration = .milliseconds(5),
                    imeSettle: Duration = .milliseconds(80)) {
            self.clipboardSettle = clipboardSettle
            self.pasteSettle = pasteSettle
            self.restoreDelay = restoreDelay
            self.minKeyInterval = minKeyInterval
            self.imeSettle = imeSettle
        }
    }

    /// Sends events on the input stream (synchronous, ordered).
    public var send: (([EmulatorInputEvent]) -> Bool)?
    public var setClipboard: (@Sendable (String) async throws -> Void)?
    public var getClipboard: (@Sendable () async throws -> String)?
    public var timing: Timing
    /// Called when a paste could not be done (no engine connection).
    public var onPasteFailed: ((Error) -> Void)?

    private enum Item {
        case events([EmulatorInputEvent])
        case paste(String, restore: Bool)
    }

    private var queue: [Item] = []
    private var running = false
    private var lastPasteKey: ContinuousClock.Instant?
    private var lastKeyDown: ContinuousClock.Instant?
    /// Last key-down the guest's input method handles (a character).
    private var lastIMEKeyDown: ContinuousClock.Instant?
    /// Last key-down that goes straight to the app (arrows, chords, Return, BACK).
    private var lastDirectKeyDown: ContinuousClock.Instant?
    private var lastBarrierKeyDown: ContinuousClock.Instant?
    /// Model of the focused Android text field's Shift state (see "Sticky Shift").
    private var guestShiftHeld = false
    private var shiftUsedByApp = false
    public private(set) var stickyShift = false
    /// evdev codes the guest's input method takes (`KeyEventTranslator.imeHandledKeys`).
    public var imeHandledKeys: Set<Int> = KeyEventTranslator.imeHandledKeys
    /// Guest clipboard before typed text replaced it (nil = nothing to restore).
    private var savedClipboard: String?
    private var restoreTask: Task<Void, Never>?
    private let pasteChord: [EmulatorInputEvent]

    public init(timing: Timing = Timing(), pasteChord: [EmulatorInputEvent]) {
        self.timing = timing
        self.pasteChord = pasteChord
    }

    /// Nothing queued or in flight.
    public var isIdle: Bool { !running && queue.isEmpty }

    /// Sends now, or after the pastes in flight.
    @discardableResult
    public func events(_ events: [EmulatorInputEvent]) -> Bool {
        guard !events.isEmpty else { return true }
        if isIdle, canSendNow(events) {
            for e in events { noteSent(e) }
            return send?(events) ?? false
        }
        queue.append(.events(events))
        pump()
        return true
    }

    /// `barrier`: Backspace, which Gboard takes while it is composing a word and the app gets otherwise — it waits
    /// for both paths and both wait for it.
    private enum KeyClass { case modifier, ime, direct, barrier }

    private func keyClass(_ code: Int) -> KeyClass {
        if code == EvdevKey.leftShift || code == EvdevKey.rightShift { return .modifier }
        if code == EvdevKey.backspace { return .barrier }
        return imeHandledKeys.contains(code) ? .ime : .direct
    }

    private static func keyDownCode(_ e: EmulatorInputEvent) -> Int? {
        if case .key(let k) = e, k.eventType == .keydown { return k.keyCode }
        return nil
    }

    private func noteSent(_ e: EmulatorInputEvent) {
        guard case .key(let k) = e else { return }
        let cls = keyClass(k.keyCode)
        if cls == .modifier {
            if k.eventType == .keydown {
                if !guestShiftHeld { shiftUsedByApp = false }
                guestShiftHeld = true
            } else if k.eventType == .keyup, guestShiftHeld {
                guestShiftHeld = false
                stickyShift = shiftUsedByApp ? false : !stickyShift
            }
        }
        guard k.eventType == .keydown else { return }
        lastKeyDown = .now
        switch cls {
        case .ime: lastIMEKeyDown = .now
        case .direct, .barrier:
            if cls == .direct { lastDirectKeyDown = .now } else { lastBarrierKeyDown = .now }
            if guestShiftHeld { shiftUsedByApp = true } else { stickyShift = false }
        case .modifier: break
        }
    }

    /// Forget the field's sticky Shift (another field got focus by a click).
    public func resetFieldState() {
        if !guestShiftHeld { stickyShift = false }
    }

    private func needsShiftUnstick(_ code: Int) -> Bool {
        [.direct, .barrier].contains(keyClass(code)) && stickyShift && !guestShiftHeld
    }

    /// When a key-down may go out: `minKeyInterval` after the previous one, and a key that bypasses the input
    /// method only `imeSettle` after the last character.
    private func readyTime(for code: Int) -> ContinuousClock.Instant? {
        var ready: ContinuousClock.Instant?
        if timing.minKeyInterval > .zero, let last = lastKeyDown { ready = last + timing.minKeyInterval }
        // Switching between keys the input method handles and keys that go straight to the app: let the other
        // path finish first (either can overtake the other).
        let others: [ContinuousClock.Instant?]
        switch keyClass(code) {
        case .direct: others = [lastIMEKeyDown, lastBarrierKeyDown]
        case .ime: others = [lastDirectKeyDown, lastBarrierKeyDown]
        case .barrier: others = [lastIMEKeyDown, lastDirectKeyDown]
        case .modifier: others = []
        }
        if timing.imeSettle > .zero, let other = others.compactMap({ $0 }).max() {
            let t = other + timing.imeSettle
            ready = max(ready ?? t, t)
        }
        return ready
    }

    /// At most one key-down, and only when it is ready.
    private func canSendNow(_ events: [EmulatorInputEvent]) -> Bool {
        let downs = events.compactMap(Self.keyDownCode)
        if downs.isEmpty { return true }
        if downs.count > 1, timing.minKeyInterval > .zero || timing.imeSettle > .zero { return false }
        if downs.contains(where: needsShiftUnstick) { return false }
        return downs.allSatisfy { code in readyTime(for: code).map { $0 <= .now } ?? true }
    }

    /// Sends events in order, holding each key-down until it is ready (`readyTime`).
    private func sendPaced(_ events: [EmulatorInputEvent]) async {
        var batch: [EmulatorInputEvent] = []
        func waitUntilReady(_ code: Int) async {
            if let ready = readyTime(for: code), ready > .now {
                if !batch.isEmpty { _ = send?(batch); batch.removeAll() }
                try? await Task.sleep(until: ready, clock: .continuous)
            }
        }
        for e in events {
            if let code = Self.keyDownCode(e) {
                if needsShiftUnstick(code) {
                    // A lone Shift tap toggles the field's sticky Shift off before the app sees this key.
                    await waitUntilReady(EvdevKey.leftShift)
                    for tap in [EmulatorInputEvent.key(.evdev(EvdevKey.leftShift, .keydown)), .key(.evdev(EvdevKey.leftShift, .keyup))] {
                        noteSent(tap)
                        batch.append(tap)
                    }
                }
                await waitUntilReady(code)
            }
            noteSent(e)
            batch.append(e)
        }
        if !batch.isEmpty { _ = send?(batch) }
    }

    /// Pastes `text` into the focused field. `restoreClipboard`: typed text (put the guest clipboard back
    /// afterwards); false for ⌘V, which deliberately leaves the Mac's text in the guest clipboard.
    public func paste(_ text: String, restoreClipboard: Bool) {
        guard !text.isEmpty else { return }
        if case .paste(let prev, let r)? = queue.last, r == restoreClipboard {
            queue[queue.count - 1] = .paste(prev + text, restore: r)   // coalesce fast input-method commits
        } else {
            queue.append(.paste(text, restore: restoreClipboard))
        }
        pump()
    }

    public func perform(_ actions: [TypingAction]) {
        for a in actions {
            switch a {
            case .events(let e): events(e)
            case .paste(let s): paste(s, restoreClipboard: true)
            }
        }
    }

    private func pump() {
        guard !running else { return }
        running = true
        restoreTask?.cancel()
        Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            switch item {
            case .events(let e):
                await sendPaced(e)
            case .paste(let text, let restore):
                await doPaste(text, restore: restore)
            }
        }
        running = false
        scheduleRestore()
    }

    private func waitForPreviousPaste() async {
        if let last = lastPasteKey {
            let ready = last + timing.pasteSettle
            if ready > .now { try? await Task.sleep(until: ready, clock: .continuous) }
        }
    }

    private func doPaste(_ text: String, restore: Bool) async {
        guard let setClipboard else { return }
        await waitForPreviousPaste()
        if restore, savedClipboard == nil, let getClipboard {
            savedClipboard = try? await getClipboard()   // unreadable: leave the clipboard as typed
        } else if !restore {
            savedClipboard = nil   // ⌘V: the Mac's text stays in the guest clipboard
        }
        do {
            try await setClipboard(text)
        } catch {
            onPasteFailed?(error)
            return
        }
        try? await Task.sleep(for: timing.clipboardSettle)
        await sendPaced(pasteChord)
        lastPasteKey = .now
    }

    private func scheduleRestore() {
        guard let saved = savedClipboard, let setClipboard else { return }
        restoreTask?.cancel()
        let delay = max(timing.restoreDelay, timing.pasteSettle)
        restoreTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.isIdle, self.savedClipboard == saved else { return }
            self.savedClipboard = nil
            try? await setClipboard(saved)
        }
    }

    /// Waits until everything queued has been sent (tests, self-test).
    public func waitUntilIdle(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !isIdle, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return isIdle
    }
}
