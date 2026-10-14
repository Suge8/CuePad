import CueStore
import SwiftUI

nonisolated extension PiSessionState {
    /// 标出是哪家 Agent 的会话时写的名字：Pi 是默认，不标；其余是 `AgentKind.name`。其他版本写的、不认识的不标。
    var agentMark: String? { agent.known.flatMap { $0 == .pi ? nil : $0.name } }
}

/// 会话是哪家 Agent 的（会话行、会话页标题区、⌘K、菜单栏面板同一个）：名字后面次要墨色的一小段，与所在、时长同一号字。
/// 品牌图标到了接在这里（名字前面），各处不另改。
struct AgentMark: View {
    let session: PiSessionState
    var font = Typography.meta
    @Environment(\.palette) private var palette

    var body: some View {
        if let name = session.agentMark {
            Text(name).font(font).foregroundStyle(palette.ink3).lineLimit(1)
        }
    }
}
