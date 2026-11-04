#if os(macOS)
import SwiftUI

/// 主栏栏头里技能与规则页的规则｜技能两段（`LibraryPanes`），同手机页顶中间那一块，也是页名。
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

/// 主栏栏头右边、搜索之前：技能与规则页的说明（`LibraryHelp`），栏头那一排的玻璃问号（`HelpButton`）。
/// 开着文件页时看不见、位置照留（`keepsPlace`：左边的分段与文件页标题不挪）；这台还没写下快照时停用。
struct LibraryHelpSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HelpButton(kind: .circular, size: .regular) {
            if let library = workspace.library { LibraryHelp(library: library) }
        }
        .disabled(workspace.library == nil)
        .padding(.leading, Spacing.item)
        .keepsPlace(shown: workspace.overlay == nil)
    }
}
#endif
