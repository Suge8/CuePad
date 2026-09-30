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
        let executor = DeliveryExecutor(store: store, hostID: hostID, onIssue: { [weak self] error in
            let message = "处理手机发来的投送请求时读写资料库失败：\(error.localizedDescription)"
            Task { @MainActor in self?.reportIssue(.syncUnavailable(message)) }
        }) { [weak self] request in
            guard let self else { return .failed("这台 Mac 上的 CuePad 正在退出") }
            return await self.execute(request)
        }
        try await executor.start()
        deliveryExecutor = executor
    }

    private func execute(_ request: DeliveryRequest) async -> DeliveryOutcome {
        do {
            try await send(request.content, to: try destination(for: request), card: request.cardID, task: request.taskID)
            return .succeeded
        } catch {
            return .failed(RemoteDeliveryError.describe(error))
        }
    }

    private func destination(for request: DeliveryRequest) throws -> Destination {
        let target = request.target
        switch target.kind {
        case .known(.piSession):
            guard let ref = target.ref, let id = channels.piSessionID(forSession: ref) else {
                throw RemoteDeliveryError.sessionEnded(target.name)
            }
            switch request.mode {
            case .known(.paste): return .piInput(id)
            case .known(.steer): return .pi(id, whenBusy: .steer)
            case .known(.followUp): return .pi(id, whenBusy: .followUp)
            case .known(.send): return .pi(id, whenBusy: nil)
            case .unknown(let raw): throw RemoteDeliveryError.unsupportedTarget(raw) // 执行器已先按失败写回，走不到这里
            }
        case .known(.app):
            guard let bundleID = target.ref else { throw RemoteDeliveryError.unsupportedTarget(target.name) }
            return .app(.bundleID(bundleID), submit: settings.autoSubmit)
        case .known(.clipboard):
            return .clipboard
        case .unknown:
            throw RemoteDeliveryError.unsupportedTarget(target.name)
        }
    }
}

nonisolated enum RemoteDeliveryError: Error {
    case sessionEnded(String)
    case unsupportedTarget(String)

    /// 写回请求、给手机用户看的失败原因。
    static func describe(_ error: any Error) -> String {
        switch error {
        case RemoteDeliveryError.sessionEnded(let name): "Pi 会话「\(name)」已经结束，或不在这台 Mac 上"
        case RemoteDeliveryError.unsupportedTarget(let name): "这台 Mac 不支持发送到「\(name)」"
        case let error as DispatchError:
            switch error {
            case .accessibilityRequired: "这台 Mac 上的 CuePad 没有辅助功能权限，无法投送到其他应用"
            case .noTarget: "这台 Mac 上没有可投送的目标应用"
            case .targetUnavailable: "目标应用没有运行，或没能切到前台"
            case .eventCreateFailed: "无法生成按键事件"
            case .clipboardWriteFailed: "无法写入这台 Mac 的剪贴板"
            }
        case PiBridgeError.unknownSession: "Pi 会话已经结束"
        case PiBridgeError.ackTimeout: "Pi 没有及时确认收到"
        case PiBridgeError.sessionEnded: "发送过程中 Pi 会话结束了"
        case PiBridgeError.rejected(let reason): "Pi 拒绝了这条消息：\(reason)"
        default: error.localizedDescription
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
