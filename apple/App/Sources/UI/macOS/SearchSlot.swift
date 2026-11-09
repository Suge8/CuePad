#if os(macOS)
import SwiftUI

struct SearchSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("搜索", icon: .search) { workspace.searching.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .help("搜索（⌘K）")
            .disabled(!workspace.isLibraryReady)
    }

    static let reserve = Spacing.item + ControlMetrics.height
}
#endif
