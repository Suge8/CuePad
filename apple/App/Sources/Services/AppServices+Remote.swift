#if os(macOS)
import CuePi
import CueStore
import Foundation

/// Mac 端的远程职责：把 Pi 会话的状态写成同步记录（手机据此显示 Pi 在干什么）与目录绑定。
extension AppServices {
    // MARK: Pi 状态记录

    /// 启动时对账上次留下的会话记录（别的 Mac 的不动）：进程确实没了的收尾，还在的留给桥重新连上（见 `PiStateRecorder.reset`）。
    /// 对账之前还没收尾的会话交给桥：重新接上时状态种类没变就沿用原来的起点（`PiBridge.attach`）。
    func resetPiState() async throws {
        pi.carryOver(try await piStateRecorder.reset { $0.isRunning })
    }

    /// 把 Pi 桥的会话变化写成同步记录，直到流结束。一个会话一条记录：同一会话同时有两个进程（后台托管的那个正在让给
    /// 用户在终端里打开的那个）时，记录跟着用户的；其中一个结束而另一个还在时，记录不标为结束。
    /// 进程都退出时记录怎么处理（历史、歇着、删除）只由 `PiStateRecorder.exited` 定。
    func consumePiChanges(_ changes: AsyncStream<PiSessionChange>) async throws {
        var live: [CuePi.PiSession.ID: CuePi.PiSession] = [:]
        func owner(of sessionID: String) -> CuePi.PiSession? {
            let processes = live.values.filter { $0.sessionID == sessionID }
            return processes.first { !$0.hosted } ?? processes.first
        }
        for await change in changes {
            switch change {
            case .appeared(let session), .stateChanged(let session, _), .infoChanged(let session):
                let previous = live[session.id]
                live[session.id] = session
                if owner(of: session.sessionID)?.id == session.id { try await recordPiState(of: session) }
                if previous?.model != session.model || previous?.availableModels != session.availableModels {
                    try await store.retainQuotaSources(on: hostID, models: live.values.flatMap { $0.availableModels + [$0.model].compactMap { $0 } })
                }
            case .ended(let session, let reason):
                live[session.id] = nil
                if let other = owner(of: session.sessionID) {
                    try await recordPiState(of: other)
                } else if reason != .reload {
                    // 重载不是退出：同一进程马上以新扩展连回来接着写，不先把记录当成进程没了写成被打断或已结束
                    try await piStateRecorder.exited(sessionID: session.sessionID, spoke: session.spoke)
                }
            case .quota(let report): try await store.recordQuota(report, host: hostID)
            case .incompatible: break
            }
        }
    }

    /// 标题：会话自己报了名字或首条消息就用它的，否则用会话索引里的（接上的老会话在第一句话之前就有标题，不必去读会话文件）。
    /// 正自己换上新扩展的（`upgrading`）读不到在做什么，不写：记录留着上一次读到的样子，退出时据此分清是不是做到一半被打断（`exited`）。
    private func recordPiState(of session: CuePi.PiSession) async throws {
        guard !session.upgrading else { return }
        let title = session.name != nil || session.firstMessage != nil
            ? session.displayName : try await store.piSession(session.sessionID)?.title ?? session.displayName
        let alert = try await piStateRecorder.update(
            sessionID: session.sessionID, state: session.state, detail: session.detail, failure: session.failure, title: title,
            directory: session.cwd.path(percentEncoded: false),
            projectID: try await store.project(containing: session.cwd)?.id, question: session.question,
            times: PiTimes(stateSince: session.stateSince, busySince: session.busySince), turnStartedAt: session.turnStartedAt,
            launchToken: session.launchToken,
            hosted: session.hosted, subagents: session.subagents, modelState: session.modelState, context: session.context,
            commands: session.commands, agent: session.agent, process: PiProcess.running(pid: session.pid))
        // 带通知标志的写入立即上传（不阻塞后面的会话变化）：排在其余待推送后面要多等，期间状态还可能前进而把它作废
        if alert != nil {
            let record = PiSessionState.recordID(sessionID: session.sessionID)
            Task { await upload(record) }
        }
    }

    // MARK: 目录绑定

    /// 本机的目录绑定写成同步的目录绑定记录（手机据此知道哪些项目能在哪台 Mac 上开新会话）：先对一次，
    /// 之后本机绑定每次变化时跟上，直到后台任务取消。
    func startDirectoryBindings() async throws {
        let host = hostID
        try await store.publishDirectoryBindings(host: host)
        let changes = store.observe { try $0.projectDirectories() }
        follow(reporting: { .syncUnavailable(String(localized: "目录绑定没能同步给手机：\(String(describing: $0))")) }) { [store] in
            for try await _ in changes { try await store.publishDirectoryBindings(host: host) }
        }
    }
}
#endif
