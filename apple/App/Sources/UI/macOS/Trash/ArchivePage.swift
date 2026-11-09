#if os(macOS)
import SwiftUI

struct ArchivePage: View {
    var body: some View {
        ArchiveList().padding(.horizontal, Spacing.page)
            .safeAreaPadding(.top, Bars.contentGap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif
