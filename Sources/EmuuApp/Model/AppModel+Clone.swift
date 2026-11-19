import Foundation
import EmuuBase
import EmuuEngine
import EmuuFarm

/// A clone that could not be made (shown in the clone sheet).
struct CloneFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// "Clone…" in the library: copies an instance with everything on it (Google sign-in, apps, settings) through
/// `InstanceCloner` (APFS clone + the farm's snapshot fix-ups). A running source is hibernated for the copy and
/// resumed afterwards, only after the user confirmed that in the sheet.
extension AppModel {
    /// What cloning `id` needs right now. `consent` = the user agreed to hibernate a running source briefly.
    func clonePlan(for id: InstanceID, consent: Bool) -> CloneSourcePlan {
        guard let row = rows.first(where: { $0.id == id }) else { return .refuse("\(id) is not in the library any more.") }
        let name = row.config.displayName.isEmpty ? id.rawValue : row.config.displayName
        var foreign: String?
        if let s = session(for: id) {
            // The app can hibernate an engine a CLI supervisor governs, but resuming it here would start a second
            // engine owner next to that supervisor.
            if s.isCLISupervised { foreign = "the emuu CLI" }
        } else if let owner = row.otherOwner {
            foreign = owner.ownerKind == .cli ? "the emuu CLI (pid \(owner.ownerPID))" : "another Emuu app (pid \(owner.ownerPID))"
        }
        return CloneSourcePlan.decide(state: row.state, mayPause: consent, foreignOwner: foreign, name: name)
    }

    /// "phone copy", "phone copy 2", …
    func suggestedCloneName(for id: InstanceID) -> String {
        let source = rows.first(where: { $0.id == id })?.config.displayName ?? id.rawValue
        return CloneNaming.suggestedDisplayName(source: source.isEmpty ? id.rawValue : source,
                                                existingDisplayNames: Set(rows.map(\.config.displayName)),
                                                existingIDs: Set(rows.map(\.id.rawValue)))
    }

    /// Makes the copy and returns its id. `progress` gets short status lines for the sheet.
    func cloneInstance(_ id: InstanceID, displayName: String, progress: @escaping @MainActor (String) -> Void) async throws -> InstanceID {
        guard let env else { throw CloneFailure(message: "The Android SDK was not found.") }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CloneFailure(message: "Enter a name for the copy.") }
        await reload()
        let source = try env.store.load(id)
        let sourceName = source.displayName.isEmpty ? id.rawValue : source.displayName
        let existing = Set(env.store.list().map(\.id.rawValue))
        let target = try CloneNaming.instanceID(forDisplayName: name, existingIDs: existing)
        let ports = try ClonePorts.choose(requested: nil, source: source.ports,
                                          fixedByOthers: Set(env.store.list().compactMap { $0.ports?.console }),
                                          isFree: { PortAllocator.isPortFree($0) })

        var paused = false
        var reopen = false
        var refreeze = false
        switch clonePlan(for: id, consent: true) {
        case .refuse(let why):
            throw CloneFailure(message: why)
        case .copyNow:
            break
        case .hibernateCopyResume(let wasFrozen):
            reopen = session(for: id) != nil || windowControllers[id] != nil
            refreeze = wasFrozen && !reopen   // an attached session is governed again after resume
            progress("Hibernating \(sourceName) (saving its state)…")
            log("clone: hibernating \(id) for a copy to \(target)")
            await finish(id, .hibernate)
            let state = await (try env.engine(for: id)).refresh()
            guard state == .hibernated || state == .stopped else {
                throw CloneFailure(message: "\(sourceName) could not be hibernated (it is \(state)); nothing was copied.")
            }
            paused = true
        }

        progress("Copying \(sourceName)…")
        let store = env.store
        let outcome: Result<InstanceCloneResult, Error> = await Task.detached {
            Result { try InstanceCloner(store: store).clone(id, to: target, displayName: name, ports: ports) }
        }.value

        if paused {
            // Back to the state it was in, whether or not the copy worked.
            progress("Resuming \(sourceName)…")
            if reopen {
                openWindow(id)
            } else if let engine = try? await env.engine(for: id) {
                do {
                    try await engine.resume()
                    if refreeze { try await engine.freeze() }
                } catch {
                    libraryError = "\(sourceName) was hibernated for the copy and could not be resumed: \(error.localizedDescription). Press Resume to try again; nothing was lost."
                }
            }
        }
        await reload()
        let result = try outcome.get()
        settings.setProfile(settings.profile(for: id, default: source.memoryProfile), for: target)
        log("clone: \(id) → \(target) in \(result.duration) (copy-on-write \(result.copyOnWrite), snapshot \(result.carriedSnapshot))")
        return target
    }

    private func log(_ text: String) {
        EmuuLogger(category: "app").notice(text)
    }
}
