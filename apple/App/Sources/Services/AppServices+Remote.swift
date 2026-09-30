#if os(macOS)
import CueDispatch
import CuePi
import CueStore
import Foundation

/// Mac 端的远程职责：把 Pi 会话的状态写成同步记录（手机据此显示 Pi 在干什么），
/// 并执行手机发来、指定给这台 Mac 的投送请求。
extension AppServices {
    // MARK: Pi 状态记录

    /// 启动时清掉这台 Mac 上次没来得及结束的会话记录（别的 Mac 的不动）。
    func resetPiState() async throws {
        try await piStateRecorder.reset()
    }

    /// 把 Pi 桥的会话变化写成同步记录，直到流结束。
    func consumePiChanges(_ changes: AsyncStream<PiSessionChange>) async throws {
        for await change in changes {
            switch change {
            case .appeared(let session), .stateChanged(let session, _): try await recordPiState(of: session)
            case .ended(let session, _): try await piStateRecorder.end(sessionID: session.sessionID)
            case .incompatible: break
            }
        }
    }

    private func recordPiState(of session: CuePi.PiSession) async throws {
        let directories = try await store.projectDirectories()
        let (state, detail) = session.state.syncRepresentation
        try await piStateRecorder.update(
            sessionID: session.sessionID, state: state, detail: detail, title: session.cwd.lastPathComponent,
            projectID: PiProjectMatch.project(forDirectory: session.cwd.path, in: directories))
    }

    // MARK: 手机发来的投送请求

    func startDeliveryExecutor() async throws {
        let executor = DeliveryExecutor(store: store, hostID: hostID) { [weak self] request in
            guard let self else { return .failed("这台 Mac 上的 CuePad 正在退出") }
            return await self.execute(request)
        }
        try await executor.start()
        deliveryExecutor = executor
    }

    /// 失败原因写回给手机用户看，取错误自身的说明（各模块的错误都实现了 `LocalizedError`）。
    private func execute(_ request: DeliveryRequest) async -> DeliveryOutcome {
        do {
            try await send(request.content, to: try destination(for: request), card: request.cardID, task: request.taskID)
            return .succeeded
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func destination(for request: DeliveryRequest) throws -> Destination {
        let target = request.target
        switch target.kind {
        case .piSession:
            guard let ref = target.ref, let id = channels.piSessionID(forSession: ref) else {
                throw SendError.sessionNotOnThisMac(target.name)
            }
            return .pi(id, request.mode)
        case .app:
            guard let bundleID = target.ref else { throw SendError.unsupportedTarget(target.name) }
            return .app(.bundleID(bundleID))
        case .clipboard:
            return .clipboard
        case .unknown:
            throw SendError.unsupportedTarget(target.name)
        }
    }
}

extension PiAgentState {
    /// 写进同步记录的状态与一句话说明。
    var syncRepresentation: (state: PiWorkState, detail: String?) {
        switch self {
        case .idle, .done: (.settled, nil)
        case .thinking: (.thinking, nil)
        case .outputting: (.outputting, nil)
        case .tool(let name, _, let detail): (.tool, detail.map { "\(name) · \($0)" } ?? name)
        case .waitingUser(_, let title): (.waitingForUser, title)
        case .error(let message): (.error, message)
        }
    }
}
#endif
