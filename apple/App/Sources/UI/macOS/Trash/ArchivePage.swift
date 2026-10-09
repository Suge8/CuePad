#if os(macOS)
import SwiftUI

/// Mac 的归档页：大标题下面是共用的 `ArchiveList`（右键取回或删除，点开是纸页）。
struct ArchivePage: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("归档").font(Typography.pageTitle).foregroundStyle(palette.ink)
                .padding(.horizontal, Spacing.page).padding(.top, ToolbarEdge.fade + 6)
            ArchiveList().frame(maxWidth: 760)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) { ToolbarEdge() }
    }
}
#endif
