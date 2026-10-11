#if os(macOS)
import CuePi
import CueStore
import CueText
import Foundation
import SwiftUI

/// 发给哪个 Agent 会话、用哪种方式（直接发送；会话正忙时马上说或等它做完再说）。Mac 上只有提示词发给 Agent（`CardMenu.handsToAgent`）。
/// 会话用 Pi 自己的会话 id 认：会话结束后它还是同一个，同一个会话重新打开也不变（桥上的连接 id 含进程号，每次打开都是新的）。
struct AgentTarget: Equatable {
    var session: String
    var mode: DeliveryMode = .send
}

/// 发送与会话归属的窗口状态：用户选的目标、等用户决定的一次发送、在线会话各归哪个项目。读写它的规则都在下面的 `Workspace` 扩展里。
@MainActor @Observable
final class SendState {
    /// Pi 会话正忙时待用户选择马上说或等它做完再说的一次发送；`session` 是 Pi 自己的会话 id。
    struct Busy {
        var text: String
        var session: String
        var card: UUID?
    }

    var busy: Busy?
    /// 用户在本窗口选过或发过的 Agent 会话；nil 或已失效时用本项目的会话（`Workspace.agentTarget`）。
    var choice: AgentTarget?
    /// 在线 Pi 会话（桥上的连接 id）各自归属的项目，由 Store 按工作目录判定（`project(containing:)`）；
    /// 会话或目录绑定变化时由 `Workspace.follow` 调用 `refreshSessionProjects` 重算。
    var projects: [String: UUID] = [:]
}

extension Workspace {
    /// 重算活着的会话各归哪个项目。
    func refreshSessionProjects() async {
        var result: [String: UUID] = [:]
        for session in services.pi.sessions {
            do {
                if let project = try await services.store.project(containing: session.cwd) { result[session.id] = project.id }
            } catch {
                fail(error)
                return
            }
        }
        sendState.projects = result
    }

    /// 一个发送目标走哪条路：本机桥上连着的会话；别的 Mac 上在线的会话；已结束的会话（在后台唤醒）。
    enum HandOffRoute {
        case local(CuePi.PiSession)
        case remote(PiSessionState)
        case ended
    }

    /// 同步记录里在线的会话此刻能直接交给：别的 Mac 上的记录在线即可；本机的要桥上连着——桥上已经没有、记录还没来得及标成结束的
    /// 不算（发送时它走"已结束"那条路，菜单和默认目标也不列它）。菜单与发送走的路都读它。
    private func isReachable(_ state: PiSessionState) -> Bool {
        state.hostID != services.hostID || liveSession(state.sessionID) != nil
    }

    /// 能交给的在线会话：所有 Mac 上的（手机的交给 Agent 输入框共用同一份规则，见 `HandOffTargets`），去掉本机已不在桥上的。
    func onlineTargets(for project: UUID?) -> [PiSessionListItem] {
        HandOffTargets.sessions(services.liveSessions.live, project: project).filter { isReachable($0.state) }
    }

    func route(of sessionID: String) -> HandOffRoute {
        if let live = liveSession(sessionID) { return .local(live) }
        if let remote = services.liveSessions.live.first(where: { $0.state.sessionID == sessionID && isReachable($0.state) }) {
            return .remote(remote.state)
        }
        return .ended
    }

    /// 项目的 Pi 会话：按工作目录归入（Store 判定），空闲的在前。
    /// 先按格子上不变的身份筛出本项目的，再读这些格子的状态：别的项目的会话状态变化不惊动读它的视图。
    func projectSessions(in project: UUID?) -> [CuePi.PiSession] {
        guard let project else { return [] }
        return services.pi.slots
            .filter { sendState.projects[$0.id] == project }
            .map(\.session)
            .sorted { !$0.state.isTurnRunning && $1.state.isTurnRunning }
    }

    /// 当前生效的会话：用户选过或发过的（已结束时照样保留，界面写"已结束"，不悄悄换掉；同一个 Pi 会话重新打开了就是在线的那个），
    /// 否则本项目的会话——在线的优先（空闲的在前，同样空闲时本机的在前：本机直接送达），都结束了就是刚结束的那个（同样写"已结束"）；
    /// 本项目一个都没有时为 nil。
    func agentTarget(for project: UUID?) -> AgentTarget? {
        if let choice = sendState.choice { return choice }
        guard let project else { return nil }
        let mine = onlineTargets(for: project).filter { $0.state.projectID == project }
        if let pick = mine.min(by: { rank($0) < rank($1) }) { return AgentTarget(session: pick.state.sessionID) }
        return endedTargets.first { $0.projectID == project }.map { AgentTarget(session: $0.sessionID) }
    }

