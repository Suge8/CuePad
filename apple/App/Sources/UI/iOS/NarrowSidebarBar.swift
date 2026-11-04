#if os(iOS)
import CueStore
import SwiftUI

/// 窄屏侧栏顶上那一排（侧栏只有这一排，项目、进展两段不再自己画页顶，`HeaderHost.sidebar`）：正中是项目｜进展，两侧各两颗只画图标的圆钮、贴页边——
/// 左边搜索与这一段的低频操作（项目段新建项目，进展段项目范围），右边额度与回 Cue 的头像。换段时只有选中块滑过去、左边第二颗换成这一段的那一颗，
/// 其余不动。圆钮的名字在读屏与悬停提示里。
/// 项目｜进展放不下带字的（英文、iPad 窄窗口、大字）时整组只画图标，不截字（`PaneSegment`）。
/// 额度明细从额度钮原地长出（`GrowPanel` 贴右）：玻璃从钮往左往下长到左页边，钮与 Cue 头像不挪；长开时左边两颗与项目｜进展让开。
/// 提示横幅盖在这一排上（从左页边到 Cue 头像前，`NoticeBanner`）时左边、正中与额度钮让开，Cue 头像留着。
struct NarrowSidebarBar: View {
    @Environment(Workspace.self) private var workspace
    @State private var quotaOpen = DebugHooks.preset.quotaOpen

    var body: some View {
        let givesWay = workspace.notice != nil
        SidebarRow(open: quotaOpen) {
            HStack(spacing: SidebarRow.gap) {
                circle("搜索", icon: .search) { workspace.openSearch() }
                switch workspace.navigationPane {
                case .projects: circle("新建项目", icon: .newProject) { workspace.projectForm = .init() }
                case .progress: ScopeButton()
                }
            }
            .modifier(Circles())
            .modifier(GiveWay(hidden: givesWay || quotaOpen))
            ViewThatFits(in: .horizontal) {
                panes(titles: true)
                panes(titles: false)
            }
            .dynamicTypeSize(...FloatingHeaderLayout.largestType)
            .modifier(GiveWay(hidden: givesWay || quotaOpen))
            QuotaButton(open: $quotaOpen)
            cue.modifier(Circles())
        }
        .padding(.horizontal, FloatingHeaderLayout.margin)
        .environment(\.headerGivesWay, givesWay)
        .animation(NoticeBanner.giveWay(workspace.notice), value: givesWay)
    }

    private func circle(_ title: LocalizedStringResource, icon: Icon, action: @escaping () -> Void) -> some View {
        Button(title, icon: icon, action: action).help(Text(title))
    }

    private func panes(titles: Bool) -> some View {
        PaneSegment(
            items: [.init(value: NavigationPane.projects, title: "项目", icon: .projects), .init(value: .progress, title: "进展", icon: .task)],
            selection: workspace.navigationPane, titles: titles, select: workspace.selectPane)
            .frame(height: FloatingHeaderLayout.height - PaneMetrics.inset * 2)
            .padding(PaneMetrics.inset)
            .glass(in: .capsule, interactive: true)
            .fixedSize()
    }

    private var cue: some View {
        Button { workspace.select(.cue) } label: {
            CueAvatar(workspace.cue.beat, size: .row)
                .relaySpot(cue: .entry)
                .frame(width: FloatingHeaderLayout.height, height: FloatingHeaderLayout.height)
        }
        .accessibilityLabel(workspace.cue.name)
        .accessibilityIdentifier("narrow-cue")
    }
}

/// 项目范围（`Workspace.projectScope`）的圆钮：看全部时是筛选图标，选了是那个项目的图标；点开是项目菜单（同 `ProjectScope` 那一份）。
private struct ScopeButton: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        let current = workspace.catalog?.project(workspace.scopedProject)
        Menu {
            Picker("项目范围", selection: $workspace.projectScope) {
                Label("全部项目", icon: .all).tag(UUID?.none)
                ForEach(workspace.catalog?.projects ?? []) { project in
                    Label { Text(project.shownName) } icon: { ProjectGlyph(project: project) }.tag(Optional(project.id))
                }
            }
        } label: {
            Group {
                if let current { ProjectGlyph(project: current, size: Self.glyph) } else { Image(.filter) }
            }
        }
        .menuStyle(.button)
        .help(Text("项目范围"))
        .accessibilityLabel(Text("项目范围"))
        .accessibilityValue(Text(current?.shownName ?? String(localized: "全部项目")))
        .sensoryFeedback(.selection, trigger: current?.id)
    }

    private static let glyph: CGFloat = 15
}

