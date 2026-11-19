#if os(iOS)
import SwiftUI

struct ShelfScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ProjectShelf(paired: sizeClass == .compact)
        .refreshable { await services.syncing.syncNow() }
        .floatingHeader("项目") { NewProjectButton() }
    }
}
#endif
