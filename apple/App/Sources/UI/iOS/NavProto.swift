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
                .foregroundStyle(on ? palette.signature : palette.ink2)
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
        .padding(.horizontal, SessionRail.Form.phone.inset)
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
                if let current { ProjectGlyph(project: current, size: 15) } else { Image(.filter) }
            }
        }
        .menuStyle(.button)
        .buttonStyle(ControlButtonStyle(kind: .circular))
        .accessibilityLabel(Text(current.map { "项目范围：\($0.shownName)" } ?? String(localized: "项目范围：全部项目")))
    }
}
#endif
