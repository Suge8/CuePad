import SwiftUI

/// 一页里换看哪一段、几样里选一样的分段：全 App 只有这一种（窄屏侧栏的项目｜进展、技能与规则的规则｜技能、搜索的灵感与任务｜会话、
/// 同名技能的几份、定时的重复）。各段可以不带图标（只写字），整组照样要么全带字、要么全只画图标。
/// 选中态同全 App 一套（docs/ui.md「选中」）：中性淡底（`selection`）、墨字，其余次一档的墨，字一律半粗——选中不换字重，段宽不跟着跳；不用靛青。
/// 形状只有一种：每段等宽（按最宽那一段）、同高的胶囊，整组要么全带字、要么全只画图标（`titles: false`，字给悬停与读屏），不在一排里一扁一圆。
/// 放不下带字的时，调用处退成全只画图标（`ViewThatFits`），不截半个词。
/// 放在哪见 docs/layout.md「栏头与页顶」；底由调用处给：栏头、页顶的玻璃，纸与面板上是淡底的槽（`paneSlot`）。
/// 选中块只有一块，换段时从上一段滑到这一段（不回弹的弹簧 `Motion.nudge`，中途再点从当前位置折回）；减弱动态效果时选中块直接到位，字色照样淡。
/// 点着的那一段再点不动。
struct PaneSegment<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: Text
        let icon: Icon?

        init(value: Value, title: LocalizedStringResource, icon: Icon? = nil) {
            self.init(value: value, title: Text(title), icon: icon)
        }

        /// 段名是用户或库里的名字（同名技能所在的范围）：原样显示。
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
                        if titles { item.title.font(PaneMetrics.font).lineLimit(1) }
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
    static let font = Typography.toolbarLabel
    /// 只画图标时一颗的宽：同一排控件里选中块那么高（控件高减去两边的 `inset`），成正方。
    static let square = ControlSize.regular.height - inset * 2
    #if os(macOS)
    static let iconFont = Glyph.small
    static let iconGap: CGFloat = 5
    static let padding: CGFloat = 12
    static let minWidth: CGFloat = 64
    #else
    static let iconFont = Typography.toolbarLabel
    static let iconGap: CGFloat = 6
    static let padding: CGFloat = 12
    static let minWidth: CGFloat = 76
    #endif
}

/// 搜索的两个范围：灵感与任务、会话（一个搜索词两边共用，换范围不清空）。Mac 在 ⌘K 面板搜索框那一行的右边，手机是结果最上面那排胶囊的头一块。
enum SearchScope {
    case cards, sessions
}

struct SearchScopePanes: View {
    @Binding var scope: SearchScope

    var body: some View {
        PaneSegment(items: [.init(value: .cards, title: "灵感与任务", icon: .idea), .init(value: .sessions, title: "会话", icon: .session)],
                    selection: scope) { scope = $0 }
            .fixedSize()
            .paneSlot()
    }
}

extension View {
    /// 纸与面板上的分段底下那道槽（玻璃不叠玻璃，纸上没有玻璃托着）：淡底胶囊，比选中块大一圈（`PaneMetrics.inset`）。
    /// 给了 `size` 就与同一排那一档控件同高（旁边是那一档的按钮时）。
    func paneSlot(_ size: ControlSize? = nil) -> some View { modifier(PaneSlot(size: size)) }
}

private struct PaneSlot: ViewModifier {
    let size: ControlSize?
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .frame(height: size.map { $0.height - PaneMetrics.inset * 2 })
            .padding(PaneMetrics.inset)
            .background(palette.fill, in: .capsule)
    }
}
