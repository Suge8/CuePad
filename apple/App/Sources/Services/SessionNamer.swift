#if os(macOS)
import CueBridge
import CueStore
import Foundation
import OSLog

@MainActor
final class SessionNamer {
    private static let log = Logger(subsystem: AppIdentity.id, category: "session-name")
    private let bridge: Bridge
    private let store: CueStore
    private var tried: Set<String> = []

    init(bridge: Bridge, store: CueStore) {
        self.bridge = bridge
        self.store = store
    }

    func consider(_ session: CueBridge.Session) {
        guard session.name == nil, session.firstMessage != nil, !session.upgrading, bridge.canNameItself(session.id),
              tried.insert(session.sessionID).inserted else { return }
        Task { await name(session.id, sessionID: session.sessionID) }
    }

    private func name(_ id: CueBridge.Session.ID, sessionID: String) async {
        do {
            guard try await store.wantsSuggestedName(sessionID) else { return }
            let name = try await bridge.suggestName(for: id)
            guard bridge.session(id: id)?.name == nil, try await store.wantsSuggestedName(sessionID) else { return }
            try await bridge.configure(SessionConfig(name: name), in: id)
        } catch {
            Self.log.notice("没给会话起名：\(String(describing: error))")
        }
    }
}
#endif
