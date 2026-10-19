#if os(macOS)
import CueStore
import SwiftUI

/// 侧栏自己读的：回收站条数与各项目最近开始的进行中任务（项目行的"此刻"，`ProjectNow`）。会话在 `LiveSessions`。
nonisolated private struct SidebarData: Sendable, Equatable {
    var trashCount: Int
    var leading: [UUID: [ProjectNow.InProgress]]
}

/// 侧栏的结构与 iPhone、iPad 同一份（`SidebarOutline`），这里只管 Mac 的长相：从上到下 Cue（`CueSidebarRow`）、任务与会话（`PlaceRows`：
/// 任务开合任务面板，会话打开 Agent 整页）、项目（置顶的在前，末尾未分类；Mac 没有书架，全部列出）、紧接着 Agent（Mac 独有：只列在线的会话，
/// 全部列出；其余与历史在"会话"那一页里），底栏是归档、回收站与设置。点哪一行，内容区就是哪一页。两区按内容高度分（`SidebarSplit`）：放得下时各占所需、Agent 紧跟项目，
/// 剩下的空白在 Agent 区下面；放不下时项目区保住至少一半可用高度，Agent 区先拿到所需、但最多拿到项目区用剩的高度，
/// 项目区拿剩下的、自己滚动（方向键与 ⌘1–9 换到的项目滚进可见区），Agent 区一直停在看得见的地方；Agent 多到超过这个上限时
/// 在自己的区里滚动（项目少时上限就是项目区用剩的全部，不在下面空着）。两区都是普通栈：项目与在线会话是几十行的量级，行高固定。
/// 每一行同一套横向尺寸：图标列（项目图标、会话状态标居中）同宽，任务、会话、项目名与会话名落在同一条竖线上。
struct Sidebar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: SidebarData?
    /// 点过侧栏里的页后焦点留在侧栏，方向键才有地方去
    @FocusState private var focused: Bool

    var body: some View {
        // 不用 List：系统选中是灰胶囊，压不过墨色体系，也没法让 Agent 区紧跟项目又不随项目滚走；当前页由 PageRow 自己画，方向键由 onMoveCommand 接管
        let catalog = workspace.catalog
        let pages = data.flatMap { data in catalog.map { SidebarPages($0, trashCount: data.trashCount) } }
        VStack(spacing: 0) {
            CueSidebarRow(select: select)
            PlaceRows(select: select).padding(.horizontal, SidebarMetrics.column).padding(.top, 6)
            SidebarSplit {
                if let data, let catalog, let pages {
                    projects(pages, catalog, data: data)
                    PiSection()
                }
            }
            footer(showsBins: pages?.showsBins ?? false, trashCount: data?.trashCount ?? 0)
        }
        .focusable()
        .focused($focused)
        // 选中样式本身就标出了位置，不再套系统焦点环
        .focusEffectDisabled()
        .onMoveCommand { direction in
            guard let order = pages?.order, let page = Self.page(after: workspace.page, in: order, moving: direction) else { return }
            workspace.show(page)
        }
        // 侧栏比桌面深一档：浅色、深色都能看出分层，与内容同一色温
        .background(palette.sidebar)
        .observing(services.store, into: $data, onError: workspace.fail) { store in
            SidebarData(trashCount: try store.trashCount(), leading: TaskBoard.leading(try store.startedTasks()))
        }
    }

    private func projects(_ pages: SidebarPages, _ catalog: ProjectCatalog, data: SidebarData) -> some View {
        // 各项目的"此刻"在数据变化时算一次，行只拿结果
        let now = ProjectNow.byProject(pages.outline.projects, sessions: services.liveSessions.items, tasks: data.leading, shown: workspace.shown)
        return VStack(alignment: .leading, spacing: 0) {
            SidebarHeader(title: "项目") {
                Button("新建项目", icon: .add) { workspace.projectForm = .init() }.disabled(!workspace.isLibraryReady)
            }
            SidebarScroll(revealsPage: true) {
                ProjectRows(pages: pages, catalog: catalog, now: now, select: select).padding(.horizontal, SidebarMetrics.column)
            }
        }
    }

    private func select(_ page: Route) {
        workspace.show(page)
        focused = true
    }

    /// 方向键：上一页 / 下一页，到头不循环；当前页不在侧栏里时从第一页开始。
    private static func page(after current: Route, in order: [Route], moving direction: MoveCommandDirection) -> Route? {
        guard let index = order.firstIndex(of: current) else { return order.first }
        switch direction {
        case .up: return index > order.startIndex ? order[index - 1] : nil
        case .down: return index + 1 < order.endIndex ? order[index + 1] : nil
        default: return nil
        }
    }

    /// 底栏：启动问题（有才出现），下面一排归档、回收站与设置。
    private func footer(showsBins: Bool, trashCount: Int) -> some View {
        VStack(spacing: 8) {
            StartupIssues()
            HStack(spacing: 2) {
                if showsBins {
                    FooterPage(entry: .archive, select: select)
                    FooterPage(entry: .trash, count: trashCount, select: select)
                }
                Spacer()
                let settings = SidebarOutline.Entry.settings
                Button(settings.title, icon: settings.icon) { SettingsPane.open() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.ink2)
                    .frame(width: 32, height: 32)
                    .help("设置（⌘,）")
            }
            .padding(.horizontal, SidebarMetrics.edge)
            .padding(.bottom, 10)
        }
        .padding(.top, 6)
    }
}

