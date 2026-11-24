#if os(macOS)
import SwiftUI

struct UpdateRow: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var updates = services.updates
        SettingRow(title: "自动更新", icon: Image(.updates), status: Dotted("CuePad \(AppServices.version)")) {
            Toggle("自动更新", isOn: $updates.automaticallyChecks).labelsHidden().toggleStyle(.switch).disabled(!updates.isAvailable)
        }
    }
}
#endif
