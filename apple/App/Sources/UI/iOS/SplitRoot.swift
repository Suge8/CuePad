#if os(iOS)
import CueStore
import SwiftUI

/// iOS 的分栏，各种宽度同一个：左栏是侧栏列表（`SplitSidebar`），右边是选中的页与其上推入的页（打开的卡片纸页推在项目页上）。
/// 宽屏两栏并排，Cue 可在右侧面板里与项目并排看；iPhone（与窄窗口 iPad）上由系统折叠成一层层的页：列表是首页，打开 App 落在 Cue，
/// 系统的返回与左缘右滑回到列表（`Navigation.column`）。不另写抽屉、手势或标签栏。
/// 外接键盘与 Mac 对齐：⌘1–9 切项目、⌘K（及 ⌘F）搜索、⌘\ 侧栏、⌘N 新建卡片、⌘⇧N 对 Cue 说、⌘⇧T 任务、⌘, 设置。
struct SplitRoot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var width: CGFloat = 0
    /// 侧栏选中的项目（宽屏恢复窗口时选回它；选的不是项目时为空）。只存这一个：当前项目由路径推出（`Navigation.currentProject`）
    @SceneStorage("splitProject") private var storedProject = ""

    private static let threeColumnWidth: CGFloat = 1100
    /// 侧栏与右侧面板随字号加宽（辅助字号下项目名不被截成"…"），各有上限，详情栏总留得下。
    @ScaledMetric(relativeTo: .body) private var sidebarWidth: CGFloat = 280
    @ScaledMetric(relativeTo: .body) private var panelWidth: CGFloat = 360
    private static let maxSidebarWidth: CGFloat = 420
    private static let maxPanelWidth: CGFloat = 480

    private var wide: Bool { sizeClass == .regular }

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView(columnVisibility: $navigation.sidebar, preferredCompactColumn: $navigation.column) {
            SplitSidebar(underPage: !wide)
                .navigationSplitViewColumnWidth(
                    min: 240, ideal: min(sidebarWidth, Self.maxSidebarWidth), max: max(340, min(sidebarWidth, Self.maxSidebarWidth)))
        } detail: {
            // 折叠时右边这一栏的导航栈直接接在列表后面，外面不能再包一层：包了系统就认不出它，推入的页成了栈里套栈
            if wide {
                // 右侧面板与详情栏并排（不用 .inspector：它包在分栏或导航栈上时，推入的页面拿不到导航栏的安全区，
                // 大标题与返回按钮压在内容上；挂进导航栈里又会把面板的工具栏并进详情栏）
                HStack(spacing: 0) {
                    stack
                    if navigation.agentPanel {
                        Divider().ignoresSafeArea()
                        AgentPanel()
                            .frame(width: min(panelWidth, Self.maxPanelWidth))
                            .transition(.move(edge: .trailing))
                    }
                }
            } else {
                stack
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // 窄窗口（竖屏、分屏）放不下三栏：打开右侧面板或卡片纸页时收起侧栏，纸页盖住整个右侧
        .onChange(of: navigation.agentPanel) { _, shown in
            if shown { collapseSidebarIfNarrow() }
        }
        .onChange(of: navigation.path) { _, path in
            if case .card = path.last { collapseSidebarIfNarrow() }
        }
        .background { SplitShortcuts() }
        .onAppear { if wide { navigation.restore(project: UUID(uuidString: storedProject), catalog: workspace.catalog) } }
        .onChange(of: navigation.root) { _, root in
            if case .project(let id) = root { storedProject = id.uuidString } else { storedProject = "" }
        }
    }

    private var stack: some View {
        @Bindable var navigation = navigation
        return NavigationStack(path: $navigation.path) {
            page(navigation.root)
                .navigationDestination(for: Route.self) { page($0) }
        }
    }

    /// 右边的页：宽屏上 Cue 面板的开关在每一页上（推入的页也有），卡片纸页与 Cue 页本身除外——纸页有自己的复制、发送与更多。
    @ViewBuilder private func page(_ route: Route) -> some View {
        if !wide || route.isCard || route == .cue {
            RouteView(route: route)
        } else {
            RouteView(route: route).toolbar {
                ToolbarItem(placement: .primaryAction) { AgentPanelButton() }
            }
        }
    }

    private func collapseSidebarIfNarrow() {
        guard wide, width < Self.threeColumnWidth, navigation.sidebar != .detailOnly else { return }
        withAnimation(Motion.panel) { navigation.sidebar = .detailOnly }
    }
}

