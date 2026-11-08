import SwiftUI

/// 外观：默认分段；辅助字号用原生内联选项，让选中值与选项保持可读。两端共用同一份设置值。
struct ThemePicker: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            picker.pickerStyle(.inline)
        } else {
            picker.labelsHidden().pickerStyle(.segmented).fixedSize()
        }
    }

    private var picker: some View {
        @Bindable var settings = services.settings
        return Picker("外观", selection: $settings.theme) {
            Text("跟随系统").tag(AppSettings.Theme.system)
            Text("浅色").tag(AppSettings.Theme.light)
            Text("深色").tag(AppSettings.Theme.dark)
        }
    }
}