/// 侧栏一行的横向尺寸（任务、会话、项目行、未分类、会话行共用）：侧栏边缘到行的图标列 `column`，行的底（`RowStyle`）向外让出 `RowMetrics.bleed`、
/// 离侧栏边缘 `edge`；图标列宽 `Spacing.sidebarIcon`；会话的状态标（外框是点径的 1.8 倍，`PiStateDot`）在图标列里居中，名字离它 `dot + 2`
/// （`PiSessionRow` 的排法），项目名离图标列 `titleGap`，两种名字就落在同一条竖线上。
enum SidebarMetrics {
    static let edge: CGFloat = 10
    static let column = edge + RowMetrics.bleed
    static let rowGap: CGFloat = 2
    static let dot: CGFloat = 6
    private static let dotBox = dot * 1.8
    static let dotInset = (Spacing.sidebarIcon - dotBox) / 2
    static let titleGap = dotBox / 2 + dot + 2 - Spacing.sidebarIcon / 2
    static let session = PiSessionRow.Style(
        name: Typography.sidebarRow, line: Typography.sidebarDetail, meta: Typography.sidebarDetail, dot: dot, spacing: 2)
}

/// 侧栏一区的滚动：放得下时不弹；下面还有没露出的行时底边淡出一截，看得出能往下滚（只换一层遮盖，不影响排版）。
/// `revealsPage`：当前页是区里的一行（打开时、方向键、⌘1–9 换到）且不在可见处时，滚到它出现在可见区中间附近（不给锚点时 macOS 的实测行为），行以页（`Route`）为 id。
private struct SidebarScroll<Content: View>: View {
    var revealsPage = false
    @ViewBuilder let content: Content
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var continues = false

    private static var fade: CGFloat { 16 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { content }
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: Bool.self) { $0.visibleRect.maxY < $0.contentSize.height - 1 } action: { continues = $1 }
                .onChange(of: revealsPage ? workspace.page : nil, initial: true) { _, page in
                    if let page { proxy.scrollTo(page) }
                }
        }
        .overlay(alignment: .bottom) {
            if continues {
                LinearGradient(colors: [palette.sidebar.opacity(0), palette.sidebar], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fade)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// 侧栏的项目区与 Agent 区按内容高度分可用高度（规则见 `Sidebar`）：只按两区此刻要多高排，不把量到的尺寸写回状态。
/// 不回答对齐查询（默认实现会递归问遍两区的每一行）。
private struct SidebarSplit: Layout {
    /// 放不下时项目区至少保住可用高度的这一份；Agent 区的上限是项目区用剩的高度。
    private static let agentShare: CGFloat = 0.5

    static func heights(available: CGFloat, projects: CGFloat, agents: CGFloat) -> (projects: CGFloat, agents: CGFloat) {
        let reserved = min(agents, available * agentShare)
        let projectHeight = min(projects, max(0, available - reserved))
        return (projectHeight, min(agents, max(0, available - projectHeight)))
    }

    private func needs(_ subviews: Subviews, width: CGFloat?) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        return CGSize(width: width, height: proposal.height ?? needs(subviews, width: width).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let needs = needs(subviews, width: bounds.width)
        guard needs.count == 2 else {
            for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
            return
        }
        let split = Self.heights(available: bounds.height, projects: needs[0], agents: needs[1])
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: split.projects))
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + split.projects), proposal: ProposedViewSize(width: bounds.width, height: split.agents))
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