/// 额度钮：一颗环，是余量最紧的那个账号（还没有额度记录时写"额度"二字）；点它从这颗钮长出明细（`QuotaDetail`）。
/// 读屏念全部账号的读数（同 `QuotaRings`）。
private struct QuotaButton: View {
    @Binding var open: Bool
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let quotas = services.accountQuotas.items
        GrowPanel(open: $open, radius: FloatingHeaderLayout.height / 2, edge: .trailing) {
            Button { $open.grow(reduceMotion: reduceMotion) } label: {
                Moments(next: quotas.nextReset(after:)) { now in ring(quotas, at: now) }
                    .frame(width: FloatingHeaderLayout.height, height: FloatingHeaderLayout.height)
                    .contentShape(.circle)
            }
            .buttonStyle(PressStyle())
            .help(Text("额度"))
            .accessibilityExpanded(open)
            .accessibilityHint(open ? "收起" : quotas.isEmpty ? "看怎么才会有额度" : "看每个窗口还剩多少、多久后重置")
        } panel: {
            QuotaDetail().padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 18)
        }
        .refreshesQuota()
    }

    private func ring(_ quotas: [AccountQuota], at now: Date) -> some View {
        let rings = quotas.compactMap { quota in quota.binding(at: now).map { (provider: quota.provider, window: QuotaMeter.Window($0, at: now)) } }
        return Group {
            if let tightest = rings.min(by: { $0.window.left < $1.window.left }) {
                ModelBadge(mark: PiProvider(id: tightest.provider).mark, binding: tightest.window)
            } else {
                Text("额度").font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink3).fixedSize()
            }
        }
        .foregroundStyle(palette.ink2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("额度")
        .accessibilityValue(Dotted(rings.map { String(localized: "\(PiProvider(id: $0.provider).account) \($0.window.name)剩 \($0.window.percent)") }).spoken)
    }
}

/// 两侧的圆钮：只画图标、玻璃圆钮，字号封顶同页顶那一排。额度钮的玻璃是它长出的那块（`GrowPanel`），不经这里。
private struct Circles: ViewModifier {
    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .dynamicTypeSize(...FloatingHeaderLayout.largestType)
    }
}

/// 让开（提示横幅盖上来、额度明细长开）：淡到透明、不可点、读屏跳过（同页顶那一排的让开）。
private struct GiveWay: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content.opacity(hidden ? 0 : 1).allowsHitTesting(!hidden).readerHidden(hidden)
    }
}

/// 这一排的排法，子视图依次是左边那组、正中的分段、额度、Cue 头像：
/// - 左边那组贴左页边，Cue 头像贴右页边，额度在 Cue 头像左边隔 `gap`；两侧一样宽（两颗圆钮加一道缝），分段在两侧之间、对着整排的正中。
/// - 额度给的是从左页边到它右沿那一段（`GrowPanel` 贴右）：收着时只占右边一颗钮，长开时往左铺满那一段、往下长，这一排的高是它长到的高。
/// 按给的宽一次排定，不读几何。
private struct SidebarRow: Layout {
    let open: Bool
    static let gap: CGFloat = 6

    private var row: CGFloat { FloatingHeaderLayout.height }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +) + 3 * Self.gap
        guard open else { return CGSize(width: width, height: row) }
        let quota = subviews[2].sizeThatFits(ProposedViewSize(width: reach(width, subviews), height: proposal.height))
        return CGSize(width: width, height: max(row, quota.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cue = subviews[3].sizeThatFits(.unspecified).width
        let side = max(subviews[0].sizeThatFits(.unspecified).width, row + Self.gap + cue)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                          proposal: ProposedViewSize(width: max(bounds.width - 2 * (side + Self.gap), 0), height: row))
        let reach = reach(bounds.width, subviews)
        subviews[2].place(at: CGPoint(x: bounds.minX + reach, y: bounds.minY), anchor: .topTrailing,
                          proposal: ProposedViewSize(width: reach, height: open ? proposal.height : row))
        subviews[3].place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing, proposal: .unspecified)
    }

    /// 额度那一段的宽：从左页边到 Cue 头像左边那道缝。
    private func reach(_ width: CGFloat, _ subviews: Subviews) -> CGFloat {
        max(width - subviews[3].sizeThatFits(.unspecified).width - Self.gap, 0)
    }
}
#endif
