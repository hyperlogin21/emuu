import AppKit
import Carbon.HIToolbox
import EmuuBase
import EmuuADB
import EmuuDisplay

/// Keyboard and text-input self-test: `EMUU_APP_SELFTEST=cycle:<id>:1 EMUU_APP_SELFTEST_ONLY=keyboard`.
///
/// Drives the device view's own key entry points (`keyDown`/`keyUp`/`flagsChanged`/`performKeyEquivalent`) with
/// synthesized `NSEvent`s and its `NSTextInputClient` methods the way input methods call them, then reads what
/// Android received from the typing test app (scripts/typing-test-apk, `dev.emuu.typetest`, must be installed):
/// the field's text via `run-as`, and the guest keyboard's pressed-key state via `dumpsys input` (nothing may
/// stay pressed). Works with the screen locked; real key presses and real input-method windows are not involved.
/// The Mac pasteboard is saved before and restored after; its contents are never logged.
@MainActor
struct KeyboardSelfTest {
    let model: AppModel
    let report: (String) -> Void

    private static let pkg = "dev.emuu.typetest"

    func run(_ session: InstanceSession) async {
        guard let client = session.client, let display = session.display,
              let window = model.windowControllers[session.id]?.window else { return report("KEYTEST no window/client") }
        let view = display.view
        guard await sh(client, "pm path \(Self.pkg)").contains("package:") else {
            return report("KEYTEST \(Self.pkg) not installed (scripts/typing-test-apk/build.sh)")
        }
        window.level = .floating
        window.orderFrontRegardless()
        let pasteboard = PasteboardSnapshot()
        defer { pasteboard.restore() }
        let filter = env["EMUU_APP_KEYTEST_FILTER"]
        var passed = 0, failed = 0
        for scenario in KeyTestScenario.all where filter.map({ scenario.name.contains($0) }) ?? true {
            await clearField(client)
            view.typing.resetFieldState()   // the app replaced the field's text (and its Shift state)
            window.makeFirstResponder(view)
            await perform(scenario.steps, view: view, window: window)
            _ = await view.typing.waitUntilIdle(timeout: .seconds(30))
            let expected: String
            var macOK = true
            switch scenario.check {
            case .field(let s): expected = s
            case .fieldAndMacClipboard(let s, let mac):
                expected = s
                macOK = NSPasteboard.general.string(forType: .string) == mac
            }
            let got = await settledText(client, expecting: expected)
            let keys = await pressedKeys(client)
            let ok = got == expected && macOK && keys == "<none>"
            if ok { passed += 1 } else { failed += 1 }
            report("KEYTEST \(ok ? "PASS" : "FAIL") [\(scenario.category)] \(scenario.name): " + describe(expected: expected, got: got)
                   + (macOK ? "" : " macClipboard=mismatch") + " pressed=\(keys)")
        }
        if filter == nil {
            await focusChecks(client, view: view, window: window)
            menuChecks(view: view, window: window)
            await softKeyboardChecks(client, session: session, view: view, window: window)
        }
        window.level = .normal
        report("KEYTEST DONE passed=\(passed) failed=\(failed)")
    }

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    // MARK: Steps

