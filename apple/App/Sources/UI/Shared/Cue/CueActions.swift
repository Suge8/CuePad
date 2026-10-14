import CueStore
import Foundation

/// 界面对 Cue 的写入（iOS 与 Mac 同一份）：都只写库，写完立即上传这一条（手机与别的 Mac 上不等引擎自己排）。
/// 对 Cue 说话就是写一条你的消息（经 `Workspace.speak`），Cue 住的那台 Mac 的管理器读到再交给它。
extension Workspace {
    /// 跟随 Cue 的现状（窗口根视图调用）。
    func observeCue() async {
        let services = services
        cue.relay = { host in services.relay(to: host) }
        do {
            try await cue.follow(services.store)
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    /// 结束 Cue 的一条"等你"：选一项或关掉。对验收答"收下"就是收下：Store 同时完成任务，结束做完了的会话的请求写下就上传（同点圆圈）。
    func endCueQuestion(_ message: CueMessage, _ end: CueQuestionEnd) async throws {
        let ended = try await services.store.endCueQuestion(message.id, end)
        for request in ended { _ = services.uploaded(request) }
        await services.upload(message.id)
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
