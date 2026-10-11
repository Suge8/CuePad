#if os(macOS)
import CuePi
import CueStore
import Foundation
import SystemConfiguration

/// Mac 端的远程职责：把 Pi 会话的状态写成同步记录（手机据此显示 Pi 在干什么）与目录绑定。
extension AppServices {
    // MARK: Pi 状态记录

    /// 启动时清掉这台 Mac 上次没来得及结束的会话记录（别的 Mac 的不动）。
    func resetPiState() async throws {
        try await piStateRecorder.reset()
    }

    /// 把 Pi 桥的会话变化写成同步记录，直到流结束。一个会话一条记录：同一会话同时有两个进程（后台托管的那个正在让给
    /// 用户在终端里打开的那个）时，记录跟着用户的；其中一个结束而另一个还在时，记录不标为结束。
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
                    try await piStateRecorder.end(sessionID: session.sessionID)
                }
            case .incompatible: break
            }
        }
    }

    /// 扩展受理了、还没交给 Pi 会话就关掉了的话（手动压缩期间留着的）：记为没送到，立即上传给手机。
    private func failUndelivered(_ ids: [String]) async throws {
        let failed = try await store.failAcceptedDeliveries(
            ids.compactMap(UUID.init(uuidString:)), host: hostID, reason: "会话在压缩上下文时关掉了，这句没送进去")
        for id in failed { Task { await upload(id) } }
    }

    private func recordPiState(of session: CuePi.PiSession) async throws {
        let alert = try await piStateRecorder.update(
            sessionID: session.sessionID, state: session.state, detail: session.detail, title: session.displayName,
            folder: CueStore.folderName(ofWorkingDirectory: session.cwd.path(percentEncoded: false)),
            projectID: try await store.project(containing: session.cwd)?.id, question: session.question,
            times: PiTimes(stateSince: session.stateSince, busySince: session.busySince), launchToken: session.launchToken,
            hosted: session.hosted, subagents: session.subagents, modelState: session.modelState, context: session.context,
            commands: session.commands)
        // 带通知标志的写入立即上传（不阻塞后面的会话变化）：通知等引擎自动调度要几十秒，期间状态还可能前进而把它作废
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
        tasks.append(Task { [store, weak self] in
            do {
                for try await _ in changes { try await store.publishDirectoryBindings(host: host, hostName: name) }
            } catch {
                self?.reportIssue(.syncUnavailable("目录绑定没能同步给手机：\(error)"))
            }
        })
    }
}
#endif
