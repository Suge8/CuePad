#if os(macOS)
import CueStore
import Foundation

/// 托管会话用用户的配置目录（会话落在 `<GROK_HOME>/sessions`，`grok --resume` 里也有）。
@MainActor
public final class GrokRuntime: AgentRuntime {
    private let bridge: Bridge
    private let host: ACPHost

    public init(
        bridge: Bridge, paths: AgentPaths, grok: @escaping @Sendable () async -> URL?,
        locate: @escaping @Sendable () async -> ExecutableLocator = { await .system }, timing: Timing = .system
    ) {
        self.bridge = bridge
        let home = paths.home(of: .grok)
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

    public func resume(_ session: IndexedSession) async throws -> Session.ID { try await host.resume(session) }

    /// 工作目录照 URL 的写法编码（只留字母、数字与 `-._~`，同 Grok 用的 urlencoding）。
    static func sessionFile(in home: URL, cwd: String, id: String) -> URL {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return home.appending(path: "sessions", directoryHint: .isDirectory)
            .appending(path: cwd.addingPercentEncoding(withAllowedCharacters: unreserved) ?? cwd, directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory).appending(path: GrokHistory.fileName)
    }
}
#endif
