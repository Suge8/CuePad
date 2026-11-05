import SwiftUI

/// 点了进一页或打开一处的一行（书架末尾的归档、回收站、设置，Cue 面板的定时、技能与规则、在哪台 Mac，灵感"更多"里的几项，技能与规则的一份）：
/// 图标一列（定宽，字都从同一条竖线起）、名字、行尾的值与记号点、箭头。高 `RowMetrics.height`（Mac 32、手机 44），字离行框 `Spacing.inset`；名字放不下折两行，值先截断。
/// 读屏把图标、名字、记号点与值合成一句"名字，值"。
/// 两种用法：
/// - 只有字：它只是行的内容，外面套 `Button` 或 `NavigationLink` 再挂 `.buttonStyle(.row)`，底、按下与悬停归 `RowStyle`；
/// - 行尾常驻一个可操作的控件（开关，`trailing`）：给 `open`，不套 `Button`——`Button` 把标签里的一切并成一项，开关在读屏里成了标签里的字、拨不了。
///   这时行自己铺一颗整行的 `RowStyle` 钮在底下（按下、悬停照旧），字那一段不接点按、读屏是一项按钮，控件排在值与箭头之间（箭头仍在各行同一列），点它只改它、读屏单独一项。
struct LinkRow<Leading: View, Trailing: View>: View {
    let title: Text
    var value: Text?
    /// 行尾的记号点（同步到不了 Mac、有该整理的）：这件事的状态色，nil 不画。
    var alert: Color?
    var chevron = true
    /// 行尾带控件时点行做什么（头注释）；只有字的行由外面的按钮管，nil。
    var open: (() -> Void)?
    @ViewBuilder var icon: Leading
    @ViewBuilder var trailing: Trailing
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .body) private var iconColumn = Chrome.icon

    var body: some View {
        if let open {
            content
                .background { Button(action: open) { Color.clear }.buttonStyle(.row).readerHidden(true) }
                .accessibilityElement(children: .contain)
        } else {
            content.contentShape(.rect)
        }
    }

    private var content: some View {
        HStack(spacing: Spacing.item) {
            HStack(spacing: Spacing.group) {
                icon.foregroundStyle(palette.ink2).frame(width: iconColumn).readerHidden(true)
                title.foregroundStyle(palette.ink).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: Spacing.item) {
                    if let alert { StatusDot(color: alert) }
                    if let value { value.foregroundStyle(palette.ink3).monospacedDigit().lineLimit(1) }
                }
                .fixedSize()
            }
            .accessibilityElement(children: .combine)
            .modifier(OpensRow(open: open))
            trailing.fixedSize()
            if chevron { Chevron(.forward).foregroundStyle(palette.ink3).allowsHitTesting(open == nil) }
        }
        .font(Typography.body)
        .padding(.horizontal, Spacing.inset)
        .frame(maxWidth: .infinity, minHeight: RowMetrics.height)
    }
}

/// 行尾带控件时字那一段：点按穿到底下那颗整行的钮，读屏是一项按钮。
private struct OpensRow: ViewModifier {
    let open: (() -> Void)?

    func body(content: Content) -> some View {
        if let open {
            content.allowsHitTesting(false).accessibilityAddTraits(.isButton).accessibilityAction { open() }
        } else {
            content
        }
    }
}

extension LinkRow where Trailing == EmptyView {
    init(title: Text, value: Text? = nil, alert: Color? = nil, chevron: Bool = true, @ViewBuilder icon: () -> Leading) {
        self.init(title: title, value: value, alert: alert, chevron: chevron, icon: icon) { EmptyView() }
    }
}
