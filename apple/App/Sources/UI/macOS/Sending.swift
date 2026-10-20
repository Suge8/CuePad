#if os(macOS)
import CuePi
import CueStore
import CueText
import SwiftUI

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

    /// 重算活着的会话各归哪个项目。
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

    /// 会话不在线：发送时先在后台唤醒它。
    func isEnded(_ target: AgentTarget) -> Bool {
        if case .ended = route(of: target.session, host: target.host) { true } else { false }
    }

    /// Pi 会话的显示名：本机在线的取桥上的，别的 Mac 上的与刚结束的取同步记录里的。
    func sessionName(_ sessionID: String) -> String {
        liveSession(sessionID)?.displayName
            ?? services.liveSessions.items.first { $0.state.sessionID == sessionID }?.state.title
            ?? services.liveSessions.recentlyEnded.first { $0.sessionID == sessionID }?.title ?? "Agent"
    }

    /// 交出后的提示：写出了、还没送达（到哪了看任务那一行），"已交给 Agent 会话「…」"，已结束的补一句它会先被唤醒。
    func handed(_ target: AgentTarget) -> Dotted {
        let note = isEnded(target) ? "唤醒后送达" : nil
        return Dotted("已交给 Agent 会话「\(sessionName(target.session))」", note)
    }

    /// 这个 Pi 会话此刻连着桥的那个进程；没有就是已结束。
    func liveSession(_ sessionID: String) -> CuePi.PiSession? {
        services.pi.session(sessionID: sessionID)
    }

    /// 发给 Agent 写到哪（存储格式正文，收不了图片的会话去掉图片）。本机在线的写给本机，别的 Mac 上的写给那台；
    /// 不在线的（已结束，或托管着、进程歇着）写给它所在的 Mac，由那台的执行器在后台唤醒后送达。
    func destination(of stored: String, to target: AgentTarget, card: UUID?) -> (content: String, listener: Listener) {
        // 收不了图片的会话只发文字（`AgentCapabilities.images`）
        let stored = capabilities(of: target.session).contains(.images) ? stored : CueFormat.plainText(stored)
        let listener: Listener = switch route(of: target.session, host: target.host) {
        case .local(let live): .session(live.sendTarget, host: services.hostID, mode: .send, card: card)
        case .remote(let session): .session(session, mode: .send, card: card)
        case .ended(let host):
            .session(
                SendTarget(kind: .piSession, name: sessionName(target.session), ref: target.session), host: host ?? services.hostID, mode: .send,
                card: card)
        }
        return (stored, listener)
    }

    /// 这个会话从 CuePad 能做什么（`AgentCapabilities`）：本机在线的看桥上的，别的 Mac 上的看同步记录；已结束的发话时会被唤醒。
    private func capabilities(of sessionID: String) -> AgentCapabilities {
        switch route(of: sessionID) {
        case .local(let live): live.capabilities
        case .remote(let session): session.capabilities
        case .ended: .all
        }
    }
}

extension Workspace {
    /// 开始：把叶子任务的第一句（`CueStore.opening`，与 Cue 的开工同一个函数）发给 Agent，交到哪只由 `CueStore.handOffPlan` 定：
    /// 接着用上一步的会话就发给它（在跑就打断这一轮）；要开新会话就开以任务命名的、开好后任务绑上它（项目没绑文件夹时执行的那台 Mac
    /// 先建工作区，`MacExecutor`）。正文发出后留在任务上。
    func handOff(_ leaf: Card) {
        let id = leaf.id
        attempt { try await self.handOff(leaf: id) }
    }

    /// 给叶子开一个新会话，不接着用绑着的或上一步的会话（"绑定会话"里的"开新会话"；与 Cue 开工带 fresh 同一条规则，
    /// `CueStore.handOffPlan(fresh:)`）。
    func startFresh(_ leaf: Card) {
        let id = leaf.id
        attempt { try await self.handOff(leaf: id, fresh: true) }
    }

    private func handOff(leaf: UUID, fresh: Bool = false) async throws {
        let store = services.store
        let plan = try await store.handOffPlan(leaf, host: services.hostID, fresh: fresh)
        let text = try await store.opening(of: leaf, plan.opensSession)
        switch plan.destination {
        case .session(let session, _, let host):
            send(text, to: AgentTarget(session: session, host: host), card: leaf)
        case .launch(let project, let host):
            // 会话名由任务定（`CueStore.requestLaunch`）；请求上显示的目标名同新会话的其他入口：任务没有标题时写项目名
            let projectName = try await services.store.project(project)?.name ?? ""
            let title = plan.name ?? projectName
            let agents = try await services.store.macAgents(on: host)
            guard let agent = agents.preferred(services.settings.lastAgent) else {
                say("\(host == services.hostID ? "这台" : "那台") Mac 上开不了会话：\(agents.whyNone)", isError: true)
                return
            }
            _ = try await startSession(in: project, prompt: text.nonEmpty, title: title, on: host, card: leaf, agent: agent) {}
        }
    }

    /// 发给 Agent（存储格式正文）：经 `speak` 写出就提示，不等送达（到哪了看任务那一行与会话页）。返回写库与上传的那个任务（测试等它）。
    @discardableResult
    func send(_ stored: String, to target: AgentTarget, card: UUID? = nil) -> Task<Void, Never> {
        let (content, listener) = sendState.destination(of: stored, to: target, card: card)
        return speak(content, to: listener, saying: sendState.handed(target))
    }
}

extension Workspace {
    /// 在线 Pi 会话或项目目录绑定变了：重算会话归属的项目（`follow` 跟着）。
    func followSessionPlacement() async {
        for await _ in Observations({ self.sessionPlacement }) {
            do { try await sendState.refreshSessionProjects() } catch { fail(error) }
        }
    }

    private struct SessionPlacement: Equatable {
        var sessions: [String]
        var directories: [UUID: String]?
    }

    private var sessionPlacement: SessionPlacement {
        let pi = services.pi
        return SessionPlacement(sessions: pi.slots.map { "\($0.id) \($0.cwd.path)" }, directories: catalog?.directories)
    }
}
#endif