/// 侧栏分组标题：名称在左、一颗动作在右（项目的"新建项目"、Agent 的"新会话"）。
private struct SidebarHeader<Action: View>: View {
    let title: String
    @ViewBuilder let action: Action
    @Environment(\.palette) private var palette

    var body: some View {
        HStack {
            Text(title).font(Typography.sidebarHeader).foregroundStyle(palette.ink3)
            Spacer()
            action
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.ink2)
        }
        .padding(.leading, SidebarMetrics.column).padding(.trailing, SidebarMetrics.edge + 4)
        .padding(.top, 10).padding(.bottom, 4)
    }
}

/// 侧栏里能去的页，按显示顺序：会话 → 项目（`SidebarOutline`）→ 未分类 → 归档 → 回收站。方向键共用这一份顺序（任务是面板、不是页）。
private struct SidebarPages {
    let outline: SidebarOutline
    let showsBins: Bool

    init(_ catalog: ProjectCatalog, trashCount: Int) {
        outline = SidebarOutline(catalog)
        showsBins = trashCount > 0 || !catalog.projects.isEmpty
    }

    var order: [Route] {
        [.agent] + outline.projects.map { .project($0.id) } + (outline.unfiled > 0 ? [.unfiled] : []) + (showsBins ? [.archive, .trash] : [])
    }
}

/// Cue 下面的去处：任务（开合任务面板，开着时选中；同 ⌘⇧T）、会话（Agent 整页）。单独读当前页与面板开合，换页、开面板时侧栏别处不跟着重算。
private struct PlaceRows: View {
    let select: (Route) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: SidebarMetrics.rowGap) {
            ForEach(SidebarOutline.places, id: \.self) { entry in
                switch entry {
                case .tasks:
                    row(entry, selected: workspace.showsTasks) { workspace.showsTasks.toggle() }
                        .help("任务（⌘⇧T）")
                        .disabled(!workspace.isLibraryReady)
                default:
                    row(entry, selected: workspace.page == entry.route) { select(entry.route) }
                        .help("按项目查看、搜索全部会话")
                }
            }
        }
    }

    private func row(_ entry: SidebarOutline.Entry, selected: Bool, action: @escaping () -> Void) -> some View {
        PageRow(count: entry.count(in: workspace), selected: selected, action: action) {
            Image(entry.icon).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.ink2)
        } title: {
            Text(entry.title)
        }
    }
}

/// 项目区的行：项目与末尾的未分类。只有这里读当前页，每行拿到"选没选中"：换页时只重算选中变了的两行
/// （每行各读当前页时，换一次页项目再多也全部重算）。
private struct ProjectRows: View {
    let pages: SidebarPages
    let catalog: ProjectCatalog
    let now: [UUID: ProjectNow]
    let select: (Route) -> Void
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let current = workspace.page
        VStack(spacing: SidebarMetrics.rowGap) {
            ForEach(pages.outline.projects) { project in
                ProjectRow(
                    project: project, count: catalog.cardCounts[project.id] ?? 0, now: now[project.id], selected: current == .project(project.id),
                    select: select, edit: { workspace.projectForm = .init(project: project) })
                    .equatable()
                    .id(Route.project(project.id))
            }
            if pages.outline.unfiled > 0 {
                PageRow(count: pages.outline.unfiled, selected: current == .unfiled, action: { select(.unfiled) }) {
                    ProjectGlyph(project: nil)
                } title: {
                    Text(CaptureCopy.unfiled)
                }
                .id(Route.unfiled)
            }
        }
    }
}

/// 侧栏里的一行：图标列、名字、行尾的计数；当前页（任务面板开着时的任务）是行的选中底（`RowStyle`）、文字加粗；其余用 85% 的墨，不发灰。
private struct PageRow<Icon: View, Title: View>: View {
    let count: Int
    var height = Spacing.sidebarRow
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let icon: Icon
    @ViewBuilder let title: Title
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                icon.frame(width: Spacing.sidebarIcon)
                title.font(Typography.sidebarRow).fontWeight(selected ? .semibold : .regular)
                    .padding(.leading, SidebarMetrics.titleGap)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)").font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3)
                }
            }
            .foregroundStyle(palette.ink)
            .frame(height: height)
            .contentShape(.rect)
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        // macOS 不把按钮的"已选中"特征交给读屏，当前页另用值念出来
        .accessibilityValue(selected ? "当前页" : "")
    }
}

