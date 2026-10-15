#if os(macOS)
import CuePi
import CueStore
import Foundation
import SystemConfiguration

/// Mac 端的远程职责：把 Pi 会话的状态写成同步记录（手机据此显示 Pi 在干什么）与目录绑定。
extension AppServices {
    // MARK: Pi 状态记录

    /// 启动时认下这台 Mac 记录的会话（从此没结束的都挂在任务上，见 `CueStore.ownSessions`），再对账上次留下的会话记录（别的 Mac 的不动）：
    /// 进程确实没了的收尾，还在的留给桥重新连上（见 `PiStateRecorder.reset`）。先认再对账：上次还在跑的游离会话先挂上进行中的任务，收尾成历史后也不丢。
    /// 对账之前还没收尾的会话交给桥：重新接上时状态种类没变就沿用原来的起点（`PiBridge.attach`）。
    func resetPiState() async throws {
        try await store.ownSessions(host: hostID)
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
                live[session.id] = session
                if owner(of: session.sessionID)?.id == session.id { try await recordPiState(of: session) }
            case .ended(let session, let reason):
                live[session.id] = nil
                if case .closed(_, let undelivered) = reason, !undelivered.isEmpty { try await failUndelivered(undelivered) }
                if let other = owner(of: session.sessionID) {
                    try await recordPiState(of: other)
                } else {
                    try await piStateRecorder.exited(sessionID: session.sessionID, spoke: session.spoke)
                }
            case .quota(let report): try await store.recordQuota(report, host: hostID)
            case .incompatible: break
            }
        }
    }

    /// 扩展受理了、没被读到会话就关掉了的话（手动压缩期间留着的，退出时还排在 Pi 队列里的）：记为没送到，立即上传给手机。
    private func failUndelivered(_ ids: [String]) async throws {
        let failed = try await store.failAcceptedDeliveries(
            ids.compactMap(UUID.init(uuidString:)), host: hostID, reason: "会话在读到这句之前关掉了")
        for id in failed { Task { await upload(id) } }
    }

    /// 标题：会话自己报了名字或首条消息就用它的，否则用会话索引里的（接上的老会话在第一句话之前就有标题，不必去读会话文件）。
    private func recordPiState(of session: CuePi.PiSession) async throws {
        let title = session.name != nil || session.firstMessage != nil
            ? session.displayName : try await store.piSession(session.sessionID)?.title ?? session.displayName
        let alert = try await piStateRecorder.update(
            sessionID: session.sessionID, state: session.state, detail: session.detail, title: title,
            directory: session.cwd.path(percentEncoded: false),
            projectID: try await store.project(containing: session.cwd)?.id, question: session.question,
            times: PiTimes(stateSince: session.stateSince, busySince: session.busySince), launchToken: session.launchToken,
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
        let name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
        try await store.publishDirectoryBindings(host: host, hostName: name)
        let changes = store.observe { try $0.projectDirectories() }
        follow(reporting: { .syncUnavailable("目录绑定没能同步给手机：\($0)") }) { [store] in
            for try await _ in changes { try await store.publishDirectoryBindings(host: host, hostName: name) }
        }
    }
}
#endif
