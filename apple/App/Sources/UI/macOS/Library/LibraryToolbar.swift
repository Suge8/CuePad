#if os(macOS)
import SwiftUI

struct LibraryPanesSlot: View {
    var body: some View {
        LibraryPanes()
            .frame(height: PaneMetrics.square)
            .padding(PaneMetrics.inset)
            .glass(in: .capsule)
            .fixedSize()
    }
}

/// 开着文件页时看不见、位置照留，左边的分段与文件页标题不挪。
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
