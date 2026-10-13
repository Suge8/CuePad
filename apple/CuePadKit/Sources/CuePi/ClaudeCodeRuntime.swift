#if os(macOS)
import CueStore
import Foundation

/// Claude Code 的接入：终端里的会话经钩子（`AgentHookServer`）上报、经它的收件箱 socket 说话、经阻塞的钩子作答；后台托管的会话是 CuePad 起的 stream-json 进程。
@MainActor
public final class ClaudeCodeRuntime: AgentRuntime {
    public init(bridge: PiBridge, paths: AgentPaths, hooks: AgentHookServer, locator: ExecutableLocator = .standard) {
        _ = (bridge, paths, hooks, locator)
    }

    public func start() throws {
        // TODO(claude)
    }

    public func stop() -> @concurrent @Sendable () async -> Void { {} }

    public func open(in directory: URL, launchToken: String) async throws -> PiSession.ID {
        throw AgentRuntimeError.notInstalled(.claudeCode)
    }

    public func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        throw AgentRuntimeError.notInstalled(.claudeCode)
    }

    public func end(_ id: PiSession.ID) async throws {
        throw PiBridgeError.unsupported
    }
}
#endif
