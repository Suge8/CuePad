#if os(macOS)
import CueStore
import Foundation

/// 接着一个会话时先看桥上：已经在线就用它；请退出后还没走的旧进程先收完（`HostedProcesses`）。
@MainActor
final class ACPHost {
    struct Launching {
        var executable: URL
        var environment: [String: String]
        var dialect: any ACPDialect
    }

    private let agent: AgentKind
    private let bridge: Bridge
    private let timing: Timing
    /// 起进程要的（`model` 是开会话时要的模型，`AgentKind.modelRef` 的写法；接着旧会话时为 nil）；没装抛 `notInstalled`
    private let launching: (_ model: String?) async throws -> Launching
    private let sessionFile: (_ cwd: URL, _ sessionID: String) -> URL
    private let processes: HostedProcesses

    init(
        _ agent: AgentKind, bridge: Bridge, timing: Timing, launching: @escaping (_ model: String?) async throws -> Launching,
        sessionFile: @escaping (_ cwd: URL, _ sessionID: String) -> URL
    ) {
        self.agent = agent
        self.bridge = bridge
        self.timing = timing
        self.launching = launching
        self.sessionFile = sessionFile
        processes = HostedProcesses(bridge: bridge, timing: timing)
    }

    func open(in directory: URL, launchToken: String, model: String? = nil) async throws -> Session.ID {
        try await host(in: directory, model: model, launchToken: launchToken, sessionID: nil, admission: try processes.admission()) {
            try await $0.open(in: directory)
        }
    }

    /// `admit` 在这个会话的旧进程收完之后、起新进程之前跑：这家要先核对的（会话正开在别处）在这里抛。
    func resume(_ session: IndexedSession, admit: @escaping @MainActor () throws -> Void = {}) async throws -> Session.ID {
        if let live = bridge.session(sessionID: session.id) { return live.id }
        let directory = URL(filePath: session.cwd, directoryHint: .isDirectory)
        return try await processes.resume(session.id) { [self] admission in
            try admit()
            return try await host(in: directory, model: nil, launchToken: nil, sessionID: session.id, admission: admission) {
                try await $0.load(session.id, in: directory)
            }
        }
    }

    func start() {
        processes.start()
    }

    func stop() -> @concurrent @Sendable () async -> Void {
        processes.stop()
    }

    private func host(
        in directory: URL, model: String?, launchToken: String?, sessionID known: String?, admission: HostedProcesses.Admission,
        open: @escaping @MainActor (ACPSession) async throws -> String
    ) async throws -> Session.ID {
        let launch = try await launching(model)
        let session = ACPSession(dialect: launch.dialect, bridge: bridge, processes: processes)
        let connection: ACPConnection, sessionID: String
        do {
            (connection, sessionID) = try await withDeadline(AgentTimeouts.launch, timing: timing, orThrow: AgentRuntimeError.launchTimedOut(agent)) {
                let connection = try await session.launch(launch.executable, environment: launch.environment, directory: directory) {
                    [processes = self.processes] process in try await processes.admit(process, for: known, admission)
                }
                return (connection, try await open(session))
            }
        } catch {
            await session.connection?.shutdown()
            throw error
        }
        let process = connection.process
        // 回完开会话就退出了：连接已关、它的收尾已走过，挂上桥就是一个没有进程的会话
        guard !connection.isClosed else {
            throw AgentRuntimeError.launchFailed(agent, await process.exited()?.text ?? String(localized: "开好会话就退出了"))
        }
        var state = Session(
            id: Session.bridgeID(sessionID: sessionID, pid: process.pid), sessionID: sessionID, agent: agent, sessionFile: sessionFile(directory, sessionID), pid: process.pid,
            cwd: directory, state: .settled, stateSince: .now)
        state.launchToken = launchToken
        processes.adopt(process, as: sessionID)
        session.attach(state)
        return state.id
    }
}
#endif
