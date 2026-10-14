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

/// 会话是哪家 Agent 的，次要墨色，与所在、时长同一号字。会话页标题区写标志与名字；会话列表的行（侧栏、Agent 页、⌘K、菜单栏面板、
/// iPhone 列表）只放标志（`named` 为 false）：行里名字优先，名字后再跟一串文字标、加上 Cue 的小头像，窄处名字会被挤成"…"。
struct AgentMark: View {
    let session: PiSessionState
    var font = Typography.meta
    var named = true
    @Environment(\.palette) private var palette

    var body: some View {
        if let name = session.agentMark, let kind = session.agent.known {
            (named ? Text("\(kind.icon) \(name)") : Text(kind.icon)).font(font).foregroundStyle(palette.ink3).lineLimit(1)
                .accessibilityLabel(name)
        }
    }
}
