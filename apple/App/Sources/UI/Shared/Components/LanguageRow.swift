import SwiftUI

/// 当前语言以进程的 Bundle 为准，重开后才更新。
struct LanguageRow: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openURL) private var openURL
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconColumn = Chrome.icon
    #endif

    var body: some View {
        #if os(macOS)
        SettingRow(title: "语言", icon: Image(.language), status: Dotted(String(localized: "更改后需重新打开 CuePad"))) {
            HStack(spacing: Spacing.item) {
                Button(AppLanguage.name, action: openSettings)
                    .help("打开语言与地区设置")
                HelpButton {
                    SettingPopover(title: "语言") {
                        Text("在「语言与地区」的「应用程序」中添加或选择 CuePad，再选择语言；移除 CuePad 可恢复跟随系统")
                        Text("会话回复框的文字与批注会保留；其他未发送内容请先保存或发出")
                    }
                }
            }
        }
        #else
        Button(action: openSettings) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.block) {
                    Image(.language).frame(width: iconColumn)
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                            Text("语言")
                            Spacer()
                            if !typeSize.isAccessibilitySize {
                                Text(AppLanguage.name).foregroundStyle(palette.ink2)
                            }
                            Chevron(.forward).foregroundStyle(palette.ink3)
                        }
                        if typeSize.isAccessibilitySize {
                            Text(AppLanguage.name).foregroundStyle(palette.ink2)
                        } else {
                            consequence
                        }
                    }
                }
                if typeSize.isAccessibilitySize { consequence }
            }
            .contentShape(.rect)
        }
        .accessibilityHint("打开系统设置")
        #endif
    }

    #if os(iOS)
    private var consequence: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("重开后生效")
            Text("退出不保留草稿中的卡片和图片")
        }
        .font(Typography.meta).foregroundStyle(palette.ink2)
    }
    #endif

    private func openSettings() {
        services.settings.flush()
        openURL(AppLanguage.settings)
    }
}
