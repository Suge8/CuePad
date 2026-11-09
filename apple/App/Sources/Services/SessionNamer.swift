#if os(macOS)
import CuePi
import CueStore
import Foundation
import OSLog

/// 没有名字的在线会话按第一句话起个短名（`SessionNameSuggestion`），只在承载它的这台 Mac 上：会话有了第一句话、自己还没有名字、
/// 这家能给它起名（`PiBridge.canNameItself`：终端里的 Codex、还没换上新扩展的 Pi 会话不能，之后能了再起）、你没起过名
/// （`CueStore.wantsSuggestedName`）时请它那一家起（`PiBridge.suggestName`）。起好后写回前再核对一遍：会话仍没名字、你仍没起过名
/// （起名途中任务有了标题、你发了改名都不写），才走改名写回，名字随会话名回来。
/// 每个会话这次运行只试一次；超时、出错都放弃，会话保持原名，不提示。
@MainActor
final class SessionNamer {
    private static let log = Logger(subsystem: AppIdentity.id, category: "session-name")
    private let bridge: PiBridge
    private let store: CueStore
    private var tried: Set<String> = []

    init(bridge: PiBridge, store: CueStore) {
        self.bridge = bridge
        self.store = store
    }

    /// 会话出现或变了（`PiSessionChange`）。
    func consider(_ session: CuePi.PiSession) {
        guard session.name == nil, session.firstMessage != nil, !session.upgrading, bridge.canNameItself(session.id),
              tried.insert(session.sessionID).inserted else { return }
        Task { await name(session.id, sessionID: session.sessionID) }
    }

    private func name(_ id: CuePi.PiSession.ID, sessionID: String) async {
        do {
            guard try await store.wantsSuggestedName(sessionID) else { return }
            let name = try await bridge.suggestName(for: id)
            guard bridge.session(id: id)?.name == nil, try await store.wantsSuggestedName(sessionID) else { return }
            try await bridge.configure(PiConfig(name: name), in: id)
        } catch {
            Self.log.notice("没给会话起名：\(String(describing: error))")
        }
    }
}
#endif
