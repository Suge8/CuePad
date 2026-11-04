#if os(iOS)
import CueStore
import SwiftUI

// PROTOTYPE（一次性分支 proto/head-phone2，不进主分支）：窄屏侧栏进展段两层分段的收口，`-CuePadNav one|two` 切，不给是现状。
// one：手机也去掉进展的会话段（同宽屏）。侧栏一排是项目｜进展、项目范围与额度一块、Cue 头像；已结束的会话在 Cue 页会话条底下的"更早"，点了推入一页；
//      新会话是看板推进中行头的"+"（同待办行头的"+"）；项目页"⋯"是"看这个项目的进展"。
// two：两层压成一层，项目｜看板｜会话三段平级（只写字、不画图标），记住上次那一段；看板与会话共用中间那一块（项目范围的小图形与额度环）。
enum NavVariant: String {
    case now, one, two

    static let current = DebugHooks.preset.nav
}

/// 方案 one 推入"更早"那一页（原型借 `navigationDestination(isPresented:)` 推，正式实现给 `Route` 加一项）。
@Observable
final class NavProtoBus {
    static let shared = NavProtoBus()
    var earlier = false
}

/// 方案 two：项目｜看板｜会话三段平级，只写字。去处只有这一层：看板、会话就是 `navigationPane == .progress` 加 `progressPane`。
struct NavTriple: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Place: Hashable { case projects, board, sessions }

    private var place: Place {
        workspace.navigationPane == .projects ? .projects : workspace.progressPane == .board ? .board : .sessions
    }

    var body: some View {
        HStack(spacing: 0) {
            item(.projects, "项目")
            item(.board, "看板")
            item(.sessions, "会话")
        }
        .frame(height: FloatingHeaderLayout.height - PaneMetrics.inset * 2)
        .padding(PaneMetrics.inset)
        .glass(in: .capsule, interactive: true)
        .fixedSize()
        .dynamicTypeSize(...FloatingHeaderLayout.largestType)
    }

    private func item(_ target: Place, _ title: LocalizedStringResource) -> some View {
        let on = place == target
        return Button { go(target) } label: {
            Text(title).font(PaneMetrics.font).lineLimit(1)
                .padding(.horizontal, PaneMetrics.padding)
                .frame(maxHeight: .infinity)
                .foregroundStyle(on ? palette.ink : palette.ink2)
                .background(on ? palette.selection : .clear, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func go(_ target: Place) {
        guard target != place else { return }
        withAnimation(Motion.fading(Motion.nudge, reduceMotion: reduceMotion)) {
            switch target {
            case .projects: workspace.selectPane(.projects)
            case .board: workspace.progressPane = .board; workspace.selectPane(.progress)
            case .sessions: workspace.progressPane = .sessions; workspace.selectPane(.progress)
            }
        }
    }
}

/// 方案 one：Cue 页会话条底下的"更早"一格（同宽屏图标条上的 `RailEarlier`：字与个数），点它推入"更早"那一页。没有已结束的会话时不画。
struct PhoneEarlierTile: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var total: Int?

    var body: some View {
        Group {
            if let total, total > 0 {
                Button { NavProtoBus.shared.earlier = true } label: {
                    VStack(spacing: 1) {
                        Text("更早").foregroundStyle(palette.ink2)
                        Text(total, format: .number).foregroundStyle(palette.ink3).monospacedDigit()
                    }
                    .font(.caption2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(PressStyle(.card))
                .paper(cornerRadius: Radius.block)
                .accessibilityLabel(Text("更早"))
                .accessibilityValue(Text(total, format: .number))
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .padding(.horizontal, SessionRail.phoneInset)
        .frame(width: SessionRail.Form.phone.width)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .observing(services.store, into: $total, onError: workspace.fail) { store in
            try store.piSessionPage(PiSessionQuery(scope: .ended, limit: 1)).total
        }
    }
}

/// 方案 one："更早"那一页：已结束的会话，按结束时间分段（同会话列表的"历史"，`SessionList` 的 `endedOnly`）。推入的页，左边系统返回。
struct EarlierScreen: View {
    @Environment(\.palette) private var palette
    @State private var model = AgentListModel()

    var body: some View {
        SessionList(model: model, filter: nil, endedOnly: true)
            .floatingHeader("更早")
            .contentMargins(.top, 0, for: .scrollContent)
            .safeAreaPadding(.top, Bars.contentGap)
            .containerBackground(palette.desk, for: .navigation)
            .navigationBarTitleDisplayMode(.inline)
            .scrollEdgeEffectHidden()
    }
}

/// 方案 one、two：项目段末尾那一组的第一行"额度"（同 Mac 会话条底下那一行，`SidebarQuota`）：右边几颗额度环，点它原地展开明细。
/// 进展那一排放不下项目范围（写成字）再加额度环：项目范围是这一页看什么，留在那一排；额度是账号的事，同归档、设置一组。
struct ShelfQuota: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open = DebugHooks.preset.quotaOpen

    var body: some View {
        VStack(spacing: 0) {
            QuotaRings(open: open, height: 48, row: true, rowInk: true) {
                withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { open.toggle() }
            }
            .padding(.horizontal, 16)
            if open {
                QuotaDetail().padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 14).transition(.opacity)
            }
        }
        .refreshesQuota()
    }
}

/// 方案 one、two：进展那一排中间只放项目范围（写成字，点它换项目；选了项目时后面一颗 ✕）。
/// 窄到放不下（iPad 320 窄窗、方案 two 三段写字）退成一颗圆钮：看全部时是筛选图标，选了是那个项目的图标，点开同一份菜单。
struct ScopePiece: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            ProjectScope(nameWidth: 72).glass(in: .capsule, interactive: true)
            ScopeButton()
        }
        .dynamicTypeSize(...FloatingHeaderLayout.largestType)
    }
}

