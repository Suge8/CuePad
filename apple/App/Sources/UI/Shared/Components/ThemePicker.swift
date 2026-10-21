import SwiftUI

/// 外观：三项分段，选中哪个一眼看得到，不用点开菜单；两端的设置同一个。
struct ThemePicker: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var settings = services.settings
        Picker("外观", selection: $settings.theme) {
            Text("跟随系统").tag(AppSettings.Theme.system)
            Text("浅色").tag(AppSettings.Theme.light)
            Text("深色").tag(AppSettings.Theme.dark)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }
}