    private func rank(_ item: PiSessionListItem) -> (busy: Int, remote: Int) {
        let busy = liveSession(item.state.sessionID)?.state.isTurnRunning ?? item.state.state.known?.isTurnRunning ?? false
        return (busy ? 1 : 0, item.state.hostID == services.hostID ? 0 : 1)
    }

    /// 能选作发送目标的已结束会话：这个窗口打开后结束、也没有重新打开的，最近结束的在前。发给它们时在后台把会话恢复起来。
    var endedTargets: [PiSessionState] { services.liveSessions.recentlyEnded.filter { liveSession($0.sessionID) == nil } }

    /// 会话已结束、也没有重新打开：发送时先在后台唤醒它，发送钮的状态点写"已结束"。
    func isEnded(_ target: AgentTarget) -> Bool {
        if case .ended = route(of: target.session) { true } else { false }
    }

    /// Pi 会话的显示名：本机在线的取桥上的，别的 Mac 上的与刚结束的取同步记录里的。
    func sessionName(_ sessionID: String) -> String {
        liveSession(sessionID)?.displayName
            ?? services.liveSessions.items.first { $0.state.sessionID == sessionID }?.state.title
            ?? services.liveSessions.recentlyEnded.first { $0.sessionID == sessionID }?.title ?? "Agent"
    }

    /// 发送目标此刻显示的状态：本机的取桥上的实时值，别的 Mac 上的取同步记录，已结束的是"已结束"。
    func shown(_ target: AgentTarget) -> PiShown {
        switch route(of: target.session) {
        case .local(let live): shown(live)
        case .remote(let state): services.settings.shown(state, delivery: services.liveSessions.deliveries[state.sessionID])
        case .ended: PiShown(state: .known(.ended))
        }
    }

    /// 完整说法："发给 Agent 会话「…」"（已结束的是"唤醒 Agent 会话「…」并发送"），用在菜单项、提示与读屏（按钮上另有省略后的写法，见 `SendControl`）。
    func action(for target: AgentTarget) -> String {
        let name = sessionName(target.session)
        return isEnded(target) ? "唤醒 Agent 会话「\(name)」并发送" : "发给 Agent 会话「\(name)」"
    }

    /// 右键菜单里提示词的"发给 …"一项；本项目没有会话时是"交给 Agent"并禁用。
    @ViewBuilder
    func sendButton(_ target: AgentTarget?, action: @escaping (AgentTarget) -> Void) -> some View {
        if let target {
            Button(self.action(for: target), systemImage: "paperplane") { action(target) }
        } else {
            // 菜单项标签里的第二行 Text 是 macOS 菜单的副标题
            Button {} label: {
                Text("交给 Agent")
                Text("本项目还没有 Agent 会话")
            }
            .disabled(true)
        }
    }

    /// 这个 Pi 会话此刻连着桥的那个进程；没有就是已结束。
    func liveSession(_ sessionID: String) -> CuePi.PiSession? {
        services.pi.session(sessionID: sessionID)
    }

    /// 桥上一个在线会话此刻显示的状态：与会话行同一条规则（`PiShown`），摘要与在路上的话取同步记录。
    func shown(_ session: CuePi.PiSession) -> PiShown {
        services.settings.shown(
            .live(session, hostID: services.hostID, projectID: sendState.projects[session.id], recap: services.liveSessions.recaps[session.sessionID]),
            delivery: services.liveSessions.deliveries[session.sessionID])
    }

    /// 发给 Agent（存储格式正文）；成功后提示，会话正忙时转为询问马上说还是等它做完再说。返回是否已送达。
    @discardableResult
    func send(_ stored: String, to target: AgentTarget, card: UUID? = nil) async -> Bool {
        let done = Dotted("已" + action(for: target), target.mode == .steer || target.mode == .followUp ? target.mode.label : nil)
        do {
            switch route(of: target.session) {
            case .local(let live): try await services.send(stored, to: live.id, mode: target.mode, card: card)
            case .remote(let session): try await services.send(stored, toRemote: session, mode: target.mode, card: card)
            case .ended: try await services.send(stored, toEnded: target.session, named: sessionName(target.session), card: card)
            }
            sendState.choice = AgentTarget(session: target.session)
            say(done)
            return true
        } catch SendError.piSessionBusy {
            sendState.busy = SendState.Busy(text: stored, session: target.session, card: card)
            return false
        } catch {
            fail(error)
            return false
        }
    }

    func resolveBusySend(_ mode: DeliveryMode) {
        guard let pending = sendState.busy else { return }
        sendState.busy = nil
        Task { await send(pending.text, to: AgentTarget(session: pending.session, mode: mode), card: pending.card) }
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
        for await _ in Observations({ self.sessionPlacement }) { await refreshSessionProjects() }
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
