#if os(macOS)
import SwiftUI

/// 设置里"自动检查更新"那一行，状态写当前版本；立即检查在菜单"CuePad › 检查更新…"（Mac 上它的标准位置）。
struct UpdateRow: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var updates = services.updates
        SettingRow(title: "自动检查更新", symbol: "arrow.down.circle", status: "CuePad \(AppServices.version)") {
            Toggle("自动检查更新", isOn: $updates.automaticallyChecks).labelsHidden().toggleStyle(.switch).disabled(!updates.isAvailable)
        }
    }
}
#endif
