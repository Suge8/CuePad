import CueStore
import Foundation
import SwiftUI

extension Workspace {
    func followCue() async {
        let services = services
        do {
            try await cue.follow(services)
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    @discardableResult
    func sayToCue(from box: Binding<ComposerDraft>) -> Task<Void, Never>? {
        guard cue.canHear else { return note(from: box) }
        return speak(to: .cue, from: box) { $0.stored }
    }

    @discardableResult
    func note(from box: Binding<ComposerDraft>, asTask: Bool = false, in project: UUID = Project.defaultID) -> Task<Void, Never>? {
        let taken = box.wrappedValue
        guard !taken.isEmpty(accepting: .files) else { return nil }
        let claim = claimImports(taken)
        box.wrappedValue = ComposerDraft()
        return Task {
            let taken = await claim.settled()
            let note = CaptureDraft(text: taken.text, files: taken.files)
            guard !note.isEmpty else { return }
            do {
                try await note.save(in: project, asTask: asTask, workspace: self)
            } catch {
                box.wrappedValue = taken.followed(by: box.wrappedValue, keeping: ComposerDraft())
                fail(error)
            }
        }
    }

    func noteCueLine(_ text: String, schedule: ScheduleDraft? = nil) async throws {
        try await services.store.noteCueLine(text, source: .you, remindAt: schedule?.next(), repeats: schedule?.repeats)
    }

    func rescheduleCueLine(_ id: UUID, _ draft: ScheduleDraft) {
        let at = draft.next(), repeats = draft.repeats
        writeCueLine(id) { try await $0.rescheduleCueLine(id, at: at, repeats: repeats) }
    }

    func forgetCueLine(_ id: UUID) { writeCueLine(id) { try await $0.forgetCueLine(id) } }

    func pinCueLine(_ id: UUID, _ pinned: Bool) { writeCueLine(id) { try await $0.pinCueLine(id, pinned) } }

    private func writeCueLine(_ id: UUID, _ write: @escaping @Sendable (CueStore) async throws -> Void) {
        let store = services.store
        attempt { try await write(store) }
    }
}
