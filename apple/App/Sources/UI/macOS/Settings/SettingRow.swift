#if os(macOS)
import SwiftUI

/// 设置的一行此刻怎么样：平静时图标与状态都是墨的次要色；要你处理是赭黄、出错是胭脂（图标与状态一起变，配上该状态的图形）；
/// 在等结果时图标位置是转圈。没有绿色与对勾：正常就是安静，只有要你动手的那一行抢眼。
enum SettingTone: Equatable {
    case calm, busy, attention, failure
}

/// 设置的一行，全窗口只有这一种排法（同系统设置的网络、iCloud 行）：
/// - 左边定宽的图标与名称，名称下面一行状态；状态有现成的解决办法时，紧跟一个链接（`fix`：打开系统设置、处理…、查看、复制命令）。
/// - 右边只放这一行常驻的那一个控件（开关、分段、键帽、立即同步、连接）。
/// 解释性的长句不上屏，放在悬停提示里（`help`）。
struct SettingRow<Control: View, Fix: View>: View {
    let title: String
    let symbol: String
    var tone = SettingTone.calm
    var status: Dotted?
    var help: String?
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
                    HStack(spacing: 8) {
                        Text(status).foregroundStyle(color(muted: true))
                        fix
                    }
                    .font(Typography.meta)
                }
            } icon: {
                Group {
                    if tone == .busy {
                        Spinner(.small)
                    } else {
                        Image(systemName: symbol).foregroundStyle(color(muted: false))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                // 各图标宽窄不一：定宽居中，名称才落在同一条竖线上
                .frame(width: Self.iconWidth)
            }
        }
        .animation(Motion.quick, value: tone)
        .help(help ?? "")
    }

    private func color(muted: Bool) -> Color {
        switch tone {
        case .calm, .busy: muted ? palette.ink3 : palette.ink2
        case .attention: palette.attention
        case .failure: palette.failure
        }
    }
}

extension SettingRow where Fix == EmptyView {
    init(
        title: String, symbol: String, tone: SettingTone = .calm, status: Dotted? = nil, help: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.init(title: title, symbol: symbol, tone: tone, status: status, help: help, control: control) { EmptyView() }
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
        content.buttonStyle(.plain).font(Typography.meta.weight(.medium)).foregroundStyle(palette.signature).pointerStyle(.link)
    }
}

/// 解决链接点开的说明或明细（同步要你决定、没能同步的记录、冲突、崩溃、Pi 的安装方法）：都是挂在链接上的弹出框，一种外观。
struct SettingPopover<Content: View>: View {
    let title: String
    var width: CGFloat = 360
    @ViewBuilder var content: Content
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Typography.bodyStrong).foregroundStyle(palette.ink)
            content
        }
        .font(Typography.secondary)
        .padding(16)
        .frame(width: width, alignment: .leading)
    }
}
#endif
