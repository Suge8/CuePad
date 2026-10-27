import SwiftUI

/// 一页里换看哪一段的分段：全 App 只有这一种（进展页的看板｜会话、技能与规则的规则｜技能、搜索的灵感与任务｜会话）。
/// 每段图标加字，选中的靛青字、浅底，其余次一档的墨；进展页那组只画图标（`titles: false`，字给悬停与读屏）：手机那块玻璃里还要放范围与额度，
/// Mac 那组在待办列头上方，加字就挤掉列头。放在哪见 docs/layout.md：手机在页顶中间，Mac 在工具栏中间；底由调用处给（工具栏、页顶的玻璃，搜索范围自带淡底的槽）。
/// 换段的动画在这里定一份：不回弹的弹簧，减弱动态效果时只交叉淡入淡出；点着的那一段再点不动。
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
        HStack(spacing: 0) {
            ForEach(items, id: \.value) { item in
                let on = selection == item.value
                Button {
                    guard !on else { return }
                    withAnimation(Motion.fading(Motion.nudge, reduceMotion: reduceMotion)) { select(item.value) }
                } label: {
                    HStack(spacing: PaneMetrics.iconGap) {
                        Image(item.icon).font(PaneMetrics.iconFont)
                        if titles { Text(item.title).font(PaneMetrics.font).lineLimit(1) }
                    }
                    .padding(.horizontal, titles ? PaneMetrics.padding : 0)
                    .frame(minWidth: titles ? PaneMetrics.minWidth : PaneMetrics.square, maxHeight: .infinity)
                    .foregroundStyle(on ? palette.signature : palette.ink2)
                    .background(on ? palette.selection : .clear, in: .capsule)
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

enum PaneMetrics {
    /// 选中块与外沿（玻璃、槽）之间：槽比选中块大一圈。
    static let inset: CGFloat = 3
    #if os(macOS)
    static let font = Typography.toolbarLabel
    static let iconFont = Font.system(size: 12, weight: .semibold)
    static let iconGap: CGFloat = 5
    static let padding: CGFloat = 12
    static let minWidth: CGFloat = 64
    /// 只画图标时一颗的宽（同工具栏控件里的选中块那么高，成正方）。
    static let square: CGFloat = Spacing.toolbarControl - inset * 2
    #else
    static let font = Font.subheadline.weight(.semibold)
    static let iconFont = Font.subheadline.weight(.semibold)
    static let iconGap: CGFloat = 6
    static let padding: CGFloat = 14
    static let minWidth: CGFloat = 76
    static let square: CGFloat = 38
    #endif
}

/// 进展页的两段：看板｜会话，看哪一段只有 `Workspace.progressPane` 一份。手机与 iPad 在顶上那块玻璃里（`ProgressHeader`），Mac 在工具栏左上（`PanesSlot`）。
struct ProgressPanes: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        PaneSegment(items: [.init(value: .board, title: "看板", icon: .task), .init(value: .sessions, title: "会话", icon: .session)],
                    selection: workspace.progressPane, titles: false) { workspace.progressPane = $0 }
    }
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
