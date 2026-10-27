#if os(macOS)
import CueStore
import Foundation

/// CuePad 托管的 ACP 会话，一个进程一个会话（各家的接入持有一个）：起 Agent 的 ACP 服务、握手、开新会话或接着已结束的、上桥，
/// 连同握手至多 `AgentTimeouts.launch`，超时或中途出错时收掉进程再抛；进程退出时从登记里拿掉，`stop` 收掉全部。
/// 各家只给事实：怎么起（`launching`：可执行文件与环境，按开会话要的模型，有的家握手时就按它判定能否收图）、方言、会话文件在哪。
/// 接着一个会话时先看桥上：已经在线、是托管的就用它，开在别处（终端里）的不接——同一个会话两边各写各的。
@MainActor
final class ACPHost {
    struct Launching {
        var executable: URL
        var environment: [String: String]
        var dialect: any ACPDialect
    }

    private let agent: AgentKind
    private let bridge: PiBridge
    private let timing: Timing
    /// 起进程要的（`model` 是开会话时要的模型，`AgentKind.modelRef` 的写法；接着旧会话时为 nil）；没装抛 `notInstalled`
    private let launching: (_ model: String?) async throws -> Launching
    private let sessionFile: (_ cwd: URL, _ sessionID: String) -> URL
    /// 会话 id → 托管它的进程上的会话（进程还在的）
    private var sessions: [String: ACPSession] = [:]

    init(
        _ agent: AgentKind, bridge: PiBridge, timing: Timing, launching: @escaping (_ model: String?) async throws -> Launching,
        sessionFile: @escaping (_ cwd: URL, _ sessionID: String) -> URL
    ) {
        self.agent = agent
        self.bridge = bridge
        self.timing = timing
        self.launching = launching
        self.sessionFile = sessionFile
    }

    /// 在托管的会话 id
    var sessionIDs: Set<String> { Set(sessions.keys) }

    func open(in directory: URL, launchToken: String, model: String? = nil) async throws -> PiSession.ID {
        try await host(in: directory, model: model, launchToken: launchToken) { try await $0.open(in: directory) }
    }

    func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        if let live = bridge.session(sessionID: session.id) {
            guard live.hosted else { throw AgentRuntimeError.openElsewhere }
            return live.id
        }
        let directory = URL(filePath: session.cwd, directoryHint: .isDirectory)
        return try await host(in: directory, model: nil, launchToken: nil) { try await $0.load(session.id, in: directory) }
    }

    func stop() -> @concurrent @Sendable () async -> Void {
        let processes = sessions.values.compactMap(\.connection?.process)
        sessions = [:]
        return { for process in processes { await process.stop() } }
    }

    private func host(
        in directory: URL, model: String?, launchToken: String?, open: @escaping @MainActor (ACPSession) async throws -> Void
    ) async throws -> PiSession.ID {
        let launch = try await launching(model)
        let session = ACPSession(dialect: launch.dialect, bridge: bridge)
        do {
            try await withDeadline(AgentTimeouts.launch, timing: timing, orThrow: AgentRuntimeError.launchTimedOut(agent)) {
                try await session.launch(launch.executable, environment: launch.environment, directory: directory)
                try await open(session)
            }
        } catch {
            await session.connection?.shutdown()
            throw error
        }
        guard let sessionID = session.sessionID, let process = session.connection?.process else { throw AgentRuntimeError.launchFailed(agent, "") }
        var state = PiSession(
            id: "\(sessionID).\(process.pid)", sessionID: sessionID, agent: agent, sessionFile: sessionFile(directory, sessionID), pid: process.pid,
            cwd: directory, terminal: PiTerminal(), state: .settled, stateSince: .now)
        state.hosted = true
        state.launchToken = launchToken
        session.attach(state)
        sessions[sessionID] = session
        Task { [weak self] in
            _ = await process.exited()
            if self?.sessions[sessionID] === session { self?.sessions[sessionID] = nil }
        }
        return state.id
    }
}
#endif
