#if os(macOS)
import CueBridge
import CueStore
import Foundation

extension AppServices {
    /// 认调用 id 的找法只覆盖 Pi 与 Claude Code 的会话文件（`ToolCallDetail.read`）。
    func readsSteps(of session: SessionState) -> Bool {
        (session.hostID == speech.localHost || DebugHooks.preset.demoMac) && [.known(.pi), .known(.claudeCode)].contains(session.agent)
    }

    func stepDetail(_ calls: [String], in session: SessionState) async -> ToolCallDetail? {
        guard let indexed = try? await store.indexedSession(session.sessionID) else { return nil }
        return await Task.detached { ToolCallDetail.read(file: URL(filePath: indexed.path), calls: calls) }.value
    }
}
#endif
