#if os(macOS)
import CuePi
import CueStore
import CueText
import Foundation
import SwiftUI

/// 交给哪个 Agent 会话、用哪种方式（直接发送；会话正忙时马上说或等它做完再说）。Mac 上只有提示词发给 Agent（`CardMenu.handsToAgent`）。
/// 会话用 Pi 自己的会话 id 认：会话结束后它还是同一个，同一个会话重新打开也不变（桥上的连接 id 含进程号，每次打开都是新的）。
struct AgentTarget: Equatable {
    var session: String
    var mode: DeliveryMode = .send
    /// 会话记录所在的 Mac（`CueStore.handOffPlan` 定下的）；nil 为本机。会话不在线时请那台 Mac 唤醒它。
    var host: String?
}

/// 发给 Agent 会话的状态与规则：等用户决定的一次发送、在线会话各归哪个项目、目标走哪条路送达、显示的名字与状态。
/// 发到哪只有一条规则（`CueStore.handOffPlan`，Mac 上经 `Workspace.handOff`）。不碰界面提示：成败由调用方（`Workspace.send`）说。
@Observable
final class SendState {
    /// Pi 会话正忙时待用户选择马上说或等它做完再说的一次发送；`session` 是 Pi 自己的会话 id。
    struct Busy {
        var text: String
        var session: String
        var host: String?
        var card: UUID?
    }

    /// 一个发送目标走哪条路：本机桥上连着的会话；别的 Mac 上在线的会话；不在线的会话（已结束的，或托管着、进程歇着的）：
    /// 发送时由它所在那台 Mac（`host`）的执行器在后台唤醒。
    enum Route {
        case local(CuePi.PiSession)
        case remote(PiSessionState)
        case ended(host: String?)
    }

    var busy: Busy?
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
        for session in services.pi.sessions {
            if let project = try await services.store.project(containing: session.cwd) { result[session.id] = project.id }
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
        HandOffTargets.sessions(services.liveSessions.live, project: project).filter { isReachable($0.state) }
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
            ?? services.liveSessions.items?.first { $0.state.sessionID == sessionID }?.state.title
            ?? services.liveSessions.recentlyEnded.first { $0.sessionID == sessionID }?.title ?? "Agent"
    }

    /// 完整说法："发给 Agent 会话「…」"（已结束的是"唤醒 Agent 会话「…」并发送"），用在送达后的提示。
    func action(for target: AgentTarget) -> String {
        let name = sessionName(target.session)
        return isEnded(target) ? "唤醒 Agent 会话「\(name)」并发送" : "发给 Agent 会话「\(name)」"
    }

    /// 这个 Pi 会话此刻连着桥的那个进程；没有就是已结束。
    func liveSession(_ sessionID: String) -> CuePi.PiSession? {
        services.pi.session(sessionID: sessionID)
    }

    /// 发给 Agent（存储格式正文）。返回是否已送达：会话正忙时记下这次发送（`busy`）等用户选，返回 false；其余失败抛出。
    func send(_ stored: String, to target: AgentTarget, card: UUID?) async throws -> Bool {
        // 收不了图片的会话只发文字（`AgentCapabilities.images`）
        let stored = capabilities(of: target.session).contains(.images) ? stored : CueFormat.withoutImages(stored)
        do {
            switch route(of: target.session, host: target.host) {
            case .local(let live): try await services.send(stored, to: live.id, mode: target.mode, card: card)
            case .remote(let session): try await services.send(stored, toRemote: session, mode: target.mode, card: card)
            case .ended(let host): try await services.send(stored, toEnded: target.session, named: sessionName(target.session), on: host, card: card)
            }
            return true
        } catch SendError.piSessionBusy {
            // 会话正忙：做不到马上说的只剩等它做完再说，不问
            guard capabilities(of: target.session).contains(.steer) else {
                return try await send(stored, to: AgentTarget(session: target.session, mode: .followUp, host: target.host), card: card)
            }
            busy = Busy(text: stored, session: target.session, host: target.host, card: card)
            return false
        }
    }

    /// 这个会话从 CuePad 能做什么（`AgentCapabilities`）：本机在线的看桥上的，别的 Mac 上的看同步记录；已结束的发话时会被唤醒、不会正忙。
    private func capabilities(of sessionID: String) -> AgentCapabilities {
        switch route(of: sessionID) {
        case .local(let live): live.capabilities
        case .remote(let session): session.capabilities
        case .ended: .all
        }
    }
}

