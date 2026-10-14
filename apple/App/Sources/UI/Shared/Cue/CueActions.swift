import CueStore
import Foundation

/// 界面对 Cue 的写入（iOS 与 Mac 同一份）：都只写库。对 Cue 说话就是写一条你的消息，Cue 住的那台 Mac 的管理器读到再交给它；
/// 写完立即上传这一条（手机与别的 Mac 上不等引擎自己排）。
extension Workspace {
    /// 跟随 Cue 的现状（窗口根视图调用）。
    func observeCue() async {
        #if os(macOS)
        cue.attach(services.cue)
        #endif
        do {
            try await cue.follow(services.store)
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    /// 对 Cue 说一句（文字可带图片，存储格式）。
    func sayToCue(_ stored: String) async throws {
        let message = try await services.store.addCueMessage(.you, text: stored)
        await services.upload(message.id)
    }

    /// 把输入框里的草稿说给 Cue：图片在这里写进图片库。
    func sayToCue(_ draft: ComposerDraft) async throws {
        try await sayToCue(try draft.stored(in: services.store.files))
    }

    /// 回答 Cue 的一条"等你"。
    func answerCue(_ message: CueMessage, _ answer: String) {
        let store = services.store, services = services, id = message.id
        attempt {
            try await store.answerCueMessage(id, answer: answer)
            await services.upload(id)
        }
    }

    /// 交给 Cue 跟进，或收回自己做（记在顶层任务上）。
    func setCueFollows(_ task: UUID, _ on: Bool) {
        let store = services.store, services = services, name = cue.name
        attempt {
            let top = try await store.setCueFollows(task, on)
            await services.upload(top.id)
            self.say(on ? "已交给 \(name)" : "已收回，你自己做")
        }
    }

    /// 这个会话（记录 id）绑着的任务由 Cue 跟进。
    func cueFollows(sessionRecord: UUID) async throws -> Bool {
        guard let sessionID = services.liveSessions.items?.first(where: { $0.state.id == sessionRecord })?.state.sessionID else { return false }
        return try await CueWaiting.followed(sessionID, in: services.store)
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
