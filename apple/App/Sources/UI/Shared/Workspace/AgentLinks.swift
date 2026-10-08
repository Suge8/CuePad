import CueStore
import SwiftUI

/// 灵感与任务交给了哪个 Agent 会话、那个会话此刻怎样（含发送中、有新回复）：行与卡上的状态点读它。
/// 会话来自 `CueStore.handedSessions`（执行过的记在卡上，手机发出还没执行的读投送请求）。
nonisolated struct AgentLinks: Sendable, Equatable {
    var items: [UUID: PiSessionListItem]
    /// 从这条开了新会话、还没开好（"正在开会话"）。
    var launching: Set<UUID>

    static let tables: Set<StoreTable> = [.cards, .piSessionStates, .deliveryRequests]

    static func read(from store: isolated CueStore) throws -> AgentLinks {
        let handed = try store.handedSessions()
        var sessions: [String: PiSessionListItem] = [:]
        for case .session(let id) in Set(handed.values) {
            sessions[id] = try store.piSessionPage(PiSessionQuery(id: PiSessionState.recordID(sessionID: id))).items.first
        }
        return AgentLinks(
            items: handed.compactMapValues { if case .session(let id) = $0 { sessions[id] } else { nil } },
            launching: Set(handed.filter { $0.value == .launching }.keys))
    }
}

extension EnvironmentValues {
    /// 这一页的灵感与任务交给的会话（`AgentLinks.items`），由页面读一次放进环境，卡与行各取自己的。
    @Entry var cardAgents = AgentLinks(items: [:], launching: [])
}

/// 灵感或任务上的会话状态点（发送中、工作中、等你确认、有新回复……，同 `PiStateDot`）：点它看那个会话；
/// 开新会话还没开好时是一圈靛青空心点（"正在开会话"）。没交给过 Agent 时不画。
struct AgentDot: View {
    let card: UUID
    @Environment(\.cardAgents) private var agents
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        if agents.launching.contains(card) {
            Circle().strokeBorder(palette.signature, lineWidth: 1.5).frame(width: 8, height: 8)
                .frame(width: 28, height: 28)
                .accessibilityLabel("正在开会话")
                .help("正在开会话")
        } else if let item = agents.items[card] {
            let shown = services.settings.shown(item)
            #if os(iOS)
            Button { navigation.openSession(item.state.id, sessionID: item.state.sessionID, store: services.store) } label: {
                PiStateDot(shown: shown, size: 8).frame(width: 28, height: 28).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.state.title) \(shown.presence)")
            .accessibilityHint("看 Agent 的会话")
            #else
            PiStateDot(shown: shown, size: 7)
                .sessionLink(item.state.sessionID)
                .help("交给了 Agent 会话「\(item.state.title)」：\(shown.presence)，点开看近况")
            #endif
        }
    }
}