extension Workspace {
    /// 把任务的草稿（提示词）发给 Agent，交到哪只由 `CueStore.handOffPlan` 定（与 Cue 的开工同一份规则）：绑着的会话经本机桥直接发，
    /// 会话正忙时转为询问；要开新会话就开以任务命名的、开好后任务绑上它；哪台 Mac 都没绑文件夹时就地弹选文件夹，取消就不开。
    /// 送达后草稿就用掉了（Store 删掉它）。
    func handOff(_ prompt: Card) {
        let text = Outgoing.text(of: prompt), id = prompt.id
        attempt { try await self.handOff(text, prompt: id) }
    }

    /// 给叶子开一个新会话，不接着用绑着的或上一步的会话（"绑定会话"里的"开新会话"；与 Cue 开工带 fresh 同一条规则，
    /// `CueStore.handOffPlan(fresh:)`）：写好的草稿作为第一句，没有就只开会话。
    func startFresh(_ leaf: UUID) {
        attempt {
            let draft = try await self.services.store.draft(of: leaf)
            try await self.handOff(draft.map(Outgoing.text(of:)), prompt: draft?.id ?? leaf, fresh: true)
        }
    }

    /// 把会话绑到叶子任务上（任务的右键、浮窗里"绑定会话"、会话页的"⋯"）。叶子写好没发的话接进这个会话的回复框，由你决定发不发。
    func bind(_ sessionID: String, to leaf: UUID) async throws {
        guard let draft = try await services.store.bindSession(sessionID, to: leaf) else { return }
        putInReplyBox(draft, of: sessionID)
        say("已绑定，写好的话放进了会话的回复框", link: .session(sessionID))
    }

    /// 用会话名在会话所在的项目里新建一个任务，绑上。
    func bindNewTask(to session: PiSessionState) async throws {
        try await bind(session.sessionID, to: try await createTask(session.title, in: session.projectID).id)
    }

    /// `text` 为 nil 只在开新会话时（没有草稿）。
    private func handOff(_ text: String?, prompt: UUID, fresh: Bool = false) async throws {
        let plan = try await services.store.handOffPlan(prompt, host: services.hostID, fresh: fresh)
        switch plan.destination {
        case .session(let session, _, let host):
            guard let text else { return }
            await send(text, to: AgentTarget(session: session, host: host), card: prompt)
        case .launch(let project, let host):
            // 会话名由带着的提示词定（`CueStore.requestLaunch`）；请求上显示的目标名同新会话的其他入口：任务没有标题时写项目名
            let projectName = try await services.store.project(project)?.name
            let title = plan.name ?? projectName ?? CaptureCopy.unfiled
            _ = try await startSession(in: project, prompt: text?.nonEmpty, title: title, on: host, card: prompt, agent: services.defaultAgent) {}
        case .noFolder(let project, _):
            guard let path = await ProjectDirectory.pick() else { return }
            try await services.store.setDirectory(path, for: project)
            try await handOff(text, prompt: prompt, fresh: fresh)
        case .unfiled:
            say("未分类的任务没有文件夹，开不了会话", isError: true)
        }
    }

    /// 发给 Agent（存储格式正文）；成功后提示，会话正忙时转为询问马上说还是等它做完再说。返回是否已送达。
    @discardableResult
    func send(_ stored: String, to target: AgentTarget, card: UUID? = nil) async -> Bool {
        let done = Dotted("已" + sendState.action(for: target), target.mode == .steer || target.mode == .followUp ? target.mode.label : nil)
        do {
            let sent = try await sendState.send(stored, to: target, card: card)
            if sent { say(done) }
            return sent
        } catch {
            fail(error)
            return false
        }
    }

    func resolveBusySend(_ mode: DeliveryMode) {
        guard let pending = sendState.busy else { return }
        sendState.busy = nil
        Task { await send(pending.text, to: AgentTarget(session: pending.session, mode: mode, host: pending.host), card: pending.card) }
    }
}

extension Workspace {
    /// Mac 的工作区随 App 常驻、主窗口与菜单栏面板共用一个：项目目录（读不出来时按"重试"重新订阅）与会话归属的项目都在这里跟着，
    /// 不挂在哪个视图上——窗口隐去、面板收起都照常更新，也不会两处各订阅一份（会话摘要由 App 级的 `LiveSessions` 跟）。直到所在任务取消。
    func follow() async {
        async let catalog: Void = followCatalog()
        async let placement: Void = followSessionPlacement()
        _ = await (catalog, placement)
    }

    private func followCatalog() async {
        for await _ in Observations({ self.catalogAttempt }) { await observeCatalog() }
    }

    /// 在线 Pi 会话或项目目录绑定变了：重算会话归属的项目。
    private func followSessionPlacement() async {
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
