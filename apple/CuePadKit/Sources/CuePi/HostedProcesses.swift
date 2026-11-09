#if os(macOS)
import CueStore
import Foundation

/// 托管会话是 CuePad 起的、一个会话一个进程的几家（Claude Code、Codex、Grok、dsh）收尾只走这里，各家只给出这个会话的
/// `SessionLink`（怎么停下这一轮）与进程（怎么请它退出，`ChildProcess.stop()`）：
/// - 请它退出（结束、闲置到点、让出，都经各家的 `SessionLink.end` 到 `retire`）：这一刻就下桥，之后的话经 `AgentRuntime.resume` 接着它；
///   随后先停下在跑的这一轮（`SessionLink.abort`：Agent 自己把被中断的这一轮写进会话记录；Claude Code 2.1.318、dsh 0.2.1 只关输入时不写），
///   至多等 `AgentTimeouts.stop`，再关输入、宽限后 SIGTERM、再宽限后 SIGKILL。下桥后它的 `SessionLink` 照常能停下这一轮，发布到桥上的都落空。
/// - 接着同一会话（`vacate`）：等这个会话上一个进程收完再起新的，同一会话同一时刻只有一个进程写会话文件；在收的不重催，
///   没在收的（输出断了、进程还在）照 `ChildProcess.stop()` 收。有上限：停这一轮的时限加两段宽限。
@MainActor
final class HostedProcesses {
    private struct Entry {
        let process: ChildProcess
        var leaving: Task<Void, Never>?
    }

    private let bridge: PiBridge
    private let timing: Timing
    private var entries: [String: Entry] = [:]

    /// `timing` 量停这一轮的时限；收进程的宽限按起进程时给它的钟（`ChildProcess`）。
    init(bridge: PiBridge, timing: Timing) {
        self.bridge = bridge
        self.timing = timing
    }

    /// 还有进程的会话（含已下桥、还在收的）
    var sessionIDs: Set<String> { Set(entries.keys) }

    /// 起好就登记，不等连上（钩子据此认出托管进程自己的）；进程退出时摘掉。
    func adopt(_ process: ChildProcess, for sessionID: String) {
        entries[sessionID] = Entry(process: process)
        Task { [weak self] in
            _ = await process.waitForExit()
            self?.forget(process, of: sessionID)
        }
    }

    func retire(_ id: PiSession.ID, link: any SessionLink) {
        guard let session = bridge.session(id: id) else { return }
        bridge.detach(id, reason: .closed(reason: "quit"))
        guard var entry = entries[session.sessionID], entry.process.pid == session.pid, entry.leaving == nil else { return }
        let (process, timing) = (entry.process, timing)
        let stopping = Task { try await link.abort(id) }
        entry.leaving = Task {
            _ = try? await withDeadline(AgentTimeouts.stop, timing: timing, orThrow: PiBridgeError.ackTimeout) {
                try await withTaskCancellationHandler { try await stopping.value } onCancel: { stopping.cancel() }
            }
            await process.stop()
        }
        entries[session.sessionID] = entry
    }

    func vacate(_ sessionID: String) async {
        guard let entry = entries[sessionID] else { return }
        if let leaving = entry.leaving { await leaving.value } else { await entry.process.stop() }
        forget(entry.process, of: sessionID)
    }

    /// App 退出：连同在收的一起收（`ChildProcess.stop()` 可以并发调）。
    func stop() -> @concurrent @Sendable () async -> Void {
        let processes = entries.values.map(\.process)
        return { for process in processes { await process.stop() } }
    }

    private func forget(_ process: ChildProcess, of sessionID: String) {
        if entries[sessionID]?.process === process { entries[sessionID] = nil }
    }
}
#endif
