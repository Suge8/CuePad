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

/// 主栏栏头右边、搜索之前：技能与规则页的说明（`LibraryHelp`），气泡从这颗圆钮长出，框按窗口坐标量（`WindowFrame`，窗口里的浮层用窗口坐标）。
/// 开着文件页时看不见、位置照留（`keepsPlace`：左边的分段与文件页标题不挪）；这台还没写下快照时停用。
struct LibraryHelpSlot: View {
    @Environment(Workspace.self) private var workspace
    @State private var open = false
    @State private var frame: CGRect?

    var body: some View {
        Button { open.toggle() } label: { Image(.help) }
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .help("说明")
            .accessibilityLabel("说明")
            .disabled(workspace.library == nil)
            .background { WindowFrame(\.self) { frame = $0 } }
            .panel(isPresented: $open, style: .bubble(frame.map(BubbleSource.control) ?? .unanchored)) {
                if let library = workspace.library { LibraryHelp(library: library) }
            }
            .padding(.leading, Spacing.item)
            .keepsPlace(shown: workspace.overlay == nil)
    }
}
#endif
