#if os(macOS)
import SwiftUI

/// 状态换一句、图标与转圈互换都是旧的先淡完、新的再淡入（`handOff`）：同时交叉淡时长短两句叠成一团，行高一变还把淡出中的那句裁掉半截。
struct SettingRow<Control: View, Fix: View>: View {
    let title: LocalizedStringResource
    let icon: Image
    var tone = StatusTone.calm
    var busy = false
    var status: Dotted?
    var help: LocalizedStringResource?
    @ViewBuilder var control: Control
    @ViewBuilder var fix: Fix
    @Environment(\.palette) private var palette

    private static var iconWidth: CGFloat { 20 }

    var body: some View {
        LabeledContent {
            control
        } label: {
            Label {
                Text(title)
                if let status {
                    ZStack(alignment: .leading) {
                        HStack(spacing: Spacing.item) {
                            Text(status).foregroundStyle(palette.color(tone, muted: true))
                            fix
                        }
                        .id(status)
                        .transition(.handOff)
                    }
                    .font(Typography.meta)
                }
            } icon: {
                ZStack {
                    if busy {
                        Spinner(.small).transition(.handOff)
                    } else {
                        icon.foregroundStyle(palette.color(tone))
                            .contentTransition(.symbolEffect(.replace))
                            .transition(.handOff)
                    }
                }
                // 各图标宽窄不一：定宽居中，名称才落在同一条竖线上
                .frame(width: Self.iconWidth)
            }
        }
        .animation(Motion.fade, value: tone)
        .animation(Motion.fade, value: busy)
        .help(help.map { Text($0) } ?? Text(verbatim: ""))
        // 读屏把这一行当一组、组名是这一行的名称：状态后的"修复""查看"与右边的控件都读得出属于哪一行
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension SettingRow where Fix == EmptyView {
    init(
        title: LocalizedStringResource, icon: Image, tone: StatusTone = .calm, busy: Bool = false, status: Dotted? = nil,
        help: LocalizedStringResource? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.init(title: title, icon: icon, tone: tone, busy: busy, status: status, help: help, control: control) { EmptyView() }
    }
}

extension View {
    func settingFix() -> some View { modifier(SettingFixStyle()) }

}

private struct SettingFixStyle: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.buttonStyle(.plain).font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink).underline().pointerStyle(.link)
    }
}

extension View {
    /// 设置里弹出框的底：弹出框常常伸出设置窗口、压在别的应用的字上，所以同 `GlassInk.solid`，系统玻璃里垫九成实的桌面色，背后的字透不过来。
    func settingPopoverBackground() -> some View { modifier(SettingPopoverBackground()) }
}

private struct SettingPopoverBackground: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.presentationBackground(palette.solidGlass)
    }
}

struct SettingPopover<Content: View>: View {
    let title: LocalizedStringResource
    var width: CGFloat = 360
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text(title).font(Typography.bodyStrong).foregroundStyle(palette.ink)
            content
        }
        .font(Typography.secondary)
        .lineLimit(nil)
        .padding(Spacing.block)
        .frame(width: width, alignment: .leading)
        .settingPopoverBackground()
    }
}
#endif
