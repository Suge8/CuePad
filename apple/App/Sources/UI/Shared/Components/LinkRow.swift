import SwiftUI

/// 点了进一页或打开一处的一行（书架末尾的归档、回收站、设置，Cue 面板的定时、技能与规则，灵感"更多"里的几项，技能与规则的一份）：
/// 图标一列（定宽，字都从同一条竖线起）、名字、行尾的值与记号点、箭头。只是行的内容：外面套 `Button` 或 `NavigationLink` 再挂 `.buttonStyle(.row)`，
/// 底、按下与悬停归 `RowStyle`。高 `RowMetrics.height`（Mac 32、手机 44），字离行框 `Spacing.inset`；名字放不下折两行，值先截断。
/// 行尾要常驻一个控件（开关）时给 `trailing`，箭头照常（点行进页、点开关只改开关）。读屏合成一句"名字，值"。
struct LinkRow<Leading: View, Trailing: View>: View {
    let title: Text
    var value: Text?
    /// 行尾的记号点（同步到不了 Mac、有该整理的）：这件事的状态色，nil 不画。
    var alert: Color?
    var chevron = true
    @ViewBuilder var icon: Leading
    @ViewBuilder var trailing: Trailing
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .body) private var iconColumn = Chrome.icon

    var body: some View {
        HStack(spacing: Spacing.group) {
            icon.foregroundStyle(palette.ink2).frame(width: iconColumn).accessibilityHidden(true)
            title.foregroundStyle(palette.ink).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Spacing.item) {
                if let alert { StatusDot(color: alert) }
                if let value { value.foregroundStyle(palette.ink3).monospacedDigit().lineLimit(1) }
                trailing
                if chevron { Chevron(.forward).foregroundStyle(palette.ink3) }
            }
            .fixedSize()
        }
        .font(Typography.body)
        .padding(.horizontal, Spacing.inset)
        .frame(maxWidth: .infinity, minHeight: RowMetrics.height)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

extension LinkRow where Trailing == EmptyView {
    init(title: Text, value: Text? = nil, alert: Color? = nil, chevron: Bool = true, @ViewBuilder icon: () -> Leading) {
        self.init(title: title, value: value, alert: alert, chevron: chevron, icon: icon) { EmptyView() }
    }
}
