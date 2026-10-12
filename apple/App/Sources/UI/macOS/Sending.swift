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
}

/// 一条提示词发给 Agent 的去处：某个会话，或在本项目的文件夹里开新会话。
enum HandOffDestination: Hashable {
    case session(String)
    case newSession
}

/// 交给哪个 Agent 会话的状态与规则：用户为任务挑的去处、等用户决定的一次发送、在线会话各归哪个项目，以及据此推出的提示词去处（`destination`，
/// 唯一的规则）、目标走哪条路送达、显示的名字与状态。不碰界面提示：成败由调用方（`Workspace.send`）说。
@Observable
final class SendState {
    /// Pi 会话正忙时待用户选择马上说或等它做完再说的一次发送；`session` 是 Pi 自己的会话 id。
    struct Busy {
        var text: String
        var session: String
        var card: UUID?
    }

    /// 一个发送目标走哪条路：本机桥上连着的会话；别的 Mac 上在线的会话；本机桥上没有的会话（已结束的，或托管着、进程歇着的）：
    /// 发送时由本机执行器在后台唤醒。
    enum Route {
        case local(CuePi.PiSession)
        case remote(PiSessionState)
        case ended
    }

    var busy: Busy?
    /// 用户在本窗口为任务挑的去处，按任务的 id；只对那个任务生效，窗口关了就没有。
    private(set) var picks: [UUID: HandOffDestination] = [:]
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
    /// 终端里开的会话桥上已经没有、记录还没来得及标成结束的不算（发送时它走"唤醒"那条路，菜单和默认目标也不列它）。
    /// 菜单与发送走的路都读它。
    private func isReachable(_ state: PiSessionState) -> Bool {
        state.hostID != services.hostID || state.hosted || liveSession(state.sessionID) != nil
    }

    /// 能交给的在线会话：所有 Mac 上的（手机的发给 Agent 输入框共用同一份规则，见 `HandOffTargets`），去掉本机已不在桥上的。
    func onlineTargets(for project: UUID?) -> [PiSessionListItem] {
        HandOffTargets.sessions(services.liveSessions.live, project: project).filter { isReachable($0.state) }
    }

    func route(of sessionID: String) -> Route {
        if let live = liveSession(sessionID) { return .local(live) }
        if let remote = services.liveSessions.live.first(where: { $0.state.sessionID == sessionID && $0.state.hostID != services.hostID }) {
            return .remote(remote.state)
        }
        return .ended
    }

    /// 项目的 Pi 会话：按工作目录归入（Store 判定），空闲的在前。
    /// 先按格子上不变的身份筛出本项目的，再读这些格子的状态：别的项目的会话状态变化不惊动读它的视图。
    func projectSessions(in project: UUID?) -> [CuePi.PiSession] {
        guard let project else { return [] }
        return services.pi.slots
            .filter { projects[$0.id] == project }
            .map(\.session)
            .sorted { !$0.state.isTurnRunning && $1.state.isTurnRunning }
    }

    /// 一条提示词默认交给哪里（一个任务一个 Agent 会话，同一任务的提示词接着发到同一个会话，新任务默认开新会话）：
    /// 用户在本窗口为它所在任务挑过的去处；否则它所在任务或它自己上次交给的会话（`recordSend` 记在两者上），只要这个会话还能送达或能在后台唤醒；
    /// 否则在本项目绑定的文件夹开新会话；没归入项目的没有默认（nil，由用户选）。`task` 是提示词所在的任务。
    func destination(of prompt: Card, task: Card?) -> HandOffDestination? {
        if let pick = prompt.parentID.flatMap({ picks[$0] }), canHand(to: pick) { return pick }
        if let last = [task?.piSessionID, prompt.piSessionID].compactMap(\.self).first(where: canHand(toSession:)) { return .session(last) }
        return prompt.projectID == nil ? nil : .newSession
    }

    /// 为提示词所在的任务挑去处。
    func pick(_ destination: HandOffDestination, for prompt: Card) {
        if let task = prompt.parentID { picks[task] = destination }
    }

    /// 交出去之后任务靠它自己的关联接着发到那个会话，挑过的不再留着。
    func clearPick(for prompt: Card) {
        if let task = prompt.parentID { picks[task] = nil }
    }

