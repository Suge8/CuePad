#if os(macOS)
import CuePi
import CueStore
import CueText
import Foundation

/// 会话在跑时发出就打断这一轮。
/// 会话用 Pi 自己的会话 id 认：会话结束后它还是同一个，同一个会话重新打开也不变（桥上的连接 id 含进程号，每次打开都是新的）。
struct AgentTarget: Equatable {
    var session: String
    /// nil 为本机；会话不在线时请那台 Mac 唤醒它。
    var host: String?
}

/// 发到哪只有一条规则（`CueStore.handOffPlan`）。不碰界面提示：成败由调用方说。
@Observable
final class SendState {
    /// `ended`：不在线的会话（已结束的，或托管着、进程歇着的），发送时由它所在那台 Mac 的执行器在后台唤醒。
    enum Route {
        case local(CuePi.PiSession)
        case remote(PiSessionState)
        case ended(host: String?)
    }

    /// key 是桥上的连接 id；归属由 Store 按工作目录判定。
    private(set) var projects: [String: UUID] = [:]
    @ObservationIgnored private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    func refreshSessionProjects() async throws {
        var result: [String: UUID] = [:]
        for slot in services.pi.slots {
            if let project = try await services.store.project(containing: slot.cwd) { result[slot.id] = project.id }
        }
        projects = result
    }

    /// 终端里开的会话桥上已经没有、记录还没来得及标成结束的不算（发送时它走"唤醒"那条路）。
    private func isReachable(_ state: PiSessionState) -> Bool {
        state.hostID != services.hostID || state.hosted || liveSession(state.sessionID) != nil
    }

    /// 与手机的发给 Agent 输入框共用同一份规则（`HandOffTargets`）。
    func onlineTargets(for project: UUID?) -> [PiSessionListItem] {
        HandOffTargets.sessions(services.liveSessions.live, project: project, at: services.speech).filter { isReachable($0.state) }
    }

    func route(of sessionID: String, host: String? = nil) -> Route {
        if let live = liveSession(sessionID) { return .local(live) }
        if let remote = services.liveSessions.live.first(where: { $0.state.sessionID == sessionID && $0.state.hostID != services.hostID }) {
            return .remote(remote.state)
        }
        return .ended(host: host)
    }

    private func sessionName(_ sessionID: String) -> String {
        liveSession(sessionID)?.displayName
            ?? services.liveSessions.items.first { $0.state.sessionID == sessionID }?.state.title
            ?? services.liveSessions.recentlyEnded.first { $0.sessionID == sessionID }?.title ?? "Agent"
    }

    private func liveSession(_ sessionID: String) -> CuePi.PiSession? {
        services.pi.session(sessionID: sessionID)
    }

    /// 正文原样写：收不了图片的会话由 Mac 交出时把图片写成路径（`MacExecutor`）。提示只说写出了，到哪了看任务那一行。
    func destination(to target: AgentTarget, card: UUID?) -> (listener: Listener, handed: Dotted) {
        let name = sessionName(target.session)
        let (listener, wakes): (Listener, Bool) = switch route(of: target.session, host: target.host) {
        case .local(let live): (.session(live.sendTarget, host: services.hostID, mode: .send, card: card), false)
        case .remote(let session): (.session(session, mode: .send, card: card), false)
        case .ended(let host):
            (.session(SendTarget(kind: .piSession, name: name, ref: target.session), host: host ?? services.hostID, mode: .send, card: card), true)
        }
        return (listener, Dotted(wakes ? String(localized: "已交给 Agent 会话「\(name)」，唤醒后送达") : String(localized: "已交给 Agent 会话「\(name)」")))
    }
}
#endif
