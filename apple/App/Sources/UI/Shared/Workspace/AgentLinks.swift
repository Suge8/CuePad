import CueStore
import SwiftUI

/// 灵感与任务交给了哪个 Agent 会话、那个会话此刻怎样（含发送中、有新回复）：行与卡上的状态点读它。
/// 会话来自 `CueStore.handedSessions`（执行过的记在卡上，手机发出还没执行的读投送请求）。
nonisolated struct AgentLinks: Sendable, Equatable {
    var items: [UUID: PiSessionListItem]
    /// 从这条开了新会话、还没开好（"正在开会话"）。
    var launching: Set<UUID>

    static func read(from store: isolated CueStore) throws -> AgentLinks {
        let handed = try store.handedSessions()
        let sessions = try store.piSessions(sessionIDs: handed.values.compactMap { if case .session(let id) = $0 { id } else { nil } })
        return AgentLinks(
            items: handed.compactMapValues { if case .session(let id) = $0 { sessions[id] } else { nil } },
            launching: Set(handed.filter { $0.value == .launching }.keys))
    }
}

extension EnvironmentValues {
    /// 灵感与任务交给的会话（`AgentLinks.items`）：整个窗口一份（`Workspace.agentLinks`），由 `WindowCardAgents` 放进环境，
    /// 页面、卡与行各取自己的，不自己订阅。
    @Entry var cardAgents = AgentLinks(items: [:], launching: [])
}

/// 把窗口那一份交给的会话放进环境。单独一层读它：会话状态变化时只重算这一层与读环境的卡和行，不重算外面的根视图。
/// 浮层（任务面板、Mac 的任务气泡）不在页面下，读它的各自挂一层。否决的方案：在窗口根挂一次盖住页面与浮层——
/// 会话状态每变一次，工具栏与分栏也跟着重算，实测主线程指令数是现在的约 4 倍。
struct WindowCardAgents: ViewModifier {
    let workspace: Workspace

    func body(content: Content) -> some View { content.environment(\.cardAgents, workspace.agentLinks) }
}

/// 灵感或任务上的会话状态点（发送中、工作中、等你确认、有新回复……，同 `PiStateDot`）：点它看那个会话；
/// 开新会话还没开好时是一圈石绿空心点（"正在开会话"，在动的状态同 `PiShown.tint`）。没交给过 Agent 时不画。
struct AgentDot: View {
    let card: UUID
    @Environment(\.cardAgents) private var agents
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        if agents.launching.contains(card) {
            Circle().strokeBorder(palette.signature, lineWidth: 1.5).frame(width: 8, height: 8)
                .relaySpot(task: card)
                .frame(width: 28, height: 28)
                .accessibilityLabel("正在开会话")
                .help("正在开会话")
        } else if let item = agents.items[card] {
            let shown = workspace.shown(item)
            #if os(iOS)
            Button { navigation.openSession(item.state.id, sessionID: item.state.sessionID, store: services.store) } label: {
                PiStateDot(shown: shown, size: 8).relaySpot(session: item.state.sessionID, row: .task).frame(width: 28, height: 28).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.state.title) \(shown.presence)")
            .accessibilityHint("看 Agent 的会话")
            #else
            PiStateDot(shown: shown, size: 7)
                .relaySpot(session: item.state.sessionID, row: .task)
                .sessionLink(item.state.sessionID, press: .control)
                .help("交给了 Agent 会话「\(item.state.title)」：\(shown.presence)，点开看近况")
            #endif
        }
    }
}
