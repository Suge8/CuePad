import QuartzCore
import SwiftUI

/// 接力的一头：会话 id 与它的任务（请求带着的那张卡）；`opens` 是这次交给开出了这个会话（start）。
nonisolated struct RelayEnd: Equatable, Sendable {
    var session: String
    var task: UUID?
    var opens = false
}

/// Cue 那一头落在哪：同时在屏上几处时取排在前面的。三端的规则就是这个顺序——
/// Mac 与 iPad 有侧栏时总落在侧栏的 Cue 一行（在不在 Cue 页都一样），侧栏收起时退到 Cue 页页头；
/// iPhone 没有侧栏：在 Cue 页落在页头的头像（从底部往上飞一长段，最看得出），在三页上落在底部那一排的 Cue 钮。
enum CueSpot: Int {
    /// 侧栏最上面的 Cue（Mac 是名片 `CueSidebarCard`、iPad 是那一行，头像都是 `CueEntryAvatar`；菜单栏面板、输入条在别的窗口，不参与）。
    case entry
    case header
    /// iPhone 三页底部那一排的 Cue 钮。
    case dock
}

/// 会话那一头落在哪：屏上有它的几处时取最具体的（`rank` 小的）。只有此刻在接力的珠子、会话与任务挂锚。
enum EndSpot: Equatable {
    /// Cue 那一行里代表这份活的珠子，一个珠子可对应几个会话。
    case bead([String])
    /// 会话的状态标，按它所在的那一行分级（`Row`）。
    case session(String, Row)
    /// 任务圈与正在开会话的空心点：带着这件任务、或交给的会话就是它绑着的那个时算。
    case task(UUID, session: String?)
    /// "会话"那一格：iPhone 展开的三格、Mac 侧栏的会话磁贴；Cue 页收起的去处钮不接力。
    case dock

    /// 状态标所在的行，越具体越前。
    enum Row: Int {
        /// 会话自己那一行：会话列表、菜单栏面板、会话页的页头卡片。
        case own = 1
        /// 它的任务行（任务行、任务卡、任务页上代表它的那一格）。
        case task
        /// 项目行上的状态：Mac 侧栏行尾的状态标、iPad 与手机的此刻一行（`ProjectNowLine`）。
        case project
    }

    /// 对 `end` 来说有多具体；不是它的为 nil。
    func rank(for end: RelayEnd) -> Int? {
        switch self {
        case .bead(let sessions): sessions.contains(end.session) ? 0 : nil
        case .session(let session, let row): session == end.session ? row.rawValue : nil
        case .task(let task, let session): task == end.task || session == end.session ? Row.task.rawValue : nil
        case .dock: Row.project.rawValue + 1
        }
    }
}

extension View {
    /// Cue 那一行里这份活的珠子：它对应的会话正在接力时才挂锚，优先于所有会话、任务与去处落点。
    func relaySpot(bead sessions: [String]) -> some View { modifier(BeadSpot(sessions: sessions)) }

    /// 会话的状态标：接力的会话那一头，`row` 是它在哪种行里。只有此刻在接力的会话挂锚，平时什么都不加。
    /// 这次交给刚开出这个会话时，状态标先透明着，光落下时才亮出来（同 `relayArrival`）。
    func relaySpot(session: String?, row: EndSpot.Row = .own) -> some View { modifier(SessionSpot(session: session, row: row)) }

    /// 任务行（任务圈、正在开会话的那个空心点）：任务交给的会话在接力、或这件任务就是接力带着的那件时，接力落在这里。
    func relaySpot(task: UUID) -> some View { modifier(TaskSpot(task: task)) }

    /// Cue 的头像：接力的 Cue 那一头，环在这里亮起。
    func relaySpot(cue spot: CueSpot) -> some View { background { RelayAnchor(role: .cue(spot)) } }

    /// "会话"那一格（`EndSpot.dock`，`dock` 为真的那处）：会话哪一行都不在屏上时接力落在这里。一直挂着。
    func relaySpot(dock: Bool) -> some View { background { if dock { RelayAnchor(role: .end(.dock)) } } }

    /// 会话自己那一行：这次交给刚开出这个会话时，行先占着位置、透明，光落下时淡出来（`Stage.arriving`）。
    func relayArrival(session: String) -> some View { modifier(Arrival(session: session)) }
}

extension EnvironmentValues {
    /// 本窗口的接力舞台（`CueRelayStage` 放进来，引用不变）；不在主窗口里的（菜单栏面板、输入条）没有。
    @Entry var relayStage: CueRelayStage.Stage?
}

/// 珠子与会话状态标只读 `LiveSessions.flight`，不在窗口根上改环境值，避免每次接力让整棵视图树重算。
private struct BeadSpot: ViewModifier {
    let sessions: [String]
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        let flying = sessions.filter { workspace.services.liveSessions.relays(session: $0) }
        content.background {
            if !flying.isEmpty { RelayAnchor(role: .end(.bead(flying))).transition(.identity) }
        }
    }
}

private struct SessionSpot: ViewModifier {
    let session: String?
    let row: EndSpot.Row
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        let flying = session.flatMap { workspace.services.liveSessions.relays(session: $0) ? $0 : nil }
        content.modifier(Arrival(session: session)).background {
            if let flying { RelayAnchor(role: .end(.session(flying, row))).transition(.identity) }
        }
    }
}

/// 任务交给的会话从窗口那一份里取（`cardAgents`，行本来就读它）：会话在接力、或这张卡就是接力的那件任务时挂锚。
private struct TaskSpot: ViewModifier {
    let task: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents

    func body(content: Content) -> some View {
        let live = workspace.services.liveSessions
        let session = agents.items[task]?.state.sessionID
        let flying = live.relays(task: task) || session.map(live.relays(session:)) == true
        content.background {
            if flying { RelayAnchor(role: .end(.task(task, session: session))).transition(.identity) }
        }
    }
}

/// 新开出的会话那一行或它的状态标：舞台说它还在等光（`Stage.arriving`）时透明，光落下那一刻淡出来；藏起来是当场的，不淡出。
private struct Arrival: ViewModifier {
    let session: String?
    @Environment(\.relayStage) private var stage

    func body(content: Content) -> some View {
        let waits = session.map { stage?.arriving.contains($0) == true } == true
        content
            .opacity(waits ? 0 : 1)
            .animation(waits ? nil : HandOff.quick, value: waits)
    }
}
