import SwiftUI

/// 一页里换看哪一段的分段：全 App 只有这一种（窄屏侧栏的项目｜进展、技能与规则的规则｜技能、搜索的灵感与任务｜会话）。
/// 选中态同全 App 一套（docs/ui.md「选中」）：中性淡底（`selection`）、墨字，其余次一档的墨，字一律半粗——选中不换字重，段宽不跟着跳；不用靛青。
/// 形状只有一种：每段等宽（按最宽那一段）、同高的胶囊，整组要么全带字、要么全只画图标（`titles: false`，字给悬停与读屏），不在一排里一扁一圆。
/// 放不下带字的时，调用处退成全只画图标（`ViewThatFits`），不截半个词。
/// 放在哪见 docs/layout.md「栏头与页顶」；底由调用处给（栏头、页顶的玻璃，搜索范围自带淡底的槽）。
/// 选中块只有一块，换段时从上一段滑到这一段（不回弹的弹簧 `Motion.nudge`，中途再点从当前位置折回）；减弱动态效果时选中块直接到位，字色照样淡。
/// 点着的那一段再点不动。
struct PaneSegment<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: LocalizedStringResource
        let icon: Icon
    }

    let items: [Item]
    let selection: Value
    var titles = true
    let select: (Value) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette

    var body: some View {
        EqualSegments(selected: items.firstIndex { $0.value == selection } ?? 0) {
            Capsule().fill(palette.selection).allowsHitTesting(false).accessibilityHidden(true)
            ForEach(items, id: \.value) { item in
                let on = selection == item.value
                Button {
                    guard !on else { return }
                    withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { select(item.value) }
                } label: {
                    HStack(spacing: PaneMetrics.iconGap) {
                        Image(item.icon).font(PaneMetrics.iconFont)
                        if titles { Text(item.title).font(PaneMetrics.font).lineLimit(1) }
                    }
                    .padding(.horizontal, titles ? PaneMetrics.padding : 0)
                    .frame(minWidth: titles ? PaneMetrics.minWidth : PaneMetrics.square, maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(on ? palette.ink : palette.ink2)
                    .animation(Motion.fade, value: on)
                    .contentShape(.capsule)
                }
                .buttonStyle(PressStyle())
                .help(Text(item.title))
                .accessibilityLabel(Text(item.title))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// 分段的排法：第一个子视图是选中块，排在第 `selected` 段的位置；其余是各段，每段一样宽（最宽那一段的理想宽）、铺满给的高，按次序挨着排。
/// 选中块是同一个视图换位置，换段的动画里它从上一段滑过去。不读几何，一次排定。
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
    /// 选中块与外沿（玻璃、槽）之间：槽比选中块大一圈。
    static let inset: CGFloat = 3
    #if os(macOS)
    static let font = Typography.toolbarLabel
    static let iconFont = Glyph.small
    static let iconGap: CGFloat = 5
    static let padding: CGFloat = 12
    static let minWidth: CGFloat = 64
    /// 只画图标时一颗的宽（同工具栏控件里的选中块那么高，成正方）。
    static let square: CGFloat = ControlMetrics.height - inset * 2
    #else
    static let font = Font.subheadline.weight(.semibold)
    static let iconFont = Font.subheadline.weight(.semibold)
    static let iconGap: CGFloat = 6
    static let padding: CGFloat = 14
    static let minWidth: CGFloat = 76
    static let square: CGFloat = 38
    #endif
}

/// 搜索的两个范围：灵感与任务、会话（一个搜索词两边共用，换范围不清空）。Mac 在 ⌘K 面板搜索框那一行的右边，手机是结果最上面那排胶囊的头一块。
enum SearchScope {
    case cards, sessions
}

struct SearchScopePanes: View {
    @Binding var scope: SearchScope
    @Environment(\.palette) private var palette

    var body: some View {
        PaneSegment(items: [.init(value: .cards, title: "灵感与任务", icon: .idea), .init(value: .sessions, title: "会话", icon: .session)],
                    selection: scope) { scope = $0 }
            .fixedSize()
            .padding(PaneMetrics.inset)
            .background(palette.fill, in: .capsule)
    }
}
