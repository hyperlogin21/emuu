import Darwin
import Foundation
import Testing
import ArgumentParser
import EmuuBase
import EmuuFarm
@testable import emuu

@Suite struct FarmCommandParsingTests {
    @Test func runParsesPassthroughCommand() throws {
        let r = try #require(try EmuuCLI.parseAsRoot(["run", "--golden", "base", "--timeout", "60", "--apk", "a.apk", "--apk", "b.apk",
                                                      "--keep-on-failure", "--artifacts", "out", "--", "pytest", "-k", "login"]) as? Run)
        #expect(r.golden == "base" && r.timeout == 60 && r.apks == ["a.apk", "b.apk"] && r.keepOnFailure && r.artifacts == "out")
        #expect(Array(r.command.drop(while: { $0 == "--" })) == ["pytest", "-k", "login"])
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["run"]) }
    }

    @Test func farmUpSizeAndPolicies() throws {
        let up = try #require(try EmuuCLI.parseAsRoot(["farm", "up", "--size", "auto", "--heal-leased", "report", "--release-mode", "recycle"]) as? FarmUp)
        #expect(up.size == .auto && up.healLeased == .report && up.releaseMode == .recycle)
        let fixed = try #require(try EmuuCLI.parseAsRoot(["farm", "up", "--size", "12", "--override-capacity"]) as? FarmUp)
        #expect(fixed.size == .fixed(12) && fixed.overrideCapacity)
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["farm", "up", "--size", "0"]) }
        let acq = try #require(try EmuuCLI.parseAsRoot(["farm", "acquire", "--wait", "--timeout", "30", "--json", "--holder-pid", "123"]) as? FarmAcquire)
        #expect(acq.wait && acq.timeout == 30 && acq.json && acq.holderPid == 123)
        let rel = try #require(try EmuuCLI.parseAsRoot(["farm", "release", "L-1", "--recycle"]) as? FarmRelease)
        #expect(rel.lease == "L-1" && rel.recycle)
    }

    @Test func healthCommands() throws {
        let r = try #require(try EmuuCLI.parseAsRoot(["reboot", "phone", "--hard", "--wait"]) as? Reboot)
        #expect(r.mode == .hard && r.wait)
        #expect(throws: (any Error).self) { try EmuuCLI.parseAsRoot(["reboot", "phone", "--hard", "--cold"]) }
        #expect((try EmuuCLI.parseAsRoot(["reboot", "phone"]) as? Reboot)?.mode == .soft)
        #expect(Health.exitCode(.healthy) == 0 && Health.exitCode(.hung) == 2 && Health.exitCode(.dead) == 3)
        let s = try #require(try EmuuCLI.parseAsRoot(["start", "phone", "--detach", "--self-heal"]) as? Start)
        #expect(s.childArguments(id: try InstanceID(validating: "phone")).contains("--self-heal"))
    }

    @Test func controlRequestCarriesRebootMode() throws {
        let data = try JSONEncoder().encode(ControlRequest(command: .reboot, rebootMode: "cold"))
        let back = try JSONDecoder().decode(ControlRequest.self, from: data)
        #expect(back.command == .reboot && back.rebootMode == "cold")
    }

    @Test func statusDocumentShape() throws {
        let s = FarmState(pool: "p", golden: "g", size: 2, policy: FarmPolicy(), now: Date(timeIntervalSince1970: 0))
        let doc = FarmStatusDocument(pools: [.init(daemonAlive: true, capacity: nil, state: s)])
        let obj = try #require(try JSONSerialization.jsonObject(with: JSONText.encoder(pretty: false).encode(doc)) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 1)
        let pool = try #require((obj["pools"] as? [[String: Any]])?.first)
        #expect(pool["daemonAlive"] as? Bool == true)
        #expect((pool["state"] as? [String: Any])?["golden"] as? String == "g")
    }
}

/// `emuu run`'s child handling: exit status passthrough, timeout, device loss and cleanup of the whole group.
@Suite struct RunChildTests {
    @Test func exitCodePassesThrough() async throws {
        let pid = try ChildCommand.spawn(["/bin/sh", "-c", "exit 3"], environment: ["PATH": "/bin:/usr/bin"])
        #expect(await ChildCommand.wait(pid: pid, timeout: .seconds(10), lost: { nil }) == .exited(3))
    }

    @Test func environmentReachesTheCommand() async throws {
        let pid = try ChildCommand.spawn(["/bin/sh", "-c", "test \"$ANDROID_SERIAL\" = emulator-5554"],
                                         environment: ["PATH": "/bin:/usr/bin", "ANDROID_SERIAL": "emulator-5554"])
        #expect(await ChildCommand.wait(pid: pid, timeout: .seconds(10), lost: { nil }) == .exited(0))
    }

    @Test func timeoutKillsTheWholeProcessGroup() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("emuu-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        // The grandchild writes its pid; after the timeout it must be gone too.
        let pid = try ChildCommand.spawn(["/bin/sh", "-c", "sleep 30 & echo $! > \(marker.path); wait"], environment: ["PATH": "/bin:/usr/bin"])
        let t0 = ContinuousClock.now
        #expect(await ChildCommand.wait(pid: pid, timeout: .milliseconds(800), lost: { nil }) == .timedOut)
        #expect(ContinuousClock.now - t0 < .seconds(8))
        let grandchild = Int32((try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        #expect(grandchild > 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(kill(grandchild, 0) != 0)
    }

    @Test func deviceLossStopsTheCommand() async throws {
        let pid = try ChildCommand.spawn(["/bin/sleep", "30"], environment: ["PATH": "/bin:/usr/bin"])
        let calls = Locked(0)
        let outcome = await ChildCommand.wait(pid: pid, timeout: nil) {
            calls.withLock { $0 += 1 }
            return "adb shell does not answer"
        }
        #expect(outcome == .deviceLost("adb shell does not answer"))
        #expect(kill(pid, 0) != 0)
    }

    @Test func forwardedSignalReachesTheCommand() async throws {
        let pid = try ChildCommand.spawn(["/bin/sh", "-c", "trap 'exit 5' TERM; sleep 20 & wait"], environment: ["PATH": "/bin:/usr/bin"])
        try await Task.sleep(for: .milliseconds(300))
        kill(-pid, SIGTERM)
        let t0 = ContinuousClock.now
        #expect(await ChildCommand.wait(pid: pid, timeout: .seconds(15), lost: { nil }) == .exited(5))
        #expect(ContinuousClock.now - t0 < .seconds(5))
    }

    @Test func missingCommandFails() {
        #expect(throws: CLIError.self) { try ChildCommand.spawn(["/nonexistent/cmd"], environment: [:]) }
    }
}
