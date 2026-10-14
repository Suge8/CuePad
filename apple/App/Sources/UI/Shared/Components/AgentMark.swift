import CueStore
import SwiftUI

nonisolated extension AgentKind {
    /// 品牌标志：LobeHub 的单色标志转成的自定义符号（资源目录 Providers 下，由 design/tools/provider-symbols.py 生成），
    /// 与文字基线对齐、随字号缩放、能嵌进 `Text` 插值，颜色跟着前景色走。
    var icon: Image { Image("provider-" + iconName) }

    private var iconName: String {
        switch self {
        case .pi: "pi"
        case .claudeCode: "claudecode"
        case .codex: "codex"
        case .opencode: "opencode"
        }
    }
}

nonisolated extension PiSessionState {
    /// 标出是哪家 Agent 的会话时写的名字：Pi 是默认，不标；其余是 `AgentKind.name`。其他版本写的、不认识的不标。
    var agentMark: String? { agent.known.flatMap { $0 == .pi ? nil : $0.name } }
}

/// 会话是哪家 Agent 的（会话行、会话页标题区、⌘K、菜单栏面板同一个）：标志与名字，次要墨色，与所在、时长同一号字。
struct AgentMark: View {
    let session: PiSessionState
    var font = Typography.meta
    @Environment(\.palette) private var palette

    var body: some View {
        if let name = session.agentMark, let kind = session.agent.known {
            Text("\(kind.icon) \(name)").font(font).foregroundStyle(palette.ink3).lineLimit(1)
        }
    }
}
