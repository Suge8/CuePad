import CueStore
import Foundation
import SwiftUI

/// 界面对 Cue 的写入（iOS 与 Mac 同一份）：都只写库，写完马上传这一条（排在其余待推送前面）。
/// 对 Cue 说话就是写一条你的消息（经 `Workspace.speak`），Cue 运行的那台 Mac 的管理器读到再交给它。
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

    /// "对 Cue 说"的发送：Cue 启用了就是对它说（`speak`，它定项目、建任务、开工）；没启用时它听不到，这句记成一条灵感（同 `note`）。
    @discardableResult
    func sayToCue(from box: Binding<ComposerDraft>) -> Task<Void, Never>? {
        guard cue.canHear else { return note(from: box) }
        return speak(to: .cue, from: box) { $0.stored }
    }

    /// 只记下（"对 Cue 说"长按发送）：这句不交给 Cue，记成一条灵感落在默认项目（不选项目，之后在灵感里挪到别的项目或拖进一条任务），
    /// 提示落点；按下输入框立刻空，写不进库时文字与图片放回输入框（期间新打的接在后面）。
    @discardableResult
    func note(from box: Binding<ComposerDraft>) -> Task<Void, Never>? {
        let taken = box.wrappedValue
        let note = CaptureDraft(text: taken.text, files: taken.files)
        guard !note.isEmpty else { return nil }
        box.wrappedValue = ComposerDraft()
        return Task {
            do {
                try await note.save(in: Project.defaultID, workspace: self)
            } catch {
                box.wrappedValue = taken.followed(by: box.wrappedValue, keeping: ComposerDraft())
                fail(error)
            }
        }
    }

    // MARK: 记忆

    /// 记一条（算你说的）；带 `schedule` 是一条定时（定时页的新定时）。
    func noteCueLine(_ text: String, schedule: ScheduleDraft? = nil) async throws {
        let line = try await services.store.noteCueLine(text, source: .you, remindAt: schedule?.next(), repeats: schedule?.repeats).line
        await services.upload(line.id)
    }

    /// 改一条定时（任务气泡与定时页里原地改）。
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
