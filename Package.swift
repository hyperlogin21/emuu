// swift-tools-version: 6.0
// Emuu — a lightweight, memory-governed front end for the Android Emulator engine (macOS, Apple Silicon).
// See docs/ARCHITECTURE.md before changing target layout.
import PackageDescription

let package = Package(
    name: "Emuu",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "emuu", targets: ["emuu"]),
        .executable(name: "EmuuApp", targets: ["EmuuApp"]),
        .library(name: "EmuuBase", targets: ["EmuuBase"]),
        .library(name: "EmuuEngine", targets: ["EmuuEngine"]),
        .library(name: "EmuuADB", targets: ["EmuuADB"]),
        .library(name: "EmuuMemory", targets: ["EmuuMemory"]),
        .library(name: "EmuuGRPC", targets: ["EmuuGRPC"]),
        .library(name: "EmuuDisplay", targets: ["EmuuDisplay"]),
        .library(name: "EmuuTestSupport", targets: ["EmuuTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Shared contracts: models, protocols, ProcessRunner, logging, paths. Depends on nothing.
        .target(name: "EmuuBase"),

        // Test doubles (FakeProcessRunner, FakeClock, FakeDeviceShell, FakeEngineControl) for every test target.
        .target(name: "EmuuTestSupport", dependencies: ["EmuuBase"]),

        .target(name: "EmuuEngine", dependencies: ["EmuuBase"]),
        .target(name: "EmuuADB", dependencies: ["EmuuBase"]),
        .target(name: "EmuuMemory", dependencies: ["EmuuBase"]),
        // shm_open(2) wrapper (variadic in C, so Swift cannot call it directly).
        .target(name: "CEmuuShim"),
        // Minimal gRPC-over-HTTP/2 (h2c) client + the emulator's EmulatorController messages. No external
        // dependencies, no protoc: the few messages are hand-encoded (see EmulatorMessages.swift).
        .target(name: "EmuuGRPC", dependencies: ["EmuuBase", "CEmuuShim"]),
        .target(name: "EmuuDisplay", dependencies: ["EmuuBase", "EmuuGRPC"]),

        .executableTarget(
            name: "emuu",
            dependencies: [
                "EmuuBase", "EmuuEngine", "EmuuADB", "EmuuMemory", "EmuuGRPC", "EmuuDisplay",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "EmuuApp",
            dependencies: ["EmuuBase", "EmuuEngine", "EmuuADB", "EmuuMemory", "EmuuGRPC", "EmuuDisplay"],
            // Control-strip icons (SVG, loaded by `IconLibrary`; scripts/make-app.sh copies the bundle).
            resources: [.copy("Resources/Icons")]
        ),

        .testTarget(name: "EmuuBaseTests", dependencies: ["EmuuBase", "EmuuTestSupport"]),
        .testTarget(name: "EmuuEngineTests", dependencies: ["EmuuEngine", "EmuuTestSupport"]),
        .testTarget(name: "EmuuADBTests", dependencies: ["EmuuADB", "EmuuTestSupport"]),
        .testTarget(name: "EmuuMemoryTests", dependencies: ["EmuuMemory", "EmuuTestSupport"]),
        .testTarget(name: "EmuuGRPCTests", dependencies: ["EmuuGRPC", "EmuuTestSupport"]),
        .testTarget(name: "EmuuDisplayTests", dependencies: ["EmuuDisplay", "EmuuTestSupport"]),
        // CLI tests import the executable target (`@testable import emuu`).
        .testTarget(name: "emuuTests", dependencies: ["emuu", "EmuuTestSupport"]),
        // App logic tests import the app executable (`@testable import EmuuApp`).
        .testTarget(name: "EmuuAppTests", dependencies: ["EmuuApp", "EmuuTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