/// 右侧 Cue 面板的开关（和项目并排看 Cue）；有等你的时带点（`WaitingDot`）。
private struct AgentPanelButton: View {
    @Environment(Navigation.self) private var navigation
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let waiting = workspace.cue.waiting
        Button { withAnimation(Motion.panel) { navigation.agentPanel.toggle() } } label: {
            Label(workspace.cue.name, systemImage: "bubble.left.and.text.bubble.right")
                .overlay(alignment: .topTrailing) { WaitingDot(count: waiting) }
        }
        .accessibilityValue(waiting > 0 ? "等你 \(waiting)" : "")
    }
}

/// 右侧 Cue 面板。不套导航栈、不放工具栏：iPadOS 的详情栏只有一条工具栏，面板里的工具栏会并进去。
/// 它不经 `RouteView`，沉浸式的那几件自己挂：离顶上那一排的距离让在安全区里（用外边距的话列表停在边距下沿、
/// 滚上去被一刀切齐），内容一直滚到工具栏的玻璃后面，只在状态栏那一条淡出。
private struct AgentPanel: View {
    @Environment(\.palette) private var palette

    var body: some View {
        CuePage(inPanel: true).countsAsPiViewer()
            .safeAreaPadding(.top, 8)
            .fadesUnderBars()
            .background(palette.desk.ignoresSafeArea())
            .modifier(KeyboardHold())
    }
}

/// 侧栏列表，结构见 `SidebarOutline`：顶上是搜索框（点它去搜索页并聚焦），Cue（`CueSidebarItem`），任务与会话，置顶与最近的项目
/// （末尾未分类与"全部项目"），底部归档、回收站与设置（同步到不了 Mac 时设置那一行带一个点）。
/// iPhone 上它就是首页：宽屏选中的那一行垫选中底，iPhone 只在推进去的那一页还在时垫着，回到列表时淡掉（同系统列表返回时的取消选中）。
private struct SplitSidebar: View {
    /// iPhone：列表压在打开的那一页底下，不在第一帧里。
    let underPage: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services
    /// 各项目的进行中任务，最近开始的在前（项目行的"此刻"，`ProjectNow`）。
    @State private var leading: [UUID: [ProjectNow.InProgress]]?
    /// 列表建出来了。iPhone 上打开 App 落在 Cue 页、列表压在底下：等 Cue 页那一帧交出去再建，冷启动的第一帧里不排一整个看不见的列表；
    /// 下一帧就建，返回列表之前早已建好（等到返回时才建，左缘右滑的第一帧要现排整个列表）。
    @State private var built = false

    var body: some View {
        Group {
            if built || !underPage || navigation.column == .sidebar { list } else { Color.clear }
        }
        // 侧栏用共用的侧栏层色（深色是更深一档的暖黑），不用系统偏冷的灰
        .background(palette.sidebar)
        .navigationTitle("CuePad")
        .toolbar {
            Button("新建项目", systemImage: "folder.badge.plus") { navigation.projectForm = .init() }
        }
        .task {
            await NextFrame.wait()
            built = true
        }
    }

