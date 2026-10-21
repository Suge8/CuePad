#if os(macOS)
import SwiftUI

/// Mac 的归档页：共用的 `ArchiveList`（右键取回或删除，点开是编辑页），一直滚到工具栏后面。顶上不写页名（侧栏底下的归档钮已经说了在哪），
/// 没有页上的操作，"⋯"置灰。
struct ArchivePage: View {
    var body: some View {
        // 与回收站的纸同一条左右边线：行底与空态的纸都铺到这两条线
        ArchiveList().padding(.horizontal, Spacing.page)
            .safeAreaPadding(.top, Bars.contentGap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif
