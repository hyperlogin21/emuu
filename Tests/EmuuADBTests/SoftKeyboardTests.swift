import Testing
import Foundation
import EmuuBase
import EmuuTestSupport
@testable import EmuuADB

@Suite struct SoftKeyboardTests {
    // Real `dumpsys input_method | grep -E -A1 …` output from android-36.1.
    static let shownFocused = """
          curEditorInfo:
            inputType=0x2060 imeOptions=0x6 privateImeOptions=com.google.android.inputmethod.latin.requestPhoneticOutput
    --
          mInputShown=true
          mLastImeTargetWindow=android.os.BinderProxy@eee9dcc
    """
    static let hiddenFocused = """
          curEditorInfo:
            inputType=0x2060 imeOptions=0x6 privateImeOptions=com.google.android.inputmethod.latin.requestPhoneticOutput
    --
          mInputShown=false
          mLastImeTargetWindow=android.os.BinderProxy@eee9dcc
    """
    static let noEditor = """
          curEditorInfo:
            inputType=0x0 imeOptions=0x0 privateImeOptions=null
    --
          mInputShown=false
    """
    static let ui = """
    <?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" class="android.widget.FrameLayout" focused="false" bounds="[0,0][720,1600]"><node index="0" text="ab" resource-id="" class="android.widget.EditText" package="com.google.android.contacts" content-desc="" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="true" scrollable="false" long-clickable="true" password="false" selected="false" bounds="[96,667][624,784]" drawing-order="1" hint="First name" /></node></hierarchy>UI hierchary dumped to: /dev/tty
    """

    @Test func commands() {
        #expect(SoftKeyboardCommands.setting(show: true) == "settings put secure show_ime_with_hard_keyboard 1")
        #expect(SoftKeyboardCommands.setting(show: false) == "settings put secure show_ime_with_hard_keyboard 0")
        #expect(SoftKeyboardCommands.hide == "input keyevent 4")
        #expect(SoftKeyboardCommands.tap(x: 360, y: 725) == "input tap 360 725")
        #expect(SoftKeyboardCommands.state.hasPrefix("dumpsys input_method"))
    }

    @Test func parsesState() {
        #expect(SoftKeyboardCommands.parseState(Self.shownFocused) == SoftKeyboardState(imeShown: true, editorFocused: true))
        #expect(SoftKeyboardCommands.parseState(Self.hiddenFocused) == SoftKeyboardState(imeShown: false, editorFocused: true))
        #expect(SoftKeyboardCommands.parseState(Self.noEditor) == SoftKeyboardState(imeShown: false, editorFocused: false))
        #expect(SoftKeyboardCommands.parseState("") == SoftKeyboardState(imeShown: false, editorFocused: false))
    }

    @Test func findsFocusedEditable() {
        let c = SoftKeyboardCommands.focusedEditableCenter(uiXML: Self.ui)
        #expect(c?.x == 360 && c?.y == 725)
        #expect(SoftKeyboardCommands.focusedEditableCenter(uiXML: "<hierarchy/>") == nil)
    }

    @Test func showTapsTheFocusedField() async throws {
        let shell = FakeDeviceShell()
        shell.onShell(prefix: "settings put", reply: .ok())
        shell.onShell(prefix: "dumpsys input_method", reply: .ok(Self.hiddenFocused))
        shell.onShell(prefix: "uiautomator dump", reply: .ok(Self.ui))
        shell.onShell(prefix: "input tap", reply: .ok())
        let outcome = try await SoftKeyboard(shell: shell).apply(show: true)
        #expect(outcome == .shown)
        #expect(shell.shellCommands.contains("settings put secure show_ime_with_hard_keyboard 1"))
        #expect(shell.shellCommands.last == "input tap 360 725")
    }

    @Test func hideSendsBackOnlyWhenShown() async throws {
        let shell = FakeDeviceShell()
        shell.onShell(prefix: "settings put", reply: .ok())
        shell.onShell(prefix: "dumpsys input_method", reply: .ok(Self.shownFocused), .ok(Self.hiddenFocused))
        shell.onShell(prefix: "input keyevent", reply: .ok())
        let kb = SoftKeyboard(shell: shell)
        #expect(try await kb.apply(show: false) == .hidden)
        #expect(shell.shellCommands.contains("input keyevent 4"))
        // Already hidden: no BACK (it would navigate back in the app).
        #expect(try await kb.apply(show: false) == .unchanged)
        #expect(shell.shellCommands.filter { $0 == "input keyevent 4" }.count == 1)
        #expect(try await kb.enforceHidden() == false)
    }

    @Test func showWithoutTextFieldDoesNothingOnScreen() async throws {
        let shell = FakeDeviceShell()
        shell.onShell(prefix: "settings put", reply: .ok())
        shell.onShell(prefix: "dumpsys input_method", reply: .ok(Self.noEditor))
        #expect(try await SoftKeyboard(shell: shell).apply(show: true) == .noTextField)
        #expect(!shell.shellCommands.contains { $0.hasPrefix("input") || $0.hasPrefix("uiautomator") })
    }
}
