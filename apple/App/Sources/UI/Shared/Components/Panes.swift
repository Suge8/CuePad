import SwiftUI

struct PaneSegment<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: Text
        let icon: Icon?
        var badge = 0

        init(value: Value, title: LocalizedStringResource, icon: Icon? = nil, badge: Int = 0) {
            self.init(value: value, title: Text(title), icon: icon)
            self.badge = badge
        }

        init(value: Value, verbatim title: String, icon: Icon? = nil) {
            self.init(value: value, title: Text(verbatim: title), icon: icon)
        }

        private init(value: Value, title: Text, icon: Icon?) {
            self.value = value
            self.title = title
            self.icon = icon
        }
    }

    let items: [Item]
    let selection: Value
    var titles = true
    let select: (Value) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette

    var body: some View {
        EqualSegments(selected: items.firstIndex { $0.value == selection } ?? 0) {
            Capsule().fill(palette.selection).allowsHitTesting(false)
            ForEach(items, id: \.value) { item in
                let on = selection == item.value
                Button {
                    guard !on else { return }
                    withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { select(item.value) }
                } label: {
                    HStack(spacing: PaneMetrics.iconGap) {
                        if let icon = item.icon { Image(icon).font(PaneMetrics.iconFont) }
                        if titles {
                            HStack(alignment: .top, spacing: Spacing.hair) {
                                item.title.font(PaneMetrics.font).lineLimit(1)
                                if item.badge > 0 {
                                    Text(item.badge, format: .number).font(Typography.caption2.weight(.semibold)).monospacedDigit()
                                        .foregroundStyle(palette.ink3).fixedSize().readerHidden(true)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, titles ? PaneMetrics.padding : 0)
                    .frame(minWidth: titles ? PaneMetrics.minWidth : PaneMetrics.square, maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(on ? palette.ink : palette.ink2)
                    .animation(Motion.fade, value: on)
                    .contentShape(.capsule)
                }
                .buttonStyle(PressStyle())
                .help(item.title)
                .accessibilityLabel(item.title)
                .accessibilityValue(item.badge > 0 ? Text(item.badge, format: .number) : Text(verbatim: ""))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

private struct EqualSegments: Layout {
    let selected: Int

    private func width(_ subviews: Subviews) -> CGFloat {
        subviews.dropFirst().map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = proposal.height ?? subviews.dropFirst().map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: width(subviews) * CGFloat(subviews.count - 1), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = width(subviews)
        let size = ProposedViewSize(width: w, height: bounds.height)
        subviews[0].place(at: CGPoint(x: bounds.minX + w * CGFloat(selected), y: bounds.minY), anchor: .topLeading, proposal: size)
        for (index, subview) in subviews.dropFirst().enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + w * CGFloat(index), y: bounds.minY), anchor: .topLeading, proposal: size)
        }
    }
}

enum PaneMetrics {
    /// 选中块离槽边：贴着槽画一道细边，比任何一档间距都紧（同系统分段控件）。
    static let inset: CGFloat = 3
    static let font = Typography.toolbarLabel
    static let square = ControlSize.regular.height - inset * 2
    #if os(macOS)
    static let iconFont = Glyph.small
    static let iconGap = Spacing.glyph
    static let padding = Spacing.group
    static let minWidth: CGFloat = 64
    #else
    static let iconFont = Typography.toolbarLabel
    static let iconGap = Spacing.glyph
    static let padding = Spacing.group
    static let minWidth: CGFloat = 76
    #endif
}

extension View {
    func paneSlot(_ size: ControlSize) -> some View { modifier(PaneSlot(size: size)) }
}

private struct PaneSlot: ViewModifier {
    let size: ControlSize
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: size.height - PaneMetrics.inset * 2)
            .padding(PaneMetrics.inset)
            .background(palette.fill, in: .capsule)
    }
}
