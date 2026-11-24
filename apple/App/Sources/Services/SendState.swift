#if os(macOS)
import CueBridge
import CueStore
import CueText
import Foundation

/// 会话在跑时发出就打断这一轮。
/// 会话用 Pi 自己的会话 id 认：会话结束后它还是同一个，同一个会话重新打开也不变（桥上的连接 id 含进程号，每次打开都是新的）。
struct AgentTarget: Equatable {
    var session: String
    var host: String?
}

@Observable
final class SendState {
    private(set) var projects: [String: UUID] = [:]
    @ObservationIgnored private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func refreshSessionProjects() async throws {
        var result: [String: UUID] = [:]
        for slot in services.bridge.slots {
            if let project = try await services.store.project(containing: slot.cwd) { result[slot.id] = project.id }
        }
        projects = result
    }

    private func sessionName(_ sessionID: String) -> String {
        liveSession(sessionID)?.displayName
            ?? services.sessionFeed.items.first { $0.state.sessionID == sessionID }?.state.title
            ?? services.sessionFeed.recentlyEnded.first { $0.sessionID == sessionID }?.title ?? "Agent"
    }

    private func liveSession(_ sessionID: String) -> CueBridge.Session? {
        services.bridge.session(sessionID: sessionID)
    }

    func destination(to target: AgentTarget, card: UUID?) -> (listener: Listener, handed: Dotted) {
        let name = sessionName(target.session)
        let (listener, wakes): (Listener, Bool) = if let live = liveSession(target.session) {
            (.session(live.sendTarget, host: services.hostID, mode: .send, card: card), false)
        } else if let remote = services.sessionFeed.live.first(where: { $0.state.sessionID == target.session && $0.state.hostID != services.hostID }) {
            (.session(remote.state, mode: .send, card: card), false)
        } else {
            (.session(SendTarget(kind: .piSession, name: name, ref: target.session), host: target.host ?? services.hostID, mode: .send, card: card), true)
        }
        return (listener, Dotted(wakes ? String(localized: "已交给 Agent 会话「\(name)」，唤醒后送达") : String(localized: "已交给 Agent 会话「\(name)」")))
    }
}
#endif
