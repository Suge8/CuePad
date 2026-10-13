#if os(macOS)
import CueStore
import Foundation

/// OpenCode 的接入：直连它的后台服务（事件流 + 接口），终端与 CuePad 开的会话都在服务里；会话索引与对话由这里写进资料库（它的会话不在文件里）。
@MainActor
public final class OpenCodeRuntime: AgentRuntime {
    public init(bridge: PiBridge, paths: AgentPaths, store: CueStore, hostID: String, locator: ExecutableLocator = .standard) {
        _ = (bridge, paths, store, hostID, locator)
    }

    public func start() throws {
        // TODO(opencode)
    }

    public func stop() -> @concurrent @Sendable () async -> Void { {} }

    public func open(in directory: URL, launchToken: String) async throws -> PiSession.ID {
        throw AgentRuntimeError.notInstalled(.opencode)
    }

    public func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        throw AgentRuntimeError.notInstalled(.opencode)
    }

    public func end(_ id: PiSession.ID) async throws {
        throw PiBridgeError.unsupported
    }
}
#endif
