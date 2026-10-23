#if os(iOS)
import CueStore
import SwiftUI

/// 宽屏（iPad）的分栏：左栏是侧栏列表（`SplitSidebar`），右边是选中的页与其上推入的页（打开的卡片纸页推在项目页上），
/// Cue 可在右侧面板里与项目并排看。窄屏不用它（`DockRoot`）：折叠后的分栏这个容器本身比导航栈多约 3000M 指令（冷启动同口径交替量）。
struct SplitRoot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.statusBarBottom) private var statusBar
    @State private var width: CGFloat = 0
    /// 侧栏选中的项目（宽屏恢复窗口时选回它；选的不是项目时为空）。只存这一个：当前项目由路径推出（`Workspace.currentProject`）
    @SceneStorage("splitProject") private var storedProject = ""

    private static let threeColumnWidth: CGFloat = 1100
    /// 侧栏与右侧面板随字号加宽（辅助字号下项目名不被截成"…"），各有上限，详情栏总留得下。
    @ScaledMetric(relativeTo: .body) private var sidebarWidth: CGFloat = 280
    @ScaledMetric(relativeTo: .body) private var panelWidth: CGFloat = 360
    private static let maxSidebarWidth: CGFloat = 420
    private static let maxPanelWidth: CGFloat = 480

    var body: some View {
        @Bindable var workspace = workspace
        NavigationSplitView(columnVisibility: $workspace.sidebar) {
            SplitSidebar()
                .navigationSplitViewColumnWidth(
                    min: 240, ideal: min(sidebarWidth, Self.maxSidebarWidth), max: max(340, min(sidebarWidth, Self.maxSidebarWidth)))
        } detail: {
            // 右侧面板与详情栏并排（不用 .inspector：它包在分栏或导航栈上时，推入的页面拿不到导航栏的安全区，
            // 大标题与返回按钮压在内容上；挂进导航栈里又会把面板的工具栏并进详情栏）
            HStack(spacing: 0) {
                // 提示横幅在右边这一栏里居中：按整个窗口居中时盖住侧栏顶上的圆钮。竖直按状态栏下沿排，与窄屏同一排：
                // 这一栏的上安全区还含着分栏的工具栏那一排，按它排就掉到页头上了
                stack.overlay(alignment: .top) { NoticeBanner().padding(.top, statusBar).ignoresSafeArea(edges: .top) }
                if workspace.agentPanel {
                    Divider().ignoresSafeArea()
                    AgentPanel()
                        .frame(width: min(panelWidth, Self.maxPanelWidth))
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // 窄窗口（竖屏、分屏）放不下三栏：打开右侧面板或卡片纸页时收起侧栏，纸页盖住整个右侧
        .onChange(of: workspace.agentPanel) { _, shown in
            if shown { collapseSidebarIfNarrow() }
        }
        .onChange(of: workspace.path) { _, path in
            if case .card = path.last { collapseSidebarIfNarrow() }
        }
        .onAppear { workspace.restore(project: UUID(uuidString: storedProject)) }
        .onChange(of: workspace.root) { _, root in
            if case .project(let id) = root { storedProject = id.uuidString } else { storedProject = "" }
        }
    }

    private var stack: some View {
        @Bindable var workspace = workspace
        return NavigationStack(path: $workspace.path) {
            // 根页的名字在侧栏的选中格里（侧栏收起时侧栏钮就在左上角），页顶那一排不再写；推入的页照写
            page(workspace.root)
                .environment(\.pageNamedElsewhere, true)
                .navigationDestination(for: Route.self) { page($0).environment(\.pageNamedElsewhere, false) }
        }
    }

    /// 右边的页：Cue 面板的开关在每一页上（推入的页也有），卡片纸页与 Cue 页本身除外——纸页有自己的复制、发送与更多。
    @ViewBuilder private func page(_ route: Route) -> some View {
        if route.isCard || route == .cue {
            RouteView(route: route)
        } else {
            RouteView(route: route).toolbar {
                ToolbarItem(placement: .primaryAction) { AgentPanelButton() }
            }
        }
    }

    private func collapseSidebarIfNarrow() {
        guard width < Self.threeColumnWidth, workspace.sidebar != .detailOnly else { return }
        withAnimation(Motion.snappy) { workspace.sidebar = .detailOnly }
    }
}

/// 右侧 Cue 面板的开关（和项目并排看 Cue）；有等你或新消息时带点（`CueDot`）。
private struct AgentPanelButton: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let waiting = workspace.cue.waiting, unread = workspace.cue.unread
        Button { withAnimation(Motion.snappy) { workspace.agentPanel.toggle() } } label: {
            Label { Text(workspace.cue.name) } icon: { CueMark(selected: workspace.agentPanel) }
                .overlay(alignment: .topTrailing) { CueDot().offset(x: 3, y: -2) }
        }
        .accessibilityValue(unread > 0 ? "\(unread) 条新消息" : waiting > 0 ? "等你 \(waiting)" : "")
    }
}

