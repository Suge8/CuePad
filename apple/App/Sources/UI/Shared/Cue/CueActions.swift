import CueStore
import Foundation

/// 界面对 Cue 的写入（iOS 与 Mac 同一份）：都只写库，写完马上传这一条（排在其余待推送前面）。
/// 对 Cue 说话就是写一条你的消息（经 `Workspace.speak`），Cue 住的那台 Mac 的管理器读到再交给它。
extension Workspace {
    /// 跟随 Cue 的现状（窗口根视图调用）。
    func observeCue() async {
        let services = services
        do {
            try await cue.follow(services)
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    /// 结束 Cue 的一条"等你"：选一项或关掉。选"以后……都不用问"时 Store 同时记下这条规矩，一起上传。
    func endCueQuestion(_ message: CueMessage, _ end: CueQuestionEnd) async throws {
        let rule = try await services.store.endCueQuestion(message.id, end)
        await services.upload(message.id)
        if let rule { await services.upload(rule.id) }
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
