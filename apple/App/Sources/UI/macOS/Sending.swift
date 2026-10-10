#if os(macOS)
import CuePi
import CueStore
import CueText
import Foundation
import SwiftUI

/// 发给哪个 Agent 会话、用哪种方式（直接发送；会话正忙时马上说或等它做完再说）。Mac 上只有提示词发给 Agent（`CardMenu.handsToAgent`）。
struct AgentTarget: Equatable {
    var session: CuePi.PiSession.ID
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

    /// 当前生效的会话：用户选过或发过的（已结束时照样保留，界面写"已结束"，不悄悄换掉；同一个 Pi 会话重新打开了就接回新开的那个），
    /// 否则本项目的会话——在线的优先，都结束了就是刚结束的那个（同样写"已结束"）；本项目一个都没有时为 nil。
    func agentTarget(for project: UUID?) -> AgentTarget? {
        if let sendChoice {
            if let live = current(sendChoice) { return live }
            if services.pi.endedSessions[sendChoice.session] != nil { return sendChoice }
        }
        if let live = projectSessions(in: project).first { return AgentTarget(session: live.id) }
        if let ended = endedSessions(in: project).first { return AgentTarget(session: ended.id) }
        return nil
    }

    /// 本次运行里结束了、也没有重新打开的本项目 Pi 会话，最近结束的在前。
    private func endedSessions(in project: UUID?) -> [CuePi.PiSession] {
        guard let project else { return [] }
        let open = Set(services.pi.slots.map(\.sessionID))
        return services.pi.endedSessions.values
            .filter { sessionProjects[$0.id] == project && !open.contains($0.sessionID) }
            .sorted { (endedOrder.firstIndex(of: $0.id) ?? -1) > (endedOrder.firstIndex(of: $1.id) ?? -1) }
    }

    /// 会话已结束、也没有重新打开：发不出去，发送钮写"<会话名> · 已结束"，点开改选。
    func isEnded(_ target: AgentTarget) -> Bool { session(target.session) == nil }

    /// 选过的会话现在指向谁：还活着就是它；已结束但同一个 Pi 会话（`sessionID`）重新打开了——新进程是新的 id——接回新开的那个；
    /// 已结束且没有重开时为 nil。
    private func current(_ target: AgentTarget) -> AgentTarget? {
        guard session(target.session) == nil else { return target }
        guard let ended = services.pi.endedSessions[target.session],
              let reopened = services.pi.session(sessionID: ended.sessionID)
        else { return nil }
        return AgentTarget(session: reopened.id, mode: target.mode)
    }

    /// Pi 会话的显示名：活着的会话，或本次运行里已结束的会话最后的样子。
    func sessionName(_ id: CuePi.PiSession.ID) -> String {
        (session(id) ?? services.pi.endedSessions[id]).map(\.displayName) ?? "Agent"
    }

    /// 完整说法："发给 Agent 会话「…」"，用在菜单项、提示与读屏（按钮上另有省略后的写法，见 `SendControl`）。
    func action(for target: AgentTarget) -> String { "发给 Agent 会话「\(sessionName(target.session))」" }

    /// 右键菜单里提示词的"发给 …"一项；会话已结束时写明并禁用（发了也只会报错）；本项目没有会话时是"交给 Agent"并禁用。
    @ViewBuilder
    func sendButton(_ target: AgentTarget?, action: @escaping (AgentTarget) -> Void) -> some View {
        if let target, !isEnded(target) {
            Button(self.action(for: target), systemImage: "paperplane") { action(target) }
        } else {
            // 菜单项标签里的第二行 Text 是 macOS 菜单的副标题
            Button {} label: {
                Text(target.map(self.action(for:)) ?? "交给 Agent")
                Text(target == nil ? "本项目还没有 Agent 会话" : "已结束")
            }
            .disabled(true)
        }
    }

    func session(_ id: CuePi.PiSession.ID) -> CuePi.PiSession? {
        services.pi.session(id: id)
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
            try await services.send(stored, to: target.session, mode: target.mode, card: card)
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

/// Pi 会话（在线与本次运行里已结束的）或项目目录绑定变化时，重算会话归属的项目、记下结束的先后。
struct SessionProjectsTracker: ViewModifier {
    let workspace: Workspace

    private struct Key: Equatable {
        var sessions: [String]
        /// 已结束的单列：会话从在线变成结束时键必须变（混在一起时字符串可能不变，重算就不会触发）
        var ended: Set<String>
        var directories: [UUID: String]?
    }

    func body(content: Content) -> some View {
        let pi = workspace.services.pi
        let key = Key(
            sessions: pi.slots.map { "\($0.id) \($0.cwd.path)" }, ended: Set(pi.endedSessions.keys),
            directories: workspace.catalog?.directories)
        content
            .task(id: key) { await workspace.refreshSessionProjects() }
    }
}
#endif
