#if os(macOS)
import CueStore
import Foundation

/// 托管会话用用户的配置目录（会话落在 `<GROK_HOME>/sessions`，`grok --resume` 里也有）。
@MainActor
public final class GrokRuntime: AgentRuntime {
    private let bridge: Bridge
    private let host: ACPHost
    private let home: URL

    public init(
        bridge: Bridge, paths: AgentPaths, grok: @escaping @Sendable () async -> URL?,
        locate: @escaping @Sendable () async -> ExecutableLocator = { await .system }, timing: Timing = .system
    ) {
        self.bridge = bridge
        let home = paths.home(of: .grok)
        self.home = home
        host = ACPHost(.grok, bridge: bridge, timing: timing, launching: { _ in
            guard let grok = await grok() else { throw AgentRuntimeError.notInstalled(.grok) }
            let environment = await locate().environment(launching: grok, overrides: paths.launchEnvironment(of: .grok))
            return ACPHost.Launching(executable: grok, environment: environment, dialect: GrokDialect())
        }, sessionFile: { cwd, id in Self.sessionFile(in: home, cwd: cwd.path, id: id) })
    }

    public func start() throws { host.start() }

    public func stop() -> @concurrent @Sendable () async -> Void { host.stop() }

    public func open(
        in directory: URL, launchToken: String, name: String?, model: ModelKey?, thinking: ThinkingLevel?
    ) async throws -> Session.ID {
        let id = try await host.open(in: directory, launchToken: launchToken)
        return try await configure(opened: id, name: name, model: model, thinking: thinking, on: bridge)
    }

    /// 终端里还开着它时不接：两个进程会同写一份会话记录。
    public func resume(_ session: IndexedSession) async throws -> Session.ID {
        try await host.resume(session) { [home] in
            if Self.openSessions(in: home).contains(session.id) { throw AgentRuntimeError.openElsewhere }
        }
    }

    /// 此刻有进程开着的会话：Grok 把它们登记在 `<GROK_HOME>/active_sessions.json`（启动即登记，`--resume` 接着的也是；退出时注销，
    /// 崩溃留下的靠进程起点认出已不在。`pid_start` 是 Unix 微秒，与内核进程起点逐位相等。1.0.70 实测）。
    /// 读不出来（没有这个文件、Grok 换了格式）当作没人开着：这道核对只防偶发的两边同开，不为它挡住接着。
    static func openSessions(in home: URL) -> Set<String> {
        struct Entry: Decodable {
            var sessionID: String
            var pid: Int32
            var pidStart: Int64

            private enum CodingKeys: String, CodingKey {
                case sessionID = "session_id"
                case pidStart = "pid_start"
                case pid
            }
        }
        let entries = (try? Data(contentsOf: home.appending(path: "active_sessions.json"))).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        return Set(entries.filter { SessionProcess(pid: $0.pid, startedAt: $0.pidStart).isRunning }.map(\.sessionID))
    }

    /// 工作目录照 URL 的写法编码（只留字母、数字与 `-._~`，同 Grok 用的 urlencoding）。
    static func sessionFile(in home: URL, cwd: String, id: String) -> URL {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return home.appending(path: "sessions", directoryHint: .isDirectory)
            .appending(path: cwd.addingPercentEncoding(withAllowedCharacters: unreserved) ?? cwd, directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory).appending(path: GrokHistory.fileName)
    }
}
#endif
