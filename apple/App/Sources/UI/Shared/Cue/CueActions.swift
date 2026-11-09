import CueStore
import Foundation
import SwiftUI

/// 都只写库，写完马上传这一条（排在其余待推送前面）。
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

    /// Cue 没启用时它听不到，这句记成一条灵感（同 `note`）。
    @discardableResult
    func sayToCue(from box: Binding<ComposerDraft>) -> Task<Void, Never>? {
        guard cue.canHear else { return note(from: box) }
        return speak(to: .cue, from: box) { $0.stored }
    }

    /// 这句不交给 Cue，记成灵感落在默认项目；写不进库时文字与图片放回输入框（期间新打的接在后面）。
    @discardableResult
    func note(from box: Binding<ComposerDraft>) -> Task<Void, Never>? {
        let taken = box.wrappedValue
        guard !taken.isEmpty(accepting: .files) else { return nil }
        let claim = claimImports(taken)
        box.wrappedValue = ComposerDraft()
        return Task {
            let taken = await claim.settled()
            let note = CaptureDraft(text: taken.text, files: taken.files)
            // 附件都没存成（已提示导入失败）又没有字：不建空灵感
            guard !note.isEmpty else { return }
            do {
                try await note.save(in: Project.defaultID, workspace: self)
            } catch {
                box.wrappedValue = taken.followed(by: box.wrappedValue, keeping: ComposerDraft())
                fail(error)
            }
        }
    }

    func noteCueLine(_ text: String, schedule: ScheduleDraft? = nil) async throws {
        let line = try await services.store.noteCueLine(text, source: .you, remindAt: schedule?.next(), repeats: schedule?.repeats)
        await services.upload(line.id)
    }

    func rescheduleCueLine(_ id: UUID, _ draft: ScheduleDraft) {
        let at = draft.next(), repeats = draft.repeats
        writeCueLine(id) { try await $0.rescheduleCueLine(id, at: at, repeats: repeats) }
    }

    func forgetCueLine(_ id: UUID) { writeCueLine(id) { try await $0.forgetCueLine(id) } }

    func pinCueLine(_ id: UUID, _ pinned: Bool) { writeCueLine(id) { try await $0.pinCueLine(id, pinned) } }

    private func writeCueLine(_ id: UUID, _ write: @escaping @Sendable (CueStore) async throws -> Void) {
        let store = services.store, services = services
        attempt {
            try await write(store)
            await services.upload(id)
        }
    }
}
