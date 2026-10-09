#if os(macOS)
import SwiftUI

/// 设置里"更新"一节的一行：自动检查开关与立即检查。
struct UpdateRow: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var updates = services.updates
        HStack {
            Toggle("自动检查更新", isOn: $updates.automaticallyChecks).disabled(!updates.isAvailable)
            Spacer()
            Button("检查更新…") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
        }
    }
}
#endif
