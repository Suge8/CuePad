import CueStore
import SwiftUI

nonisolated extension AgentKind {
    var mark: BrandMark {
        switch self {
        case .pi: .pi
        case .claudeCode: .claudeCode
        case .codex: .codex
        case .opencode: .opencode
        // Grok Build 没有自己的标志，用的就是 Grok 的
        case .grok: .grok
        // dsh 自己的标志就是 DeepSeek 的鲸鱼（它网页版的图标）
        case .dsh: .deepseek
        }
    }
}

nonisolated extension PiSessionState {
    /// 其他版本写的、不认识的 Agent 为 nil，不标。
    var agentMark: String? { agent.known?.name }
}

/// 会话列表的行只放标志（`named` 为 false）：行里名字优先，名字后再跟一串文字标、加上 Cue 的小头像，窄处名字会被挤成"…"。
struct AgentMark: View {
    let session: PiSessionState
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
