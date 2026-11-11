#if os(macOS)
import SwiftUI

/// 立即检查在菜单"CuePad › 检查更新…"，不在这一行。
struct UpdateRow: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var updates = services.updates
        SettingRow(title: "自动检查更新", icon: Image(.updates), status: Dotted("CuePad \(AppServices.version)", updates.waitingNote)) {
            Toggle("自动检查更新", isOn: $updates.automaticallyChecks).labelsHidden().toggleStyle(.switch).disabled(!updates.isAvailable)
        } fix: {
            if updates.waitingNote != nil {
                Button("现在就装") { updates.installNow() }.settingFix()
            }
        }
    }
}
#endif