/// 项目行：名称，下面一行是"此刻"（`ProjectNow`，与书架同一条规则）。行高一直是两行的高度，状态出现、消失时列表不跳；
/// 没有可说的时名称在行里居中，不在上半截空出一行（一列里有的有、有的没有时，名称高低错落）。
/// 只随自己的项目、计数、"此刻"与选中重算：Agent 的状态一变，侧栏的数据整个换新，没变的行不跟着重算。
private struct ProjectRow: View, Equatable {
    let project: Project
    let count: Int
    let now: ProjectNow?
    let selected: Bool
    let select: (Route) -> Void
    let edit: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.project == b.project && a.count == b.count && a.now == b.now && a.selected == b.selected }

    var body: some View {
        PageRow(count: count, height: Spacing.sidebarProjectRow, selected: selected, action: { select(.project(project.id)) }) {
            ProjectGlyph(project: project)
        } title: {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                if now != nil { ProjectNowLine(now: now, font: Typography.sidebarDetail, dot: 6).fontWeight(.regular) }
            }
            .animation(Motion.quick, value: now == nil)
        }
        .contextMenu { ProjectActions(project: project, edit: edit) }
    }
}

/// 底栏里通向一页的图标钮（归档、回收站，有东西时读屏念出条数）：当前页垫选中底色。
private struct FooterPage: View {
    let entry: SidebarOutline.Entry
    var count = 0
    let select: (Route) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private var title: String { count > 0 ? "\(entry.title)，\(count) 项" : entry.title }

