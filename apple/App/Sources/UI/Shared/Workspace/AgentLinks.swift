import CueStore
import SwiftUI

nonisolated struct AgentLinks: Sendable, Equatable {
    var items: [UUID: SessionListItem]
    var launching: [UUID: AgentKind]

    static func read(from store: isolated CueStore) throws -> AgentLinks {
        let handed = try store.handedSessions()
        let sessions = try store.sessionItems(sessionIDs: handed.values.compactMap { if case .session(let id) = $0 { id } else { nil } })
        return AgentLinks(
            items: handed.compactMapValues { if case .session(let id) = $0 { sessions[id] } else { nil } },
            launching: handed.compactMapValues { if case .launching(let kind) = $0 { kind } else { nil } })
    }
}

extension EnvironmentValues {
    @Entry var cardAgents = AgentLinks(items: [:], launching: [:])
}

struct WindowCardAgents: ViewModifier {
    let workspace: Workspace

    func body(content: Content) -> some View { content.environment(\.cardAgents, workspace.agentLinks) }
}

struct AgentDot: View {
    let card: UUID
    static let overhang: CGFloat = 8
    @Environment(\.cardAgents) private var agents
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        if workspace.isLaunching(card, in: agents) {
            Circle().strokeBorder(palette.signature, lineWidth: 1.5).frame(width: 8, height: 8)
                .relaySpot(task: card)
                .frame(width: 28, height: 28)
                .accessibilityLabel("正在开会话")
                .help("正在开会话")
        } else if let item = agents.items[card] {
            let shown = workspace.shown(item)
            #if os(iOS)
            Button { workspace.openSession(item.state.id, sessionID: item.state.sessionID) } label: {
                StateDot(shown: shown, size: 8).relaySpot(session: item.state.sessionID, row: .task)
                    .frame(width: ControlSize.target, height: ControlSize.target).contentShape(.rect)
            }
            .buttonStyle(PressStyle(.inline))
            .accessibilityLabel("\(item.state.title) \(shown.presence)")
            .accessibilityHint("看 Agent 的会话")
            #else
            StateDot(shown: shown, size: 7)
                .relaySpot(session: item.state.sessionID, row: .task)
                .sessionLink(item.state.sessionID, press: .control)
                .help("交给了 Agent 会话「\(item.state.title)」：\(shown.presence)，点开看近况")
            #endif
        }
    }
}
