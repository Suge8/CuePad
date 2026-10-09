#if os(macOS)
import SwiftUI

/// Mac 的归档页：大标题下面是共用的 `ArchiveList`（右键取回或删除，点开是纸页）。
struct ArchivePage: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("归档").font(Typography.pageTitle).foregroundStyle(palette.ink)
                .padding(.horizontal, Spacing.page).padding(.top, Spacing.pageTop)
            // 与标题、回收站的纸同一条左右边线：行底与空态的纸都铺到这两条线
            ArchiveList().padding(.horizontal, Spacing.page)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif
