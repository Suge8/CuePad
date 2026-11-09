import SwiftUI

/// 两种用法：
/// - 只有字：它只是行的内容，外面套 `Button` 或 `NavigationLink` 再挂 `.buttonStyle(.row)`，底、按下与悬停归 `RowStyle`；
/// - 行尾常驻一个可操作的控件（开关，`trailing`）：给 `open`，不套 `Button`——`Button` 把标签里的一切并成一项，开关在读屏里成了标签里的字、拨不了。
///   这时行自己铺一颗整行的 `RowStyle` 钮在底下（按下、悬停照旧），字那一段不接点按、读屏是一项按钮，控件排在值与箭头之间（箭头仍在各行同一列），点它只改它、读屏单独一项。
struct LinkRow<Leading: View, Trailing: View>: View {
    let title: Text
    var value: Text?
    var alert: Color?
    var chevron = true
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
