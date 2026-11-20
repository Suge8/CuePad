#if os(macOS)
import SwiftUI

/// 新会话与记任务的输入框（`NewSessionInput`、`NewTaskInput`）：同一种浮法。
struct NewInputPanel: ViewModifier {
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        // 从刚点的那一下长出（点"＋"、点"开始"旁的箭头）
        let from: CGPoint? = if case .press(let point, _) = workspace.press.source { point } else { nil }
        return content
            .panel(item: Bindable(workspace).newSession, style: .bare(from: from)) { NewSessionInput(start: $0) }
            .panel(item: Bindable(workspace).newTask, style: .bare(from: from)) { NewTaskInput(start: $0) }
    }
}
#endif
