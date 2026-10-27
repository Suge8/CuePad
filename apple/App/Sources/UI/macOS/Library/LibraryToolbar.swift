#if os(macOS)
import SwiftUI

/// 工具栏左边、进展页分段的位置：技能与规则页的规则｜技能两段（`LibraryPanes`，同手机页顶那块玻璃里那一组），也是页名。
/// 规矩同 `ScopeSlot`：别的页宽 0、随这一页第一次挂上才建（`PageControl`）；开着文件页时宽度照旧、只是看不见（换的是盖住的那一页）。
struct LibraryPanesSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        PageControl(.library) {
            LibraryPanes()
                .frame(height: Spacing.toolbarControl - PanesSlot.inset * 2)
                .padding(PanesSlot.inset)
                .glass(in: .capsule)
        }
        .toolbarVisible(workspace.overlay == nil)
        .toolbarPresence(workspace.root == .library)
    }
}

/// 工具栏右边、搜索之前：技能与规则页的说明（`LibraryHelp`），气泡从这颗圆钮长出。工具栏项不在页面那棵视图里，框按窗口坐标量（`WindowFrame`）。
/// 规矩同 `LibraryPanesSlot`；这台还没写下快照时停用。
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
