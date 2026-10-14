import CueStore
import SwiftUI

nonisolated extension AgentKind {
    /// 这家 Agent 的产品标志（`BrandMark`）。
    var mark: BrandMark {
        switch self {
        case .pi: .pi
        case .claudeCode: .claudeCode
        case .codex: .codex
        case .opencode: .opencode
        }
    }
}

/// 选哪家 Agent 的菜单里的一项：标志与名字。macOS 27、iPadOS 27 起菜单默认藏起选项的图片，这里的标志说的是"哪一家"
/// （对象而非动作），要显示（同模型菜单，`ChoiceMenu`）。
struct AgentLabel: View {
    let kind: AgentKind

    var body: some View {
        Label { Text(kind.name) } icon: { kind.mark.image }.labelStyle(.titleAndIcon)
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
            (named ? Text("\(kind.mark.image) \(name)") : Text(kind.mark.image)).font(font).foregroundStyle(palette.ink3).lineLimit(1)
                .accessibilityLabel(name)
        }
    }
}
