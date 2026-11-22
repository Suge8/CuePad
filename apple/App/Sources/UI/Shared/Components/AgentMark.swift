import CueStore
import SwiftUI

nonisolated extension AgentKind {
    var mark: BrandMark {
        switch self {
        case .pi: .pi
        case .claudeCode: .claudeCode
        case .codex: .codex
        case .opencode: .opencode
        case .grok: .grok
        case .dsh: .deepseek
        }
    }
}

nonisolated extension SessionState {
    var agentMark: String? { agent.known?.name }
}

struct AgentMark: View {
    let session: SessionState
    var font = Typography.meta
    var named = true
    @Environment(\.palette) private var palette

    var body: some View {
        if let name = session.agentMark, let kind = session.agent.known {
            (named ? Text("\(kind.mark.image) \(name)") : Text(kind.mark.image)).font(font).foregroundStyle(palette.ink3).lineLimit(1)
                .accessibilityLabel(name)
        }
    }
}
