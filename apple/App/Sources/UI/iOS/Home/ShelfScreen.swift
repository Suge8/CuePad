#if os(iOS)
import SwiftUI

struct ShelfScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ProjectShelf(placesAtEnd: sizeClass == .compact) {
            if sizeClass == .compact {
                ProjectListPlace(title: "设置", icon: .settings, route: .settings, alert: services.macAlert)
            }
        }
        .refreshable { await services.syncNow() }
        .floatingHeader("项目") { NewProjectButton() }
    }
}
#endif
