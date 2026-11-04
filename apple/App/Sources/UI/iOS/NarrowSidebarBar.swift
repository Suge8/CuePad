#if os(iOS)
import SwiftUI

/// 窄屏侧栏顶上那一排（侧栏只有这一排，项目、进展两段不再自己画页顶，`HeaderHost.sidebar`）：左边项目｜进展，右边回 Cue 的头像，
/// 中间是这一段的工具——项目段一条搜索入口（`SearchEntry`）与新建项目，进展段是看板｜会话与额度环那一块（`ProgressHeader`，项目范围收在它长出的面板里）。
/// 两头先排定，中间铺在两头之间；放不下全宽的项目｜进展时它只画图标（`BarRow`，按给的宽一次排定，不读几何）。
/// 额度面板长开时那一块铺满整排、盖住两头。提示横幅盖在这一排上时左边与中间让开，Cue 头像留着（`NoticeBanner`）。
struct NarrowSidebarBar: View {
    @Environment(Workspace.self) private var workspace
    @State private var quotaOpen = DebugHooks.preset.quotaOpen
    /// 搜索入口最窄多宽：放得下放大镜与"搜索"两个字；再窄先让项目｜进展只画图标。
    @ScaledMetric(relativeTo: .body) private var searchWidth: CGFloat = 92

    var body: some View {
        // PROTOTYPE：方案 1 之上的两种摆法（`CenteredBar`）
        if let bar = BarVariant.current { CenteredBar(variant: bar) } else { row }
    }

    @ViewBuilder private var row: some View {
        let open = quotaOpen && workspace.navigationPane == .progress && NavVariant.current == .now
        let givesWay = workspace.notice != nil
        BarRow(open: open) {
            Group {
                if NavVariant.current == .two {
                    NavTriple()
                } else {
                    ViewThatFits(in: .horizontal) {
                        panes(titles: true)
                        panes(titles: false)
                    }
                }
            }
            .modifier(GiveWay(hidden: givesWay))
            cue
            tools.modifier(GiveWay(hidden: givesWay && !open))
        }
        .padding(.horizontal, FloatingHeaderLayout.margin)
        .environment(\.headerGivesWay, givesWay)
        .animation(NoticeBanner.giveWay(workspace.notice), value: givesWay)
    }

    private func panes(titles: Bool) -> some View {
        PaneSegment(
            items: [.init(value: NavigationPane.projects, title: "项目", icon: .projects), .init(value: .progress, title: "进展", icon: .task)],
            selection: workspace.navigationPane, titles: titles, select: workspace.selectPane)
            .fixedSize()
            .frame(height: FloatingHeaderLayout.height - PaneMetrics.inset * 2)
            .padding(PaneMetrics.inset)
            .glass(in: .capsule, interactive: true)
            .dynamicTypeSize(...FloatingHeaderLayout.largestType)
    }

    private var cue: some View {
        Button { workspace.select(.cue) } label: {
            CueAvatar(workspace.cue.beat, size: .row)
                .relaySpot(cue: .entry)
                .frame(width: FloatingHeaderLayout.height, height: FloatingHeaderLayout.height)
        }
        .buttonStyle(ControlButtonStyle(kind: .circular))
        .accessibilityLabel(workspace.cue.name)
        .accessibilityIdentifier("narrow-cue")
    }

    @ViewBuilder private var tools: some View {
        switch workspace.navigationPane {
        case .projects:
            HStack(spacing: BarRow.gap) {
                SearchEntry().frame(minWidth: searchWidth)
                NewProjectButton()
                    .labelStyle(.iconOnly)
                    .buttonStyle(ControlButtonStyle(kind: .circular))
                    .dynamicTypeSize(...FloatingHeaderLayout.largestType)
            }
        case .progress:
            // 收着时只占自己的宽，在两头之间居中；长开时铺满给的整排
            if NavVariant.current == .now {
                // 收着时只占自己的宽，在两头之间居中；长开时铺满给的整排
                ProgressHeader(open: $quotaOpen, scopeInPanel: true).fixedSize(horizontal: !quotaOpen, vertical: false)
            } else {
                // PROTOTYPE one、two：中间只放项目范围，额度去了项目段末尾那一组（`ShelfQuota`）
                ScopePiece()
            }
        }
    }
}

/// 提示横幅盖在这一排上：淡到透明、不可点、读屏跳过（同页顶那一排的让开）。
private struct GiveWay: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content.opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).readerHidden(hidden)
    }
}

/// 一排三块：左、右排在两头，中间铺在两头之间、各隔 `gap`。左边先让出中间最窄要的宽，再按剩下的给（`ViewThatFits` 在全宽与只画图标之间挑）；
/// `open` 时中间铺满整排、画在两头上面，高是它长到的高（面板往下长）。子视图依次是左、右、中。
private struct BarRow: Layout {
    let open: Bool
    /// 比页顶那一排的 8 窄一点：iPhone 17（402 宽）上项目｜进展、看板｜会话与两颗额度环、Cue 头像正好排下带字的项目｜进展。
    static let gap: CGFloat = 6

    private struct Frames {
        var size: CGSize
        var leading: ProposedViewSize
        var middle: CGRect
    }

    private func frames(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Frames {
        let row = FloatingHeaderLayout.height
        let trailing = subviews[1].sizeThatFits(.unspecified).width
        let width = proposal.width
            ?? subviews[0].sizeThatFits(.unspecified).width + trailing + subviews[2].sizeThatFits(.unspecified).width + 2 * Self.gap
        if open {
            let middle = subviews[2].sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
            return Frames(size: CGSize(width: width, height: max(row, middle.height)), leading: ProposedViewSize(width: width, height: row),
                          middle: CGRect(x: 0, y: 0, width: width, height: proposal.height ?? middle.height))
        }
        let narrowest = subviews[2].sizeThatFits(ProposedViewSize(width: 0, height: row)).width
        let leading = ProposedViewSize(width: max(width - trailing - narrowest - 2 * Self.gap, 0), height: row)
        let lead = subviews[0].sizeThatFits(leading).width
        let x = lead + Self.gap
        return Frames(size: CGSize(width: width, height: row), leading: leading,
                      middle: CGRect(x: x, y: 0, width: max(width - x - trailing - Self.gap, 0), height: row))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frames(proposal, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let f = frames(ProposedViewSize(width: bounds.width, height: proposal.height), subviews)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: f.leading)
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing, proposal: .unspecified)
        subviews[2].place(
            at: CGPoint(x: bounds.minX + f.middle.midX, y: bounds.minY), anchor: .top,
            proposal: ProposedViewSize(width: f.middle.width, height: f.middle.height))
    }
}
#endif
