#if os(macOS)
import CueStore
import Foundation
import os

/// 托管会话是 CuePad 起的、一个会话一个进程的几家（Claude Code、Codex、Grok、dsh）的进程只在这里登记与收尾，各家只给出这个会话的
/// `SessionLink`（怎么停下这一轮）与进程（怎么请它退出，`ChildProcess.stop()`）：
/// - 起进程（开、接着）：先拿 `admission()`，进程一起来（握手之前）就 `admit`，失败时只收自己起的那个。
///   `stop()`（App 退出、接入断开）之后到下一次 `start()` 之前拿不到、登记不上：起到一半的收掉，不留没人收的进程。
/// - 请它退出（结束、闲置到点、让出，都经各家的 `SessionLink.end` 到 `retire`）：这一刻就下桥，之后的话经 `AgentRuntime.resume` 接着它；
///   随后先停下在跑的这一轮（`SessionLink.abort`：Agent 自己把被中断的这一轮写进会话记录；Claude Code 2.1.318、dsh 0.2.1 只关输入时不写），
///   至多等 `AgentTimeouts.stop`，再关输入、宽限后 SIGTERM、再宽限后 SIGKILL。下桥后它的 `SessionLink` 照常能停下这一轮，发布到桥上的都落空。
/// - 接着同一会话（`resume`）：同一会话同时只有一次恢复（`Resumptions`）；先等这个会话的旧进程收完再起新的，
///   同一会话同一时刻只有一个进程写会话文件。在收的不重催，没在收的（输出断了、进程还在）照 `ChildProcess.stop()` 收。
///   有上限：停这一轮的时限加两段宽限。
@MainActor
final class HostedProcesses {
    private static let log = Logger(subsystem: AppIdentity.id, category: "hosted")

    private struct Entry {
        let process: ChildProcess
        var sessionID: String?
        var leaving: Task<Void, Never>?
    }

    /// 拿到它时还没被 `stop()`：登记时这一代还在才登记得上。
    struct Admission {
        fileprivate let era: Int
    }

    private let bridge: Bridge
    private let timing: Timing
    private let resumptions = Resumptions()
    private var entries: [pid_t: Entry] = [:]
    /// 每次 `stop()` 换一代；停着（nil）时拿不到 `Admission`
    private var era: Int? = 0
    private var eras = 0

    /// `timing` 量停这一轮的时限；收进程的宽限按起进程时给它的钟（`ChildProcess`）。
    init(bridge: Bridge, timing: Timing) {
        self.bridge = bridge
        self.timing = timing
    }

    /// 有进程的会话（含已下桥、还在收的）
    var sessionIDs: Set<String> { Set(entries.values.compactMap(\.sessionID)) }

    func start() {
        if era == nil { era = eras }
    }

    /// 停着时抛 `CancellationError`。
    func admission() throws -> Admission {
        guard let era else { throw CancellationError() }
        return Admission(era: era)
    }

    /// 进程一起来就登记（不等握手、不等连上：`stop()` 也收得到它）；进程退出时摘掉。
    /// `admission` 之后被 `stop()` 过就不登记：收掉它，抛 `CancellationError`。开新会话时会话 id 还不知道，连上后 `adopt`。
    func admit(_ process: ChildProcess, for sessionID: String?, _ admission: Admission) async throws {
        guard era == admission.era else {
            await process.stop()
            throw CancellationError()
        }
        entries[process.pid] = Entry(process: process, sessionID: sessionID)
        Task { [weak self] in
            _ = await process.waitForExit()
            if self?.entries[process.pid]?.process === process { self?.entries[process.pid] = nil }
        }
    }

    func adopt(_ process: ChildProcess, as sessionID: String) {
        entries[process.pid]?.sessionID = sessionID
    }

    func retire(_ id: Session.ID, link: any SessionLink) {
        guard let session = bridge.session(id: id) else { return }
        bridge.detach(id, reason: .closed(reason: "quit"))
        guard var entry = entries[session.pid], entry.leaving == nil else { return }
        let (process, timing) = (entry.process, timing)
        let stopping = Task { try await link.abort(id) }
        entry.leaving = Task {
            do {
                try await withDeadline(AgentTimeouts.stop, timing: timing, orThrow: BridgeError.ackTimeout) {
                    try await withTaskCancellationHandler { try await stopping.value } onCancel: { stopping.cancel() }
                }
            } catch {
                // 照样关输入收进程，结束早已报了成功：会话记录里少了这一轮被停下的标记，只留这条记录
                Self.log.error("\(session.agent.rawValue, privacy: .public) \(session.sessionID, privacy: .public) 收尾前没能停下这一轮：\(String(describing: error), privacy: .public)")
            }
            await process.stop()
        }
        entries[session.pid] = entry
    }

    /// 各家的 `resume` 在会话不在桥上时经这里起进程：`start` 在这个会话的旧进程收完之后跑，拿到的 `Admission` 用来登记它起的进程。
    func resume(_ sessionID: String, start: @escaping @MainActor (Admission) async throws -> Session.ID) async throws -> Session.ID {
        try await resumptions.resume(sessionID) { [self] in
            let admission = try admission()
            await vacate(sessionID)
            return try await start(admission)
        }
    }

    private func vacate(_ sessionID: String) async {
        for entry in entries.values where entry.sessionID == sessionID {
            if let leaving = entry.leaving { await leaving.value } else { await entry.process.stop() }
        }
    }

    /// App 退出、接入断开：连同在收的、起到一半的一起收（`ChildProcess.stop()` 可以并发调），到 `start()` 之前不再起。
    func stop() -> @concurrent @Sendable () async -> Void {
        if era != nil {
            eras += 1
            era = nil
        }
        let processes = entries.values.map(\.process)
        return { for process in processes { await process.stop() } }
    }
}
#endif
