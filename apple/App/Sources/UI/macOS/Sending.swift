#if os(macOS)
import CueDispatch
import CuePi
import CueStore
import CueText
import Foundation
import SwiftUI

extension Workspace {
    /// 项目的 Pi 会话：按工作目录归入（Store 判定），空闲的在前。
    func liveSessions(in project: UUID?) -> [CuePi.PiSession] {
        guard let project else { return [] }
        return services.pi.sessions
            .filter { sessionProjects[$0.id] == project }
            .sorted { !$0.state.isBusy && $1.state.isBusy }
    }

    /// 当前生效的目标：用户选过或发过的（指向的 Pi 会话已结束时照样保留，界面写"已结束"，不悄悄换掉；同一个 Pi 会话重新打开了就接回新开的那个），
    /// 否则本项目的 Pi 会话——在线的优先，都结束了就是刚结束的那个（同样写"已结束"，不退回到应用）——否则上一个前台应用。
    func effectiveChoice(for project: UUID?) -> AppServices.Destination {
        if let sendChoice {
            if let live = current(sendChoice) { return live }
            if case .pi(let id, _) = sendChoice, services.pi.endedSessions[id] != nil { return sendChoice }
        }
        if let live = liveSessions(in: project).first { return .pi(live.id, .send) }
        if let ended = endedSessions(in: project).first { return .pi(ended.id, .send) }
        return .app(.lastFrontmost)
    }

    /// 本次运行里结束了、也没有重新打开的本项目 Pi 会话，最近结束的在前。
    private func endedSessions(in project: UUID?) -> [CuePi.PiSession] {
        guard let project else { return [] }
        let open = Set(services.pi.sessions.map(\.sessionID))
        return services.pi.endedSessions.values
            .filter { sessionProjects[$0.id] == project && !open.contains($0.sessionID) }
            .sorted { (endedOrder.firstIndex(of: $0.id) ?? -1) > (endedOrder.firstIndex(of: $1.id) ?? -1) }
    }

    /// 目标指向的 Pi 会话已结束、也没有重新打开：发不出去，界面写"<会话名> · 已结束"，点开改选。
    func isEnded(_ choice: AppServices.Destination) -> Bool {
        if case .pi(let id, _) = choice { session(id) == nil } else { false }
    }

    /// 选过的目标现在指向谁：Pi 会话还活着就是它；已结束但同一个 Pi 会话（`sessionID`）重新打开了——新进程是新的 id——接回新开的那个；
    /// 已结束且没有重开时为 nil。应用与剪贴板总是可用。
    private func current(_ choice: AppServices.Destination) -> AppServices.Destination? {
        guard case .pi(let id, let mode) = choice, session(id) == nil else { return choice }
        guard let ended = services.pi.endedSessions[id],
              let reopened = services.pi.sessions.first(where: { $0.sessionID == ended.sessionID })
        else { return nil }
        return .pi(reopened.id, mode)
    }

    /// Pi 会话的显示名：活着的会话，或本次运行里已结束的会话最后的样子。
    func sessionName(_ id: CuePi.PiSession.ID) -> String {
        (session(id) ?? services.pi.endedSessions[id]).map(\.displayName) ?? "Pi"
    }

    /// 方式加目标的完整说法："发给 …" / "放进 Pi 会话「…」的输入框"，用在菜单项、提示与读屏（按钮上另有省略后的写法，见 `SendControl`）。
    func action(for choice: AppServices.Destination) -> String {
        if case .pi(_, .paste) = choice { "放进 \(label(for: choice))" } else { "发给 \(label(for: choice))" }
    }

    /// 目标的完整说法。
    func label(for choice: AppServices.Destination) -> String {
        switch choice {
        case .pi(let id, let mode): "Pi 会话「\(sessionName(id))」" + (mode == .paste ? "的输入框" : "")
        case .app(.bundleID(let bundleID)): services.appName(bundleID: bundleID)
        case .app(.lastFrontmost): services.lastFrontmostApp()?.name ?? "上一个前台应用"
        case .clipboard: "剪贴板"
        }
    }

    /// 右键菜单里的"发给 …"一项。发不出去时写明原因并禁用（发了也只会报错）：指向的 Pi 会话已结束，副标题"已结束"；
    /// 目标是上一个前台应用而 CuePad 启动后还没有别的应用到过前台，标题"发给前台应用"、副标题"还没有"。
    @ViewBuilder
    func sendButton(_ choice: AppServices.Destination, action: @escaping () -> Void) -> some View {
        if isEnded(choice) {
            Button(action: action) {
                Text(self.action(for: choice))
                Text("已结束")
            }
            .disabled(true)
        } else if choice == .app(.lastFrontmost), services.lastFrontmostApp() == nil {
            // 菜单项标签里的第二行 Text 是 macOS 菜单的副标题
            Button(action: action) {
                Text("发给前台应用")
                Text("还没有")
            }
            .disabled(true)
        } else {
            Button(self.action(for: choice), systemImage: "paperplane", action: action)
        }
    }

    func session(_ id: CuePi.PiSession.ID) -> CuePi.PiSession? {
        services.pi.sessions.first { $0.id == id }
    }

    /// 发送存储格式正文；成功后提示，Pi 忙时转为询问插话或排队。返回是否已发出（发给 Pi 时是已送达）。
    @discardableResult
    func send(_ stored: String, via choice: AppServices.Destination, card: UUID? = nil, task: UUID? = nil) async -> Bool {
        await send(stored, via: choice, card: card, task: task, remembering: choice)
    }

    private func send(
        _ stored: String, via choice: AppServices.Destination, card: UUID?, task: UUID?, remembering: AppServices.Destination
    ) async -> Bool {
        let done = switch choice {
        case .clipboard: "已复制"
        case .pi(_, .steer): "已插话"
        case .pi(_, .followUp): "已排队"
        default: "已" + action(for: choice)
        }
        do {
            try await services.send(stored, to: choice, card: card, task: task)
            remember(remembering)
            say(done)
            return true
        } catch SendError.unrecorded(let reason) {
            remember(remembering)
            say("\(done)，但没能记下这次发送：\(reason)", isError: true)
            return true
        } catch SendError.piSessionBusy {
            if case .pi(let id, _) = choice { busySend = BusySend(text: stored, session: id, card: card, task: task) }
            return false
        } catch {
            fail(error)
            return false
        }
    }

    /// 发出去过的目标就是用户在用的目标：记住它，会话结束后按钮写"已结束"、重新打开时接回，不再按默认规则悄悄换掉。
    /// 复制到剪贴板（右键"复制"、分块复制）不算换目标。
    private func remember(_ choice: AppServices.Destination) {
        if choice != .clipboard { sendChoice = choice }
    }

    func resolveBusySend(_ mode: DeliveryMode) {
        guard let pending = busySend else { return }
        busySend = nil
        Task {
            await send(
                pending.text, via: .pi(pending.session, mode), card: pending.card, task: pending.task,
                remembering: .pi(pending.session, .send))
        }
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
            sessions: pi.sessions.map { "\($0.id) \($0.cwd.path)" }, ended: Set(pi.endedSessions.keys),
            directories: workspace.catalog?.directories)
        content.task(id: key) { await workspace.refreshSessionProjects() }
    }
}
#endif