struct ScopeButton: View {
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
                if let current { ProjectGlyph(project: current, size: 15) } else { Image(.filter) }
            }
        }
        .menuStyle(.button)
        .buttonStyle(ControlButtonStyle(kind: .circular))
        .accessibilityLabel(Text(current.map { "项目范围：\($0.shownName)" } ?? String(localized: "项目范围：全部项目")))
    }
}

/// 方案 1 之上，侧栏那一排的摆法（`-CuePadBar a|b`，只在 `-CuePadNav one` 下起作用）：项目｜进展在正中，两侧各放同样多的圆钮、贴边对齐，都只画图标。
/// a：两侧各一颗，左搜索、右 Cue 头像，换段时这一排一点不变；新建项目是项目列表末尾一行，项目范围是看板顶上一行。
/// b：两侧各两颗，左搜索与这一段的低频（项目段新建项目、进展段项目范围），右额度与 Cue 头像；内容里不放操作。
enum BarVariant: String {
    case a, b

    static let current = NavVariant.current == .one ? DebugHooks.preset.bar : nil
}

/// 正中一组分段、两侧各 `count` 颗圆钮的一排：两侧按同样的宽占位（多颗时按 `count` 算），分段在两侧之间居中，放不下带字时只画图标。
struct CenteredBar: View {
    let variant: BarVariant
    @Environment(Workspace.self) private var workspace

    private var count: Int { variant == .a ? 1 : 2 }
    private var side: CGFloat { CGFloat(count) * FloatingHeaderLayout.height + CGFloat(count - 1) * Self.gap }
    private static let gap: CGFloat = 6

    var body: some View {
        HStack(spacing: Self.gap) {
            HStack(spacing: Self.gap) {
                circle("搜索", icon: .search) { workspace.openSearch() }
                if variant == .b { paneTool }
            }
            .frame(width: side, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                panes(titles: true)
                panes(titles: false)
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: Self.gap) {
                if variant == .b { QuotaButton() }
                HeadCue()
            }
            .frame(width: side, alignment: .trailing)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(ControlButtonStyle(kind: .circular))
        .dynamicTypeSize(...FloatingHeaderLayout.largestType)
        .padding(.horizontal, FloatingHeaderLayout.margin)
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

    @ViewBuilder private var paneTool: some View {
        switch workspace.navigationPane {
        case .projects: circle("新建项目", icon: .newProject) { workspace.projectForm = .init() }
        case .progress: ScopeButton()
        }
    }

    private func circle(_ title: LocalizedStringResource, icon: Icon, action: @escaping () -> Void) -> some View {
        Button(title, icon: icon, action: action).help(Text(title))
    }
}

/// 回 Cue 的头像圆钮（同 `NarrowSidebarBar` 右边那一颗）。
private struct HeadCue: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button { workspace.select(.cue) } label: {
            CueAvatar(workspace.cue.beat, size: .row)
                .relaySpot(cue: .entry)
                .frame(width: FloatingHeaderLayout.height, height: FloatingHeaderLayout.height)
        }
        .buttonStyle(ControlButtonStyle(kind: .circular))
        .accessibilityLabel(workspace.cue.name)
        .accessibilityIdentifier("narrow-cue")
    }
}

/// b：额度一颗圆钮，里面是余量最紧的那个账号的环（同 `QuotaRings` 的环），点它弹出明细。
/// PROTOTYPE：明细借系统弹出框（`popover`）；落地时从这颗钮长出 `GrowPanel`。
private struct QuotaButton: View {
    @Environment(AppServices.self) private var services
    @State private var open = DebugHooks.preset.quotaOpen

    var body: some View {
        let quotas = services.accountQuotas.items
        Button { open = true } label: {
            Moments(next: quotas.nextReset(after:)) { now in
                let first = quotas.lazy.compactMap { quota in quota.binding(at: now).map { (quota, QuotaMeter.Window($0, at: now)) } }.first
                if let (quota, window) = first {
                    ModelBadge(mark: PiProvider(id: quota.provider).mark, binding: window)
                } else {
                    Text("额度").font(.caption2.weight(.semibold))
                }
            }
            .frame(width: FloatingHeaderLayout.height, height: FloatingHeaderLayout.height)
        }
        .accessibilityLabel(Text("额度"))
        .help(Text("额度"))
        .popover(isPresented: $open) {
            QuotaDetail().padding(16).frame(width: 340).refreshesQuota().presentationCompactAdaptation(.popover)
        }
        .refreshesQuota()
    }
}

/// a：看板顶上一行项目范围（看全部时"全部项目 ⌄"，选了写名字带 ✕），与看板的卡同一条左边。
struct ScopeLine: View {
    var body: some View {
        HStack { ProjectScope(nameWidth: 200); Spacer(minLength: 0) }
            .padding(.leading, BoardRowMetrics.lead - 14)
            .dynamicTypeSize(...FloatingHeaderLayout.largestType)
    }
}

/// a：项目列表末尾一行"新建项目"（同书架的行，`ShelfRow` 的高与左边）。
struct NewProjectRow: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 17

    var body: some View {
        Button { workspace.projectForm = .init() } label: {
            HStack(spacing: 12) {
                Image(.add).font(.system(size: glyph)).frame(width: glyph + 6).accessibilityHidden(true)
                Text("新建项目")
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.ink2)
            .padding(.horizontal, 16).frame(minHeight: 48)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
    }
}
#endif