    private func perform(_ steps: [KeyTestScenario.Step], view: EmulatorDisplayView, window: NSWindow) async {
        func ev(_ type: NSEvent.EventType, _ code: Int, _ chars: String, _ mods: NSEvent.ModifierFlags, repeat r: Bool = false) -> NSEvent {
            let base = Self.baseCharacter[code] ?? chars
            let ignoring = mods.contains(.shift) ? (chars.isEmpty ? base.uppercased() : chars) : base
            return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: chars,
                                    charactersIgnoringModifiers: type == .flagsChanged ? "" : ignoring, isARepeat: r, keyCode: UInt16(code))!
        }
        for step in steps {
            switch step {
            case .type(let text):
                var shift = false
                for ch in text {
                    guard let (code, needsShift) = KeyTestScenario.usKeys[ch] else { continue }
                    if needsShift != shift {
                        shift = needsShift
                        view.flagsChanged(with: ev(.flagsChanged, kVK_Shift, "", shift ? KeyTestScenario.shiftFlags : []))
                    }
                    let mods: NSEvent.ModifierFlags = shift ? KeyTestScenario.shiftFlags : []
                    let chars = ch == "\n" ? "\r" : String(ch)
                    view.keyDown(with: ev(.keyDown, code, chars, mods))
                    view.keyUp(with: ev(.keyUp, code, chars, mods))
                }
                if shift { view.flagsChanged(with: ev(.flagsChanged, kVK_Shift, "", [])) }
            case .key(let code, let chars, let mods):
                view.keyDown(with: ev(.keyDown, code, chars, mods))
                view.keyUp(with: ev(.keyUp, code, chars, mods))
            case .hold(let code, let chars, let repeats, let mods):
                view.keyDown(with: ev(.keyDown, code, chars, mods))
                for _ in 0..<repeats {
                    try? await Task.sleep(for: .milliseconds(60))
                    view.keyDown(with: ev(.keyDown, code, chars, mods, repeat: true))
                }
                try? await Task.sleep(for: .milliseconds(60))
                view.keyUp(with: ev(.keyUp, code, chars, mods))
            case .down(let code, let chars, let mods):
                view.keyDown(with: ev(.keyDown, code, chars, mods))
            case .up(let code, let chars):
                view.keyUp(with: ev(.keyUp, code, chars, []))
            case .flags(let code, let mods):
                view.flagsChanged(with: ev(.flagsChanged, code, "", mods))
            case .cmd(let chars, let code, let extra):
                let mods = KeyTestScenario.cmdFlags.union(extra)
                if !view.performKeyEquivalent(with: ev(.keyDown, code, chars, mods)) {
                    report("KEYTEST note: ⌘\(chars.isEmpty ? "key \(code)" : chars) not handled by the view")
                }
            case .insert(let text, let replace):
                view.insertText(text, replacementRange: replace ?? KeyTestScenario.none)
            case .pressAndHold(let text):
                let sel = view.selectedRange()
                view.insertText(text, replacementRange: NSRange(location: sel.location - 1, length: 1))
            case .marked(let text):
                view.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                                   replacementRange: KeyTestScenario.none)
            case .resignKey:
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            case .deactivate:
                NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            case .wait(let ms):
                _ = await view.typing.waitUntilIdle()
                try? await Task.sleep(for: .milliseconds(ms))
            case .macClipboard(let text):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    /// US key → unmodified character (for `charactersIgnoringModifiers`).
    private static let baseCharacter: [Int: String] = {
        var t: [Int: String] = [:]
        for (ch, v) in KeyTestScenario.usKeys where !v.1 { t[v.0] = String(ch) }
        return t
    }()

    // MARK: Device

    private func sh(_ client: ADBClient, _ cmd: String) async -> String {
        (try? await client.shell(cmd, timeout: .seconds(20)).stdoutString) ?? ""
    }

    private func clearField(_ client: ADBClient) async {
        _ = await sh(client, "am start -n \(Self.pkg)/.TypeActivity --ez clear true")
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            if await fieldText(client) == "" { break }
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func fieldText(_ client: ADBClient) async -> String {
        await sh(client, "run-as \(Self.pkg) cat files/text.txt")
    }

    /// The field once Android has handled everything (same text twice 0.8 s apart, or the expected text).
    private func settledText(_ client: ADBClient, expecting expected: String) async -> String {
        try? await Task.sleep(for: .milliseconds(500))
        var last = await fieldText(client)
        for _ in 0..<40 {
            if last == expected { return last }
            try? await Task.sleep(for: .milliseconds(800))
            let now = await fieldText(client)
            if now == last { return now }
            last = now
        }
        return last
    }

    /// Keys the guest keyboard (`qwerty2`) holds down right now.
    private func pressedKeys(_ client: ADBClient) async -> String {
        let out = await sh(client, "dumpsys input | grep -A16 ': qwerty2' | grep -m1 'KeyState (pressed)'")
        return out.components(separatedBy: "KeyState (pressed):").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }

    private func describe(expected: String, got: String) -> String {
        func show(_ s: String) -> String {
            let e = s.replacingOccurrences(of: "\n", with: "⏎")
            return e.count > 60 ? "\(e.prefix(40))…(\(s.count) chars)" : "\"\(e)\""
        }
        if got == expected { return "\(show(got))" }
        let a = Array(expected), b = Array(got)
        let firstDiff = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
        let lo = max(0, firstDiff - 8)
        let around = { (x: [Character]) in String(x[min(lo, x.count)..<min(firstDiff + 8, x.count)]).replacingOccurrences(of: "\n", with: "⏎") }
        return "expected \(show(expected)) got \(show(got)) (lengths \(a.count)/\(b.count), first difference at \(firstDiff): expected …\(around(a))… got …\(around(b))…)"
    }

    // MARK: Focus, menus, soft keyboard

    private func focusChecks(_ client: ADBClient, view: EmulatorDisplayView, window: NSWindow) async {
        // Window becomes key with nothing focused → the device view takes keyboard focus.
        window.makeFirstResponder(nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        let onKey = window.firstResponder === view
        // Click on the device screen → focus (the field is tapped too), and typing works at once.
        window.makeFirstResponder(nil)
        await clearField(client)
        let p = view.mapper.viewPoint(fromVideoX: 360, y: 500)
        let loc = view.convert(p, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { view.mouseDown(with: e) } else { view.mouseUp(with: e) }
        }
        let onClick = window.firstResponder === view
        await perform([.type("ok")], view: view, window: window)
        _ = await view.typing.waitUntilIdle()
        let got = await settledText(client, expecting: "ok")
        report("KEYTEST \(onKey && onClick && got == "ok" ? "PASS" : "FAIL") [Focus] focus-on-key-window=\(onKey) focus-on-click=\(onClick) typed-after-click=\"\(got)\"")
    }

    private func menuChecks(view: EmulatorDisplayView, window: NSWindow) {
        // App and system shortcuts must reach the menus: the view does not claim them.
        let chords: [(String, Int, NSEvent.ModifierFlags)] = [
            ("q", kVK_ANSI_Q, []), ("w", kVK_ANSI_W, []), ("m", kVK_ANSI_M, []), (",", kVK_ANSI_Comma, []), ("h", kVK_ANSI_H, []),
            ("k", kVK_ANSI_K, []), ("i", kVK_ANSI_I, []), ("0", kVK_ANSI_0, []), ("r", kVK_ANSI_R, [.option]), ("c", kVK_ANSI_C, [.option]),
            ("n", kVK_ANSI_N, [.option]), ("s", kVK_ANSI_S, [.shift]), ("a", kVK_ANSI_A, [.shift]), ("p", kVK_ANSI_P, [.shift]),
            ("m", kVK_ANSI_M, [.shift]), (" ", kVK_Space, [.control]),
        ]
        var claimed: [String] = []
        for (c, code, extra) in chords {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: KeyTestScenario.cmdFlags.union(extra), timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: c, charactersIgnoringModifiers: c,
                                     isARepeat: false, keyCode: UInt16(code))!
            if EmulatorDisplayView.commandAction(for: e, hostClipboard: true) != nil { claimed.append("⌘\(c)") }
        }
        report("KEYTEST \(claimed.isEmpty ? "PASS" : "FAIL") [Shortcuts] menu-shortcuts-not-swallowed (⌘Q ⌘W ⌘M ⌘, ⌘H ⌘K ⌘I ⌘0 ⌥⌘R ⌥⌘C ⌥⌘N ⇧⌘S ⇧⌘A ⇧⌘P ⇧⌘M ⌃⌘Space) claimed=\(claimed)")
    }

    private func softKeyboardChecks(_ client: ADBClient, session: InstanceSession, view: EmulatorDisplayView, window: NSWindow) async {
        let kb = SoftKeyboard(shell: client)
        await clearField(client)
        window.makeFirstResponder(view)
        if !session.softKeyboardEnabled { await session.setSoftKeyboard(true) }
        _ = await sh(client, "input tap 360 500")   // like a user tapping the field: Gboard opens
        try? await Task.sleep(for: .seconds(2))
        let tapped = try? await kb.state()
        await perform([.wait(2100), .type("abc")], view: view, window: window)
        try? await Task.sleep(for: .seconds(2))
        let afterTyping = try? await kb.state()
        let text1 = await fieldText(client)
        session.toggleSoftKeyboard()   // the button: show it again on demand
        try? await Task.sleep(for: .seconds(4))
        let afterButton = try? await kb.state()
        let pass = tapped?.imeShown == true && afterTyping?.imeShown == false && afterButton?.imeShown == true && text1 == "abc"
        func d(_ s: SoftKeyboardState?) -> String { s.map { "shown=\($0.imeShown)" } ?? "?" }
        report("KEYTEST \(pass ? "PASS" : "FAIL") [Soft keyboard] tap[\(d(tapped))] typing-on-mac[\(d(afterTyping))] text=\"\(text1)\" button[\(d(afterButton)) enabled=\(session.softKeyboardEnabled)]")
        // Escape → Android Back (closes the keyboard first, then leaves the activity).
        await perform([.wait(2100), .key(kVK_Escape, "\u{1B}")], view: view, window: window)
        try? await Task.sleep(for: .seconds(1))
        let st = try? await kb.state()
        await perform([.key(kVK_Escape, "\u{1B}")], view: view, window: window)
        try? await Task.sleep(for: .seconds(1.5))
        let top = await sh(client, "dumpsys activity activities | grep -m1 topResumedActivity")
        let left = !top.contains(Self.pkg)
        report("KEYTEST \(st?.imeShown == false && left ? "PASS" : "FAIL") [Editing] escape-is-back: first Esc closed keyboard=\(st?.imeShown == false) second Esc left the app=\(left)")
    }
}

/// Copy of the general pasteboard's items, put back after the test (never logged).
@MainActor
final class PasteboardSnapshot {
    private var items: [[NSPasteboard.PasteboardType: Data]] = []

    init() {
        for item in NSPasteboard.general.pasteboardItems ?? [] {
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let d = item.data(forType: type) { copy[type] = d } }
            items.append(copy)
        }
    }

    func restore() {
        let pb = NSPasteboard.general
        pb.clearContents()
        let restored = items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
    }
}
