import Foundation
import EmuuBase

/// Engine-side effector: T3 reclaim, T4 freeze/thaw, T5 hibernate/resume through `EngineControl`.
/// What each call really does (balloon, console `avd stop`, SIGSTOP, snapshot) is EmuuEngine's
/// business; this type only maps outcomes and states.
public struct EngineEffector: MemoryEffector {
    public let engine: any EngineControl

    public init(engine: any EngineControl) {
        self.engine = engine
    }

    public func handles(_ action: GovernorAction) -> Bool {
        switch action {
        case .reclaimGuestMemory, .freeze, .thaw, .hibernate, .resume: return true
        default: return false
        }
    }

    public func apply(_ action: GovernorAction) async throws -> EffectorOutcome {
        switch action {
        case .reclaimGuestMemory(let target):
            switch try await engine.reclaimGuestMemory(targetBytes: target) {
            case .reclaimed(let bytes, let detail): return .applied(detail, reclaimedBytes: bytes)
            case .unsupported(let reason): return .unsupported(reason)
            }
        case .freeze:
            if await engine.state() == .frozen { return .noop("already frozen") }
            try await engine.freeze()
            return .applied("engine frozen")
        case .thaw:
            if await engine.state() == .running { return .noop("already running") }
            try await engine.thaw()
            return .applied("engine thawed")
        case .hibernate:
            let s = await engine.state()
            if s == .hibernated || s == .hibernating { return .noop("already \(s)") }
            try await engine.hibernate()
            return .applied("engine hibernated")
        case .resume:
            if await engine.state() == .running { return .noop("already running") }
            try await engine.resume()
            return .applied("engine resumed")
        default:
            return .unsupported("EngineEffector does not handle \(action)")
        }
    }
}

/// Routes each action to the first effector that handles it.
public struct EffectorRouter: MemoryEffector {
    public let effectors: [any MemoryEffector]

    public init(_ effectors: [any MemoryEffector]) {
        self.effectors = effectors
    }

    public func handles(_ action: GovernorAction) -> Bool { effectors.contains { $0.handles(action) } }

    public func apply(_ action: GovernorAction) async throws -> EffectorOutcome {
        guard let e = effectors.first(where: { $0.handles(action) }) else {
            return .unsupported("no effector for \(action)")
        }
        return try await e.apply(action)
    }
}

/// Result of one maintenance run.
public struct MaintenanceReport: Sendable, Hashable {
    public struct StepResult: Sendable, Hashable {
        public var step: MaintenanceStep
        public var outcome: EffectorOutcome?
        public var error: String?
    }

    public var steps: [StepResult]
    public var reclaimUnsupported: Bool {
        steps.contains { $0.step == .reclaim && $0.outcome?.status == .unsupported }
    }

    public var summary: String {
        steps.map { r in
            if let e = r.error { return "\(r.step.rawValue): error \(e)" }
            guard let o = r.outcome else { return "\(r.step.rawValue): skipped" }
            var s = "\(r.step.rawValue): \(o.status.rawValue)"
            if let b = o.reclaimedBytes, b > 0 { s += " (\(ByteCount.format(b)))" }
            return s
        }.joined(separator: "; ")
    }
}

/// Runs a `MaintenancePlan`: guest steps through `GuestEffector`, reclaim through the engine.
/// A failing step does not stop later steps.
public struct MaintenanceRunner: Sendable {
    public let guest: GuestEffector?
    public let engine: (any MemoryEffector)?

    public init(guest: GuestEffector?, engine: (any MemoryEffector)?) {
        self.guest = guest
        self.engine = engine
    }

    public func run(_ plan: MaintenancePlan) async -> MaintenanceReport {
        var results: [MaintenanceReport.StepResult] = []
        for step in plan.steps {
            if Task.isCancelled { break }
            do {
                let outcome: EffectorOutcome?
                switch step {
                case .trimBackground: outcome = try await guest?.trim(level: .complete, packages: [])
                case .killCached: outcome = try await guest?.killBackground(packages: [])
                case .trimCaches: outcome = try await guest?.trimCaches(desiredFreeBytes: plan.trimCachesDesiredFreeBytes)
                case .compact: outcome = try await guest?.compactSystem()
                case .reclaim: outcome = try await engine?.apply(.reclaimGuestMemory(targetBytes: nil))
                }
                results.append(.init(step: step, outcome: outcome, error: nil))
            } catch {
                results.append(.init(step: step, outcome: nil, error: (error as? LocalizedError)?.errorDescription ?? "\(error)"))
            }
        }
        return MaintenanceReport(steps: results)
    }
}