    private func canHand(to destination: HandOffDestination) -> Bool {
        switch destination {
        case .session(let id): canHand(toSession: id)
        case .newSession: true
        }
    }

    /// 会话此刻能交给：在线可达的，或本窗口刚结束、可以在后台唤醒的。
    private func canHand(toSession sessionID: String) -> Bool {
        services.liveSessions.live.contains { $0.state.sessionID == sessionID && isReachable($0.state) }
            || endedTargets.contains { $0.sessionID == sessionID }
    }

    /// 能选作发送目标的已结束会话：这个窗口打开后结束、也没有重新打开的，最近结束的在前。发给它们时在后台把会话恢复起来。
    var endedTargets: [PiSessionState] { services.liveSessions.recentlyEnded.filter { liveSession($0.sessionID) == nil } }

    /// 本机桥上没有这个会话：发送时先在后台唤醒它。去处里的状态点照记录写——已结束的写"已结束"，托管着、进程歇着的写它歇着的状态。
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
        case .local(let live):
            return shown(live)
        case .remote(let state):
            return services.settings.shown(state, delivery: services.liveSessions.deliveries[state.sessionID])
        case .ended:
            let resting = services.liveSessions.live.first { $0.state.sessionID == target.session && $0.state.hostID == services.hostID }
            return resting.map { services.settings.shown($0) } ?? PiShown(state: .known(.ended))
        }
    }

    /// 桥上一个在线会话此刻显示的状态：与会话行同一条规则（`PiShown`），摘要与在路上的话取同步记录。
    private func shown(_ session: CuePi.PiSession) -> PiShown {
        services.settings.shown(
            .live(session, hostID: services.hostID, projectID: projects[session.id], recap: services.liveSessions.recaps[session.sessionID]),
            delivery: services.liveSessions.deliveries[session.sessionID])
    }

    /// 完整说法："发给 Agent 会话「…」"（已结束的是"唤醒 Agent 会话「…」并发送"），用在提示与读屏（按钮上另有省略后的写法，见 `SendControl`）。
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
        do {
            switch route(of: target.session) {
            case .local(let live): try await services.send(stored, to: live.id, mode: target.mode, card: card)
            case .remote(let session): try await services.send(stored, toRemote: session, mode: target.mode, card: card)
            case .ended: try await services.send(stored, toEnded: target.session, named: sessionName(target.session), card: card)
            }
            return true
        } catch SendError.piSessionBusy {
            busy = Busy(text: stored, session: target.session, card: card)
            return false
        }
    }
}

extension Workspace {
    /// 把提示词发给 Agent，去处按 `SendState.destination`：整条正文，或 `text`（选中的部分，变量已填）。
    /// 会话正忙时转为询问；新会话开在项目绑定的文件夹（没绑时就地弹选文件夹，取消就不开）；没有默认去处时打开提示词的编辑页去选。
    func handOff(_ prompt: Card, text: String? = nil) {
        let text = text ?? Outgoing.text(of: prompt), id = prompt.id
        attempt {
            var task: Card?
            if let parent = prompt.parentID { task = try await self.services.store.card(parent) }
            switch self.sendState.destination(of: prompt, task: task) {
            // 交出去之后去处记在任务上（`recordSend`），挑过的不再留着：之后只认任务上记的那一个
            case .session(let session): if await self.send(text, to: AgentTarget(session: session), card: id) { self.sendState.clearPick(for: prompt) }
            case .newSession: try await self.startNewSession(for: prompt, text: text)
            case nil: self.open(prompt)
            }
        }
    }

    /// 在提示词所在项目绑定的文件夹开新会话，话作为第一句：行上先是"正在开会话"，开好后它和任务关联到新会话。
    private func startNewSession(for prompt: Card, text: String) async throws {
        guard let project = prompt.projectID else { return }
        if try await services.store.directory(of: project) == nil {
            guard let path = await ProjectDirectory.pick() else { return }
            try await services.store.setDirectory(path, for: project)
        }
        let title = catalog?.project(project)?.name ?? "新会话"
        _ = try await startSession(in: project, prompt: text.nonEmpty, title: title, card: prompt.id) {}
        sendState.clearPick(for: prompt)
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
