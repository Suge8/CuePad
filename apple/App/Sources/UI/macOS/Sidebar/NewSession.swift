#if os(macOS)
import SwiftUI

struct NewSessionPanel: ViewModifier {
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        // 从刚点的那一下长出（点"＋"、点"开始"旁的箭头）
        let from: CGPoint? = if case .press(let point) = workspace.press.source { point } else { nil }
        return content.panel(item: Bindable(workspace).newSession, style: .bare(from: from)) { NewSessionInput(start: $0) }
    }
}
#endif