/// 右侧 Cue 面板。不套导航栈、不放工具栏：iPadOS 的详情栏只有一条工具栏，面板里的工具栏会并进去。
/// 它不经 `RouteView`，沉浸式的那几件自己挂：页顶那一排（Cue 的名牌）由面板自己画（`HeaderHost.panel`），
/// 内容一直滚到它与状态栏后面，什么也不遮（`Bars`）。
private struct AgentPanel: View {
    @Environment(\.palette) private var palette

    var body: some View {
        CuePage(inPanel: true).countsAsPiViewer()
            .environment(\.headerHost, .panel)
            .background(palette.desk.ignoresSafeArea())
            .modifier(KeyboardHold())
    }
}

/// 侧栏列表，结构见 `SidebarOutline`：顶上是搜索框（点它把搜索页推在当前页上并聚焦），Cue（`CueSidebarItem`），任务与会话，置顶与最近的项目
/// （末尾"全部项目"），底部归档、回收站与设置（同步到不了 Mac 时设置那一行带一个点）。选中的那一行垫选中底。
private struct SplitSidebar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services
    /// 各项目的进行中任务，最近开始的在前（项目行的"此刻"，`ProjectNow`）。
    @State private var leading: [UUID: [ProjectNow.InProgress]]?

    var body: some View {
        list
            // 侧栏用共用的侧栏层色（深色是更深一档的暖黑），不用系统偏冷的灰
            .background(palette.sidebar)
            .navigationTitle("CuePad")
            .toolbar {
                Button("新建项目", icon: .newProject) { workspace.projectForm = .init() }
            }
    }

    private var list: some View {
        // 不用 List：行数有数（置顶的几个、最近至多几个、固定的几行），普通栈就够，格子的底、分隔线与间距也不用再一项项关掉
        ScrollView {
            VStack(alignment: .leading, spacing: Self.rowGap) {
                SidebarSearchField().padding(.bottom, 10)
                CueSidebarItem().padding(.bottom, 6)
                ForEach(SidebarOutline.places, id: \.self) { SidebarRow(entry: $0) }
                if let catalog = workspace.catalog {
                    let outline = SidebarOutline(catalog)
                    // 各项目的"此刻"在数据变化时算一次，行只拿结果
                    let now = ProjectNow.byProject(
                        outline.projects, sessions: services.liveSessions.items, tasks: leading ?? [:], shown: workspace.shown)
                    header("项目")
                    ForEach(outline.projects) { row($0, catalog, now: now[$0.id]) }
                }
                VStack(alignment: .leading, spacing: Self.rowGap) {
                    ForEach(SidebarOutline.footer, id: \.self) { SidebarRow(entry: $0, alert: $0 == .settings ? syncAlert : nil) }
                }
                .padding(.top, Self.groupGap)
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
        .observing(services.store, into: $leading, onError: workspace.fail) { ProjectNow.leading(try $0.startedTasks()) }
    }

    private static let rowGap: CGFloat = 2
    private static let groupGap: CGFloat = 16

    private func header(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink3)
            .padding(.top, Self.groupGap).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// 同步到不了 Mac 时设置那一行带的点（提示赭黄、真出错胭脂），点进设置看 iCloud 那一节；平时没有。
    private var syncAlert: SidebarRow.Alert? {
        services.macAlert.map { .init(color: palette.color($0.tone), text: $0.title) }
    }

    private func row(_ project: Project, _ catalog: ProjectCatalog, now: ProjectNow?) -> some View {
        SidebarRow(route: .project(project.id), title: project.name, project: project, badge: catalog.cardCounts[project.id] ?? 0, now: now)
            .projectActions(project, radius: 10, pi: now?.shown)
    }
}

/// 列表顶上的搜索框：点它把搜索页推在当前页上，那里的搜索框接着拿到键盘（同 ⌘K）。长相同搜索页的搜索框（`SearchCapsule`）。
/// 搜索页开着时它是选中的那一格（签名色写"搜索"），不再写同一句提示：同一屏只有一个搜索框。
private struct SidebarSearchField: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let searching = workspace.top == .search
        Button { workspace.openSearch() } label: {
            HStack(spacing: 6) {
                Image(.search).foregroundStyle(searching ? palette.signature : palette.ink3)
                // 窄侧栏（iPad）放不下整句时只写"搜索"，不截成半句
                Group {
                    if searching {
                        Text("搜索").fontWeight(.semibold).foregroundStyle(palette.signature)
                    } else {
                        ViewThatFits(in: .horizontal) {
                            Text("搜索灵感、任务与会话")
                            Text("搜索")
                        }
                        .foregroundStyle(palette.ink3)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: SearchCapsule.height)
            .glass(in: .capsule, interactive: true)
            .contentShape(.capsule)
        }
        .buttonStyle(PressStyle(.wide))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("搜索")
        .accessibilityAddTraits([.isButton, .isSearchField])
    }
}

/// 侧栏最上面的 Cue：头像、名字与 Cue 此刻那一行（`CueStatusRow`），点开 Cue 页。Cue 页开着（右边那页或右侧面板）时不写此刻那一行：
/// 页头（`CueHeader`）就写着同一句，同屏不说两遍；行高不变（`minHeight`），名字在原高里居中，侧栏不挪。
private struct CueSidebarItem: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let selected = workspace.root == .cue
        Button { workspace.select(.cue) } label: {
            CueStatusRow(font: .body.weight(selected ? .semibold : .medium), status: !selected && !workspace.agentPanel)
                .frame(minHeight: 60).contentShape(.rect)
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 侧栏的一项。选中是行的选中底（`RowStyle`，不是实心胶囊，只告诉你"在这里"，不抢内容的注意）加粗字。
private struct SidebarRow: View {
    /// 行尾一个点（设置：同步到不了 Mac）与它给读屏的话。
    struct Alert {
        let color: Color
        let text: String
    }

    let route: Route
    let title: String
    var icon: Icon?
    var project: Project?
    var badge = 0
    /// 项目行的"此刻"（项目行总留着这一行的高度）。
    var now: ProjectNow?
    var alert: Alert?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    /// 图标随字号放大（侧栏列表里的符号默认不跟随辅助字号）。
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 16

    var body: some View {
        let selected = workspace.root == route
        Button { workspace.select(route) } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    // 辅助字号下名称独占一行、可换行，计数排到下一行：名称不被挤成"…"或从词中间断开
                    let layout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))
                    layout {
                        Text(title).fontWeight(selected ? .semibold : .regular).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        HStack(spacing: 6) {
                            Spacer(minLength: 4)
                            if let alert { Circle().fill(alert.color).frame(width: 7, height: 7).accessibilityHidden(true) }
                            if badge > 0 { Text("\(badge)").font(.subheadline.monospacedDigit()).foregroundStyle(palette.ink3) }
                        }
                    }
                    if project != nil { ProjectNowLine(now: now, font: .footnote) }
                }
            } icon: {
                if let icon { IconImage(icon, accent: selected ? .lit : .none).font(.system(size: glyph)) } else { ProjectGlyph(project: project, size: glyph) }
            }
            .foregroundStyle(palette.ink)
            .padding(.vertical, 4).frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityValue(alert?.text ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension SidebarRow {
    init(entry: SidebarOutline.Entry, badge: Int = 0, alert: Alert? = nil) {
        self.init(route: entry.route, title: entry.title, icon: entry.icon, badge: badge, alert: alert)
    }
}
#endif
