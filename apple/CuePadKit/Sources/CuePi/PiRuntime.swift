#if os(macOS)
import CueStore
import Foundation

/// Pi 的接入：会话由桥经扩展的 socket 发现（`PiBridge`），后台托管交给 `PiHost`；`locate` 找这台 Mac 上够新的 `pi`。
@MainActor
public final class PiRuntime: AgentRuntime {
    public let host: PiHost
    private let locate: @Sendable () async -> URL?

    public init(host: PiHost, locate: @escaping @Sendable () async -> URL?) {
        self.host = host
        self.locate = locate
    }

    public func start() throws { host.start() }

    public func stop() -> @concurrent @Sendable () async -> Void { host.closeAll() }

    public func open(in directory: URL, launchToken: String) async throws -> PiSession.ID {
        try await host.open(in: directory, launchToken: launchToken, executable: try await executable()).id
    }

    public func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        let directory = URL(filePath: session.cwd, directoryHint: .isDirectory)
        return try await host.resume(sessionFile: URL(filePath: session.path), in: directory, executable: try await executable()).id
    }

    public func end(_ id: PiSession.ID) async throws { try await host.end(id) }

    private func executable() async throws -> URL {
        guard let pi = await locate() else { throw AgentRuntimeError.notInstalled(.pi) }
        return pi
    }
}
#endif
