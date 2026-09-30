#if os(macOS)
import SwiftUI

/// 设置窗口底部的更新行：自动检查开关与立即检查。
struct UpdateBar: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var updates = services.updates
        HStack {
            Toggle("自动检查更新", isOn: $updates.automaticallyChecks).disabled(!updates.isAvailable)
            Spacer()
            Button("检查更新…") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }
}
#endif
