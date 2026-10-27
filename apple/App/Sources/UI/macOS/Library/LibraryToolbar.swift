#if os(macOS)
import SwiftUI

/// 工具栏中间的标题位（`PageTitleSlot`）：技能与规则页的规则｜技能两段（`LibraryPanes`），同手机页顶中间那一块，也是页名。
/// 定宽（两颗的字不随数据变）；开着文件页时这一位换成文件页的标题（`OverlayTitle`）。
struct LibraryPanesSlot: View {
    var body: some View {
        LibraryPanes()
            .frame(height: PaneMetrics.square)
            .padding(PaneMetrics.inset)
            .glass(in: .capsule)
            .fixedSize()
    }
}

/// 工具栏右边、搜索之前：技能与规则页的说明（`LibraryHelp`），气泡从这颗圆钮长出。工具栏项不在页面那棵视图里，框按窗口坐标量（`WindowFrame`）。
/// 别的页宽 0、随这一页第一次挂上才建（`PageControl`，规矩同 `ScopeSlot`）；开着文件页时看不见；这台还没写下快照时停用。
struct LibraryHelpSlot: View {
    @Environment(Workspace.self) private var workspace
    @State private var open = false
    @State private var frame: CGRect?

    var body: some View {
        PageControl(.library) {
            Button { open.toggle() } label: { Image(.help) }
                .buttonStyle(ControlButtonStyle(kind: .circular))
                .help("说明")
                .accessibilityLabel("说明")
                .disabled(workspace.library == nil)
                .background { WindowFrame(\.self) { frame = $0 } }
                .panel(isPresented: $open, style: .bubble(frame.map(BubbleSource.control) ?? .unanchored)) {
                    if let library = workspace.library { LibraryHelp(library: library) }
                }
        }
        .padding(.leading, Spacing.toolbarGap)
        .toolbarVisible(workspace.overlay == nil)
        .toolbarPresence(workspace.root == .library)
    }
}
#endif
