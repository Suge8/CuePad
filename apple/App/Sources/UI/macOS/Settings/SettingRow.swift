#if os(macOS)
import SwiftUI

/// 设置的一行，全窗口只有这一种排法（同系统设置的网络、iCloud 行）：
/// - 左边定宽的图标与名称，名称下面一行状态；状态有现成的解决办法时，紧跟一个链接（`fix`：打开系统设置、处理…、查看、复制命令）。
/// - 图标与状态字按 `StatusTone` 一起着色（正常就是安静，没有绿色与对勾）；在等结果（`busy`）时图标位置是转圈。
///   状态换一句、图标与转圈互换都是旧的先淡完、新的再淡入（`handOff`）：同时交叉淡时长短两句叠成一团，行高一变还把淡出中的那句裁掉半截。
/// - 右边只放这一行常驻的那一个控件（开关、分段、键帽、立即同步、连接）。
/// 解释性的长句不上屏，放在悬停提示里（`help`）。
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
                    // 新旧两句叠在同一处：淡出中的那句不另占一行
                    ZStack(alignment: .leading) {
                        HStack(spacing: 8) {
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
        .animation(HandOff.quick, value: tone)
        .animation(HandOff.quick, value: busy)
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
    /// 状态后面的解决链接：靛青字、链接指针（同访达里打开链接的字）。
    func settingFix() -> some View { modifier(SettingFixStyle()) }

    /// 右边那一个控件是按钮时：`primary` 是这一窗此刻唯一该点的（靛青底），其余是安静的胶囊。
    func settingButton(primary: Bool = false) -> some View {
        buttonStyle(ControlButtonStyle(kind: primary ? .primary : .secondary, compact: true))
    }
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

/// 解决链接点开的说明或明细（同步要你决定、没能同步的记录、冲突、崩溃）：都是挂在链接上的弹出框，一种外观。
struct SettingPopover<Content: View>: View {
    let title: LocalizedStringResource
    var width: CGFloat = 360
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Typography.bodyStrong).foregroundStyle(palette.ink)
            content
        }
        .font(Typography.secondary)
        .lineLimit(nil)
        .padding(16)
        .frame(width: width, alignment: .leading)
        .settingPopoverBackground()
    }
}
#endif
