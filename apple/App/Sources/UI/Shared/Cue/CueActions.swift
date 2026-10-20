import CueStore
import Foundation
import SwiftUI

/// 界面对 Cue 的写入（iOS 与 Mac 同一份）：都只写库，写完马上传这一条（排在其余待推送前面）。
/// 对 Cue 说话就是写一条你的消息（经 `Workspace.speak`），Cue 运行的那台 Mac 的管理器读到再交给它。
extension Workspace {
    /// 跟随 Cue 的现状（`follow` 里）。
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
        let files = services.store.files
        return speak(to: .cue, from: box) { try $0.stored(in: files) }
    }

    /// 只记下（"对 Cue 说"长按发送）：这句不交给 Cue，记成一条灵感落在默认项目（不选项目，之后在灵感里挪到别的项目或设为任务），
    /// 提示落点；按下输入框立刻空，写不进库时文字与图片放回输入框（期间新打的接在后面）。
    @discardableResult
    func note(from box: Binding<ComposerDraft>) -> Task<Void, Never>? {
        let taken = box.wrappedValue
        let note = CaptureDraft(text: taken.text, images: taken.images.map(\.data))
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

    /// 回答 Cue 的一条"等你"：选一项（不选的话在 Cue 页直接说，见 `CueQuestionEnd`）。选"以后……不用问"时 Store 同时按提问存的范围把它记进允许清单（Cue 的设置），一起上传。
    func answerCueQuestion(_ message: CueMessage, _ choice: String) async throws {
        let allowed = try await services.store.endCueQuestion(message.id, .answered(choice))
        await services.upload(message.id)
        if allowed { await services.upload(CueProfile.recordID) }
    }

    // MARK: 记忆

    func noteCueLine(_ text: String) async throws {
        let line = try await services.store.noteCueLine(text, source: .you).line
        await services.upload(line.id)
    }

    func forgetCueLine(_ id: UUID) {
        let store = services.store, services = services
        attempt {
            try await store.forgetCueLine(id)
            await services.upload(id)
        }
    }

    func pinCueLine(_ id: UUID, _ pinned: Bool) {
        let store = services.store, services = services
        attempt {
            try await store.pinCueLine(id, pinned)
            await services.upload(id)
        }
    }
}