    var body: some View {
        let selected = workspace.page == entry.route
        Button { select(entry.route) } label: {
            IconImage(entry.icon, accent: selected ? .lit : .none).font(.system(size: 15))
                .foregroundStyle(selected ? palette.ink : palette.ink2)
                .frame(width: 32, height: 32)
                .background(selected ? palette.selection : .clear, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Agent 区：只回答"现在"——在线的会话（本机桥上的与别的 Mac 同步来的，各家 Agent 一起），与 iOS 的 Agent 页同一种行（`PiSessionRow`）、
/// 同一列（`LiveSessionList`：与菜单栏面板、手机 Cue 页头的面板同一个顺序与折叠），全部列出；区头写一共几个会话、几个子代理在跑（`LiveWorkCount`）；
/// 区的高度与滚动见 `Sidebar`。已结束的不列，全部会话在侧栏上面的"会话"（`AgentPage`）。
/// 点会话在内容区打开它的整页，开在终端里的在线会话右键可跳到所在终端、悬停看出错原文；标题旁的 + 开新会话（这台 Mac 上没有能用的 Agent 时置灰）。
/// 没有在线会话时一行说怎么开始；一个 Agent 都没接入、本机也没有会话时，这里是接入小卡（`AgentConnectCard`）。
private struct PiSection: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var startingSession = false
    @State private var renaming: PiSessionState?

    var body: some View {
        let agents = services.agents
        let detected = AgentKind.allCases.contains { agents.status($0) != nil }
        let connected = AgentKind.allCases.contains { agents.status($0)?.isConnected == true }
        let work = workspace.liveWork, rows = work.rows
        let total = services.liveSessions.total
        if detected || total > 0 {
            VStack(alignment: .leading, spacing: 0) {
                SidebarHeader(title: "Agent") {
                    if !rows.isEmpty { LiveWorkCount(work: work, font: Typography.sidebarDetail) }
                    NewSessionButton(showing: $startingSession)
                }
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isHeader)
                // 没接入：本机的会话看不到，在这一区里接入，别的 Mac 上在线的照样列在下面
                if detected, !connected, services.pi.slots.isEmpty {
                    AgentConnectCard().padding(.horizontal, SidebarMetrics.edge)
                } else if rows.isEmpty {
                    // 现状一行、怎么办一行：同一句挤成两行时"·"会落到行首
                    VStack(alignment: .leading, spacing: 2) {
                        Text("没有运行中的 Agent 会话").foregroundStyle(palette.ink3)
                        Text("在终端里开一个，或点 + 在后台开").foregroundStyle(palette.ink3)
                    }
                    .font(Typography.meta)
                    .padding(.horizontal, SidebarMetrics.column).padding(.vertical, 4)
                }
                if !rows.isEmpty {
                    SidebarScroll {
                        LiveSessionList(sessions: rows, spacing: SidebarMetrics.rowGap) {
                            sessionRow($0)
                        } fold: { count, expanded in
                            PiReloadFold(count: count, expanded: expanded, style: SidebarMetrics.session)
                                .padding(.leading, SidebarMetrics.dotInset)
                                .frame(height: Spacing.sidebarRow)
                        }
                        .padding(.horizontal, SidebarMetrics.column)
                    }
                }
            }
            .renameSession($renaming)
        }
    }

    private func sessionRow(_ session: PiSessionState) -> some View {
        let sessions = services.liveSessions
        return PiSessionRow(
            session: session, project: workspace.catalog?.project(session.projectID), delivery: sessions.deliveries[session.sessionID],
            rename: sessions.renames[session.sessionID], undelivered: sessions.undelivered[session.sessionID] ?? 0, style: SidebarMetrics.session)
            .equatable()
            .padding(.leading, SidebarMetrics.dotInset)
            .frame(height: Spacing.sidebarProjectRow)
            .sessionLink(session.sessionID)
            .modifier(SessionRowMenu(session: session) { renaming = session })
    }
}

/// 侧栏会话行的悬停原文与右键菜单。桥上的那个会话只在这里读（`pi.session(sessionID:)`）：整个 Agent 区读全部会话的话，任一会话一变整区重算。
private struct SessionRowMenu: ViewModifier {
    let session: PiSessionState
    let rename: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    func body(content: Content) -> some View {
        let bridge = services.pi.session(sessionID: session.sessionID)
        content
            .help(bridge?.errorMessage ?? "")
            .contextMenu {
                MarkUnreadButton(session: session)
                if MacDelivery.canRename(session) {
                    Button("重命名…", icon: .rename, action: rename)
                }
                if let bridge, bridge.canJump {
                    Button("跳到所在终端", icon: .terminal) { workspace.jumpToTerminal(bridge.id) }
                }
            }
    }
}

/// 接入 Agent 的小卡：一个图标、一句话说接入了双向能做什么，右边"接入"打开接入面板（`AgentSetupPanel`，检测到还没接入的几家，一键接入）。
/// 没有"不用了"：没接入时本机的会话在这一区里看不到，这张卡就是这一区如实的空态。
private struct AgentConnectCard: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(.extensionNote).font(.system(size: 14)).foregroundStyle(palette.ink2)
                .frame(width: 28, height: 28).background(palette.fill, in: .rect(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("接入 Agent").font(Typography.label).foregroundStyle(palette.ink).lineLimit(1)
                Text("终端和桌面版里的会话与历史也看得到").font(Typography.meta).foregroundStyle(palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button { workspace.showsAgentSetup = true } label: {
                Text("接入").font(Typography.meta.weight(.semibold)).foregroundStyle(palette.onFill)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(palette.signatureFill, in: .capsule).contentShape(.capsule)
            }
            .buttonStyle(PressStyle())
        }
        .padding(10)
        .background(palette.paper, in: .rect(cornerRadius: 12, style: .continuous))
        .help("接入 Pi、Claude Code、Codex 或 OpenCode：在终端和桌面版里开的会话与历史也出现在这里，在 Mac 和手机上看进展、发话、回答提问。CuePad 往它的配置目录写技能（Claude Code、Codex 另写钩子），在设置里关掉即删除。")
        .transition(.opacity)
    }
}

/// 启动时没能完成的事：只在有问题时出现，点开看详情。
private struct StartupIssues: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var showing = false

    var body: some View {
        if !services.startupIssues.isEmpty {
            Button {
                showing.toggle()
            } label: {
                Label { Text("\(services.startupIssues.count) 个启动问题") } icon: { FailureMark() }
                    .font(Typography.meta).foregroundStyle(palette.failure)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(services.startupIssues.enumerated()), id: \.offset) { _, issue in
                        Text(issue.text).font(Typography.meta).textSelection(.enabled)
                    }
                }
                .padding(14).frame(width: 340, alignment: .leading)
            }
        }
    }
}
#endif
