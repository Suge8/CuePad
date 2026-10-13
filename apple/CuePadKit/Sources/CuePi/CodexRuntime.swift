#if os(macOS)
import CueStore
import Foundation

/// Codex 的接入：终端里的会话经钩子（`AgentHookServer`）上报、经它常驻服务的控制 socket 说话；后台托管的会话是 CuePad 起的 `codex app-server`。
@MainActor
public final class CodexRuntime: AgentRuntime {
    public init(bridge: PiBridge, paths: AgentPaths, hooks: AgentHookServer, locator: ExecutableLocator = .standard) {
        _ = (bridge, paths, hooks, locator)
    }

    public func start() throws {
        // TODO(codex)
    }

    public func stop() -> @concurrent @Sendable () async -> Void { {} }

    public func open(in directory: URL, launchToken: String) async throws -> PiSession.ID {
        throw AgentRuntimeError.notInstalled(.codex)
    }

    public func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        throw AgentRuntimeError.notInstalled(.codex)
    }

    public func end(_ id: PiSession.ID) async throws {
        throw PiBridgeError.unsupported
    }
}
#endif