    private var list: some View {
        // 不用 List：行数有数（置顶的几个、最近至多几个、固定的几行），普通栈就够，格子的底、分隔线与间距也不用再一项项关掉
        ScrollView {
            VStack(alignment: .leading, spacing: Self.rowGap) {
                SidebarSearchField().padding(.bottom, 10)
                CueSidebarItem().padding(.bottom, 6)
                ForEach(SidebarOutline.places, id: \.self) { SidebarRow(entry: $0, badge: badge($0)) }
                if let catalog = workspace.catalog {
                    let outline = SidebarOutline(catalog)
                    // 各项目的"此刻"在数据变化时算一次，行只拿结果
                    let now = ProjectNow.byProject(
                        outline.projects, sessions: services.liveSessions.items, tasks: leading ?? [:], shown: workspace.shown)
                    if !outline.pinned.isEmpty {
                        header("置顶")
                        ForEach(outline.pinned) { row($0, catalog, now: now[$0.id]) }
                    }
                    if !outline.recent.isEmpty || outline.unfiled > 0 {
                        header("最近")
                        ForEach(outline.recent) { row($0, catalog, now: now[$0.id]) }
                        if outline.unfiled > 0 { SidebarRow(route: .unfiled, title: CaptureCopy.unfiled, symbol: "tray", badge: outline.unfiled) }
                        if outline.showsAllProjects { SidebarRow(entry: .allProjects, badge: catalog.projects.count) }
                    }
                }
                VStack(alignment: .leading, spacing: Self.rowGap) {
                    ForEach(SidebarOutline.footer, id: \.self) { SidebarRow(entry: $0, alert: $0 == .settings ? syncAlert : nil) }
                }
                .padding(.top, Self.groupGap)
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
        .observing(services.store, into: $leading, onError: workspace.fail) { TaskBoard.leading(try $0.startedTasks()) }
    }

    private static let rowGap: CGFloat = 2
    private static let groupGap: CGFloat = 16

    private func header(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink3)
            .padding(.top, Self.groupGap).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func badge(_ entry: SidebarOutline.Entry) -> Int {
        switch entry {
        case .tasks: workspace.catalog?.allTasks.open ?? 0
        case .sessions: services.liveSessions.total
        default: 0
        }
    }

    /// 同步到不了 Mac 时设置那一行带的点（提示赭黄、真出错胭脂），点进设置看 iCloud 那一节；平时没有。
    private var syncAlert: SidebarRow.Alert? {
        let status = services.syncStatus
        guard !status.reachesMac else { return nil }
        let summary = SyncSummary(status)
        return .init(color: palette.color(summary.tone), text: summary.title)
    }

    private func row(_ project: Project, _ catalog: ProjectCatalog, now: ProjectNow?) -> some View {
        SidebarRow(route: .project(project.id), title: project.name, project: project, badge: catalog.cardCounts[project.id] ?? 0, now: now)
            .projectActions(project, radius: 10, pi: now?.shown)
    }
}

/// 列表顶上的搜索框：点它去搜索页，那里的搜索框接着拿到键盘（同 ⌘K）。长相同搜索页的搜索框（`SearchCapsule`）。
private struct SidebarSearchField: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        Button { navigation.openSearch() } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.ink3)
                // 窄侧栏（iPad）放不下整句时只写"搜索"，不截成半句
                ViewThatFits(in: .horizontal) {
                    Text("搜索灵感、任务与会话")
                    Text("搜索")
                }
                .foregroundStyle(palette.ink3).lineLimit(1)
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

/// 侧栏最上面的 Cue：头像、名字、此刻在做什么、"等你 N"，点开 Cue 页。
private struct CueSidebarItem: View {
    @Environment(Navigation.self) private var navigation

    var body: some View {
        let selected = navigation.shows(.cue)
        Button { navigation.select(.cue) } label: {
            CueStatusRow(font: .body.weight(selected ? .semibold : .medium)).frame(minHeight: 60).contentShape(.rect)
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 侧栏一行的底：选中是共用的选中底色（不是实心胶囊，只告诉你"在这里"，不抢内容的注意），按住亮一层浅底；
/// 按下即亮、松开与选中的变化都淡出。行内容在底里，底比内容两侧各宽出一截，同一列圆角块对齐。
private struct SidebarRowStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.palette) private var palette

    private static let bleed: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Self.bleed)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? palette.selection : configuration.isPressed ? palette.fill : .clear)
            }
            .padding(.horizontal, -Self.bleed)
            .animation(configuration.isPressed ? nil : Motion.quick, value: configuration.isPressed)
            .animation(Motion.quick, value: selected)
    }
}

