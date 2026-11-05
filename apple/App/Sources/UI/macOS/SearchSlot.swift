#if os(macOS)
import SwiftUI

/// 搜索（⌘K）：主区栏头右端、"⋯"左边的一颗玻璃圆钮（Mac 的惯例：工具栏右端是这一页的操作与搜索）。
/// 浏览页与辅助页的栏头（`MainColumn`）、看板那一排、会话栏头（`WideSessionTitle`）都有；并排两个会话时只在左半的栏头上，一个窗口只一颗。
struct SearchSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("搜索", icon: .search) { workspace.searching.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .help("搜索（⌘K）")
            .disabled(!workspace.isLibraryReady)
    }

    /// 栏头右端让给它的宽：钮前那道缝与圆钮。
    static let reserve = Spacing.item + ControlMetrics.height
}
#endif
