import AppKit
import Foundation
import ArgumentParser
import EmuuBase
import EmuuEngine

@main
struct EmuuCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "emuu",
        abstract: "Lightweight, memory-governed Android emulator for Apple Silicon (wraps the Android Emulator engine).",
        discussion: """
        Quick start:
          emuu doctor                 check SDK, engine, Play Store image and adb
          emuu create phone           create an instance (Play Store image, 2 GB)
          emuu start phone --detach   boot it headless with the memory governor
          emuu install game.xapk      install apps and games
          emuu playstore              open the Play Store (sign in on the device)
          emuu mem                    live governor view
          emuu hibernate / resume     give all memory back, come back in ~2 s

        Automation farm:
          emuu golden create base --seal   prepared golden image (quick-boot snapshot)
          emuu farm up --size auto         warm devices; farm acquire / release / status
          emuu run -- ./run-tests.sh       fresh device for one command (ANDROID_SERIAL set)
        """,
        version: Emuu.version,
        subcommands: [
            Doctor.self, Create.self, List.self, Delete.self,
            Start.self, Stop.self, Freeze.self, Thaw.self, Hibernate.self, Resume.self, Status.self,
            Install.self, Apps.self, Launch.self, Uninstall.self, Playstore.self, Screenshot.self, Record.self, Rotate.self, Shell.self,
            Keyboard.self, Automation.self, VideoDecoder.self,
            Health.self, Reboot.self, Heal.self,
            Golden.self, Clone.self, Farm.self, Run.self,
            Logs.self, Mem.self, Bench.self, Paths.self, Debug.self,
        ])

    /// Synchronous entry point so the main thread stays free: it parks in `dispatchMain()` (or, for
    /// `start --window`, in `NSApplication.run()`), which services the main queue, while the command runs
    /// as a detached task. Blocking the main actor with `NSApplication.run()` from inside an async task
    /// would starve every other main-actor job (measured: the window could never be closed).
    static func main() {
        let parsed: ParsableCommand
        do {
            parsed = try parseAsRoot()
        } catch {
            exit(withError: error)
        }
        nonisolated(unsafe) let command = parsed
        let needsAppKit = (command as? Start)?.window == true
        Task.detached {
            await runToCompletion(command)
        }
        if needsAppKit {
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.run()
            }
        }
        dispatchMain()
    }

    /// Runs the command and exits the process, printing `CLIError`/`EmuuError` as one clean line.
    static func runToCompletion(_ command: ParsableCommand) async -> Never {
        do {
            var command = command
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            Foundation.exit(0)
        } catch let error as CLIError {
            Out.err("emuu: \(error.message)")
            Foundation.exit(error.code)
        } catch let error as EmuuError {
            Out.err("emuu: \(describe(error))")
            Foundation.exit(1)
        } catch {
            exit(withError: error)
        }
    }
}

struct Paths: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print Emuu's state directories and SDK search order.")

    func run() throws {
        let paths = EmuuPaths.default()
        Out.line("root:      \(paths.root.path)")
        Out.line("avd home:  \(paths.avdHome.path)")
        Out.line("instances: \(paths.instancesDirectory.path)")
        Out.line("run:       \(paths.runDirectory.path)")
        Out.line("logs:      \(paths.logsDirectory.path)")
        Out.line("sdk search order:")
        for url in SDKDiscovery.candidateRoots() { Out.line("  \(url.path)") }
    }
}