/// 侧栏的一项。选中态是共用的选中底色加粗字（`SidebarRowStyle`）。
private struct SidebarRow: View {
    /// 行尾一个点（设置：同步到不了 Mac）与它给读屏的话。
    struct Alert {
        let color: Color
        let text: String
    }

    let route: Route
    let title: String
    var symbol: String?
    var project: Project?
    var badge = 0
    /// 项目行的"此刻"（项目行总留着这一行的高度）。
    var now: ProjectNow?
    var alert: Alert?
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    /// 图标随字号放大（侧栏列表里的符号默认不跟随辅助字号）。
    @ScaledMetric(relativeTo: .body) private var icon: CGFloat = 16

    var body: some View {
        let selected = navigation.shows(route)
        Button { navigation.select(route) } label: {
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
                if let symbol { Image(systemName: symbol).font(.system(size: icon)) } else { ProjectGlyph(project: project, size: icon) }
            }
            .foregroundStyle(palette.ink)
            .padding(.vertical, 4).frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(SidebarRowStyle(selected: selected))
        .accessibilityValue(alert?.text ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension SidebarRow {
    init(entry: SidebarOutline.Entry, badge: Int = 0, alert: Alert? = nil) {
        self.init(route: entry.route, title: entry.title, symbol: entry.symbol, badge: badge, alert: alert)
    }
}

private extension SidebarOutline.Entry {
    /// 点这一行去的页。
    var route: Route {
        switch self {
        case .tasks: .tasks
        case .sessions: .agent
        case .allProjects: .shelf
        case .archive: .archive
        case .trash: .trash
        case .settings: .settings
        }
    }
}

private extension Navigation {
    /// 侧栏这一行此刻垫不垫选中底：选中的那一页，iPhone 上只在推进去的那一页还在时（回到列表时淡掉；宽屏一直在页里）。
    /// 不按尺寸类判断宽窄：侧栏这一栏里的尺寸类总是窄的。
    func shows(_ route: Route) -> Bool { root == route && column == .detail }
}

/// 外接键盘快捷键（不占位的隐形按钮）。
private struct SplitShortcuts: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation

    /// 新卡放进正在看的项目（不在项目里时进未分类），随即打开。
    private func newCard() {
        let project = navigation.currentProject
        workspace.attempt {
            let card = try await workspace.createCard(in: project)
            if navigation.root == .search { navigation.closeSearch() }
            navigation.push(.card(card.id))
        }
    }

    var body: some View {
        ZStack {
            Button("搜索") { navigation.openSearch() }.keyboardShortcut("k")
            Button("搜索") { navigation.openSearch() }.keyboardShortcut("f")
            // 搜索框没有焦点时 Esc 退出搜索（有焦点时第一下 Esc 由系统收起输入）
            if navigation.root == .search {
                Button("退出搜索") { navigation.closeSearch() }.keyboardShortcut(.escape, modifiers: [])
            }
            Button("记一条灵感", action: newCard).keyboardShortcut("n")
            Button("对 Cue 说") { navigation.speakToCue() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("设置") { navigation.select(.settings) }.keyboardShortcut(",")
            Button("侧栏") {
                withAnimation(Motion.panel) { navigation.sidebar = navigation.sidebar == .detailOnly ? .automatic : .detailOnly }
            }
            .keyboardShortcut("\\")
            Button("任务") { navigation.show(.tasks) }.keyboardShortcut("t", modifiers: [.command, .shift])
            ForEach(Array((workspace.catalog?.projects ?? []).prefix(9).enumerated()), id: \.offset) { index, project in
                Button("项目 \(index + 1)") { navigation.show(.project(project.id)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
#endif
