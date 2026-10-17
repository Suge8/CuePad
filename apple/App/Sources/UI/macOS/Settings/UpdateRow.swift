#if os(macOS)
import SwiftUI

/// 设置里"自动检查更新"那一行，状态写当前版本；立即检查在菜单"CuePad › 检查更新…"（Mac 上它的标准位置）。
/// 更新等后台会话做完再装时（`UpdateService`），状态接着写等几个，后面是"现在就装"。
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
