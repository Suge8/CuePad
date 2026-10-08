#if os(macOS)
import SwiftUI

/// Mac 的归档页：大标题下面是共用的 `ArchiveList`（右键取回或删除，点开是纸页）。
struct ArchivePage: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("归档").font(.system(size: 28, weight: .bold)).foregroundStyle(palette.ink)
                .padding(.horizontal, 32).padding(.top, 20)
            ArchiveList().frame(maxWidth: 760)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif
