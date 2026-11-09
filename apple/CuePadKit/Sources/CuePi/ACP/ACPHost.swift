#if os(macOS)
import CueStore
import Foundation

/// 接着一个会话时先看桥上：已经在线、是托管的就用它，开在别处（终端里）的不接——同一个会话两边各写各的；
/// 请退出后还没走的旧进程先收完（`HostedProcesses`）。
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
    private let processes: HostedProcesses

    init(
        _ agent: AgentKind, bridge: PiBridge, timing: Timing, launching: @escaping (_ model: String?) async throws -> Launching,
        sessionFile: @escaping (_ cwd: URL, _ sessionID: String) -> URL
    ) {
        self.agent = agent
        self.bridge = bridge
        self.timing = timing
        self.launching = launching
        self.sessionFile = sessionFile
        processes = HostedProcesses(bridge: bridge, timing: timing)
    }

    var sessionIDs: Set<String> { processes.sessionIDs }

    func open(in directory: URL, launchToken: String, model: String? = nil) async throws -> PiSession.ID {
        try await host(in: directory, model: model, launchToken: launchToken) { try await $0.open(in: directory) }
    }

    func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        if let live = bridge.session(sessionID: session.id) {
            guard live.hosted else { throw AgentRuntimeError.openElsewhere }
            return live.id
        }
        await processes.vacate(session.id)
        let directory = URL(filePath: session.cwd, directoryHint: .isDirectory)
        return try await host(in: directory, model: nil, launchToken: nil) { try await $0.load(session.id, in: directory) }
    }

    func stop() -> @concurrent @Sendable () async -> Void {
        processes.stop()
    }

    private func host(
        in directory: URL, model: String?, launchToken: String?, open: @escaping @MainActor (ACPSession) async throws -> Void
    ) async throws -> PiSession.ID {
        let launch = try await launching(model)
        let session = ACPSession(dialect: launch.dialect, bridge: bridge, processes: processes)
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
        processes.adopt(process, for: sessionID)
        session.attach(state)
        return state.id
    }
}
#endif
