#if os(macOS)
import SwiftUI

struct ArchivePage: View {
    var body: some View {
        ArchiveList()
            .safeAreaPadding(.top, Bars.contentGap)
            .fades(.top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif
