#if os(macOS)
import CuePi
import CueStore
import CueText
import Foundation

/// 交给哪个 Agent 会话（会话在跑时发出就打断这一轮）。Mac 上交给 Agent 的是任务的正文（"开始"，`Workspace.handOff`）。
/// 会话用 Pi 自己的会话 id 认：会话结束后它还是同一个，同一个会话重新打开也不变（桥上的连接 id 含进程号，每次打开都是新的）。
struct AgentTarget: Equatable {
    var session: String
    /// 会话记录所在的 Mac（`CueStore.handOffPlan` 定下的）；nil 为本机。会话不在线时请那台 Mac 唤醒它。
    var host: String?
}

/// 发给 Agent 会话的状态与规则：在线会话各归哪个项目、目标走哪条路送达、显示的名字与状态。
/// 发到哪只有一条规则（`CueStore.handOffPlan`，Mac 上经 `Workspace.handOff`）。不碰界面提示：成败由调用方（`Workspace.send`）说。
@Observable
final class SendState {
    /// 一个发送目标走哪条路：本机桥上连着的会话；别的 Mac 上在线的会话；不在线的会话（已结束的，或托管着、进程歇着的）：
    /// 发送时由它所在那台 Mac（`host`）的执行器在后台唤醒。
    enum Route {
        case local(CuePi.PiSession)
        case remote(PiSessionState)
        case ended(host: String?)
    }

    /// 在线 Pi 会话（桥上的连接 id）各自归属的项目，由 Store 按工作目录判定（`project(containing:)`）；
    /// 会话或目录绑定变化时由 `Workspace.follow` 调用 `refreshSessionProjects` 重算。
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

    /// 同步记录里在线的会话此刻能交给：别的 Mac 上的记录在线即可；本机的要桥上连着，或是托管着的（进程歇着也列出，发送时唤醒）——
    /// 终端里开的会话桥上已经没有、记录还没来得及标成结束的不算（发送时它走"唤醒"那条路）。
    private func isReachable(_ state: PiSessionState) -> Bool {
        state.hostID != services.hostID || state.hosted || liveSession(state.sessionID) != nil
    }

    /// 能交给的在线会话：所有 Mac 上的（手机的发给 Agent 输入框共用同一份规则，见 `HandOffTargets`），去掉本机已不在桥上的。
    func onlineTargets(for project: UUID?) -> [PiSessionListItem] {
        HandOffTargets.sessions(services.liveSessions.live, project: project, at: services.speech).filter { isReachable($0.state) }
    }

    /// `host`：会话记录所在的 Mac，nil 为本机。
    func route(of sessionID: String, host: String? = nil) -> Route {
        if let live = liveSession(sessionID) { return .local(live) }
        if let remote = services.liveSessions.live.first(where: { $0.state.sessionID == sessionID && $0.state.hostID != services.hostID }) {
            return .remote(remote.state)
        }
        return .ended(host: host)
    }

    /// Pi 会话的显示名：本机在线的取桥上的，别的 Mac 上的与刚结束的取同步记录里的。
    private func sessionName(_ sessionID: String) -> String {
        liveSession(sessionID)?.displayName
            ?? services.liveSessions.items.first { $0.state.sessionID == sessionID }?.state.title
            ?? services.liveSessions.recentlyEnded.first { $0.sessionID == sessionID }?.title ?? "Agent"
    }

    /// 这个 Pi 会话此刻连着桥的那个进程；没有就是已结束。
    private func liveSession(_ sessionID: String) -> CuePi.PiSession? {
        services.pi.session(sessionID: sessionID)
    }

    /// 发给 Agent 写到哪与交出后的提示。正文原样写：收不了图片的会话由 Mac 交出时把图片写成路径（`MacExecutor`）。本机在线的写给本机，别的 Mac 上的写给那台；
    /// 不在线的（已结束，或托管着、进程歇着）写给它所在的 Mac，由那台的执行器在后台唤醒后送达，提示补一句"唤醒后送达"。
    /// 提示只说写出了（到哪了看任务那一行）。
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
