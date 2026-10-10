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

extension Workspace {
    /// 项目的 Pi 会话：按工作目录归入（Store 判定），空闲的在前。
    /// 先按格子上不变的身份筛出本项目的，再读这些格子的状态：别的项目的会话状态变化不惊动读它的视图。
    func projectSessions(in project: UUID?) -> [CuePi.PiSession] {
        guard let project else { return [] }
        return services.pi.slots
            .filter { sessionProjects[$0.id] == project }
            .map(\.session)
            .sorted { !$0.state.isTurnRunning && $1.state.isTurnRunning }
    }

    /// 当前生效的会话：用户选过或发过的（已结束时照样保留，界面写"已结束"，不悄悄换掉；同一个 Pi 会话重新打开了就是在线的那个），
    /// 否则本项目的会话——在线的优先，都结束了就是刚结束的那个（同样写"已结束"）；本项目一个都没有时为 nil。
    func agentTarget(for project: UUID?) -> AgentTarget? {
        if let sendChoice { return sendChoice }
        if let live = projectSessions(in: project).first { return AgentTarget(session: live.sessionID) }
        guard let project else { return nil }
        return endedTargets.first { $0.projectID == project }.map { AgentTarget(session: $0.sessionID) }
    }

    /// 能选作发送目标的已结束会话：这个窗口打开后结束、也没有重新打开的，最近结束的在前。发给它们时在后台把会话恢复起来。
    var endedTargets: [PiSessionState] { recentlyEnded.filter { liveSession($0.sessionID) == nil } }

    /// 会话已结束、也没有重新打开：发送时先在后台唤醒它，发送钮的状态点写"已结束"。
    func isEnded(_ target: AgentTarget) -> Bool { liveSession(target.session) == nil }

    /// Pi 会话的显示名：在线的取桥上的，结束了的取同步记录里的（`recentlyEnded`）。
    func sessionName(_ sessionID: String) -> String {
        liveSession(sessionID)?.displayName ?? recentlyEnded.first { $0.sessionID == sessionID }?.title ?? "Agent"
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
            .live(session, hostID: services.hostID, projectID: sessionProjects[session.id], recap: services.liveSessions.recaps[session.sessionID]),
            delivery: services.liveSessions.deliveries[session.sessionID])
    }

    /// 发给 Agent（存储格式正文）；成功后提示，会话正忙时转为询问马上说还是等它做完再说。返回是否已送达。
    @discardableResult
    func send(_ stored: String, to target: AgentTarget, card: UUID? = nil) async -> Bool {
        let done = Dotted("已" + action(for: target), target.mode == .steer || target.mode == .followUp ? target.mode.label : nil)
        do {
            if let live = liveSession(target.session) {
                try await services.send(stored, to: live.id, mode: target.mode, card: card)
            } else {
                try await services.send(stored, toEnded: target.session, named: sessionName(target.session), card: card)
            }
            sendChoice = AgentTarget(session: target.session)
            say(done)
            return true
        } catch SendError.piSessionBusy {
            busySend = BusySend(text: stored, session: target.session, card: card)
            return false
        } catch {
            fail(error)
            return false
        }
    }

    func resolveBusySend(_ mode: DeliveryMode) {
        guard let pending = busySend else { return }
        busySend = nil
        Task { await send(pending.text, to: AgentTarget(session: pending.session, mode: mode), card: pending.card) }
    }
}

/// Pi 会话或项目目录绑定变化时，重算在线会话归属的项目；并跟随同步记录里的会话摘要与结束了的会话。
struct SessionProjectsTracker: ViewModifier {
    let workspace: Workspace

    private struct Key: Equatable {
        var sessions: [String]
        var directories: [UUID: String]?
    }

    func body(content: Content) -> some View {
        let pi = workspace.services.pi
        let key = Key(
            sessions: pi.slots.map { "\($0.id) \($0.cwd.path)" }, directories: workspace.catalog?.directories)
        content
            .task(id: key) { await workspace.refreshSessionProjects() }
    }
}
#endif
