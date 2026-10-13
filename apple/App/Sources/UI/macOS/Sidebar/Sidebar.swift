#if os(macOS)
import CuePi
import CueStore
import SwiftUI

/// 侧栏自己读的：回收站条数与各项目最近开始的进行中任务（项目行的"此刻"，`ProjectNow`）。会话在 `LiveSessions`。
nonisolated private struct SidebarData: Sendable, Equatable {
    var trashCount: Int
    var leading: [UUID: [ProjectNow.InProgress]]
}

/// 侧栏从上到下：项目（置顶的在前，末尾未分类）、紧接着 Agent（只列在线的会话，全部列出；其余与历史在"全部"打开的 Agent 整页里），
/// 底栏是归档、回收站与设置。点哪一行，内容区就是哪一页。两区按内容高度分（`SidebarSplit`）：放得下时各占所需、Agent 紧跟项目，
/// 剩下的空白在 Agent 区下面；放不下时项目区保住至少一半可用高度，Agent 区先拿到所需、但最多拿到项目区用剩的高度，
/// 项目区拿剩下的、自己滚动（方向键与 ⌘1–9 换到的项目滚进可见区），Agent 区一直停在看得见的地方；Agent 多到超过这个上限时
/// 在自己的区里滚动，"全部"一行留在区底（项目少时上限就是项目区用剩的全部，不在下面空着）。两区都是普通栈：项目与在线会话是几十行的量级，行高固定。
/// 每一行同一套横向尺寸：图标列（项目图标、会话状态标居中）同宽，项目名、会话名与"全部"落在同一条竖线上。
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
            SidebarSplit {
                if let data, let catalog, let pages {
                    projects(pages, catalog, data: data)
                    let sessions = services.liveSessions
                    PiSection(
                        recorded: sessions.live.map(\.listed), deliveries: sessions.deliveries, renames: sessions.renames,
                        undelivered: sessions.undelivered, total: sessions.total, select: select)
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
            SidebarData(trashCount: try store.trashCount(), leading: try TaskBoard.leading(from: store))
        }
    }

    private func projects(_ pages: SidebarPages, _ catalog: ProjectCatalog, data: SidebarData) -> some View {
        // 各项目的"此刻"在数据变化时算一次，行只拿结果；在线会话读到前先留空白（`ProjectNow.byProject`）
        let now = ProjectNow.byProject(catalog.projects, sessions: services.liveSessions.items, tasks: data.leading, shown: services.settings.shown)
        return VStack(alignment: .leading, spacing: 0) {
            SidebarHeader(title: "项目") {
                Button("新建项目", systemImage: "plus") { workspace.projectForm = .init() }.disabled(!workspace.isLibraryReady)
            }
            SidebarScroll(revealsPage: true) {
                ProjectRows(pages: pages, catalog: catalog, now: now, select: select).padding(.horizontal, SidebarMetrics.edge)
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
                    FooterPage(page: .archive, title: "归档", systemImage: "archivebox", select: select)
                    FooterPage(page: .trash, title: trashCount > 0 ? "回收站，\(trashCount) 项" : "回收站", systemImage: "trash", select: select)
                }
                Spacer()
                Button("设置", systemImage: "gearshape") { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) }
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

/// 侧栏一行的横向尺寸（项目行、未分类、会话行、"全部"共用）：侧栏边缘到行的选中底 `edge`，选中底到图标列 `inset`，
/// 图标列宽 `Spacing.sidebarIcon`；会话的状态标（外框是点径的 1.8 倍，`PiStateDot`）在图标列里居中，名字离它 `dot + 2`
/// （`PiSessionRow` 的排法），项目名离图标列 `titleGap`，两种名字就落在同一条竖线上。
private enum SidebarMetrics {
    static let edge: CGFloat = 10
    static let inset: CGFloat = 8
    static let rowGap: CGFloat = 2
    static let dot: CGFloat = 6
    private static let dotBox = dot * 1.8
    static let dotInset = inset + (Spacing.sidebarIcon - dotBox) / 2
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
        .padding(.leading, SidebarMetrics.edge + SidebarMetrics.inset).padding(.trailing, SidebarMetrics.edge + 4)
        .padding(.top, 10).padding(.bottom, 4)
    }
}

/// 侧栏里能去的页，按显示顺序：项目（置顶在前，`store.projects()` 的顺序）→ 未分类 → 归档 → 回收站。方向键共用这一份顺序。
private struct SidebarPages {
    let projects: [Project]
    let unfiledCount: Int
    let showsBins: Bool

    init(_ catalog: ProjectCatalog, trashCount: Int) {
        projects = catalog.projects
        unfiledCount = catalog.cardCounts[nil] ?? 0
        showsBins = trashCount > 0 || !catalog.projects.isEmpty
    }

    var order: [Route] {
        projects.map { .project($0.id) } + (unfiledCount > 0 ? [.unfiled] : []) + (showsBins ? [.archive, .trash] : [])
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
            ForEach(pages.projects) { project in
                ProjectRow(
                    project: project, count: catalog.cardCounts[project.id] ?? 0, now: now[project.id], selected: current == .project(project.id),
                    select: select, edit: { workspace.projectForm = .init(project: project) })
                    .equatable()
                    .id(Route.project(project.id))
            }
            if pages.unfiledCount > 0 {
                PageRow(page: .unfiled, count: pages.unfiledCount, selected: current == .unfiled, select: select) {
                    ProjectGlyph(project: nil)
                } title: {
                    Text(CaptureCopy.unfiled)
                }
                .id(Route.unfiled)
            }
        }
    }
}

/// 侧栏里通向一页的一行：图标列、名字、行尾的计数；当前页垫选中底色、文字加粗；其余用 85% 的墨，不发灰。
private struct PageRow<Icon: View, Title: View>: View {
    let page: Route
    let count: Int
    var height = Spacing.sidebarRow
    let selected: Bool
    let select: (Route) -> Void
    @ViewBuilder let icon: Icon
    @ViewBuilder let title: Title
    @Environment(\.palette) private var palette

    private static var restingOpacity: Double { 0.85 }

    var body: some View {
        Button { select(page) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                icon.frame(width: Spacing.sidebarIcon)
                title.font(Typography.sidebarRow).fontWeight(selected ? .semibold : .regular)
                    .padding(.leading, SidebarMetrics.titleGap)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)").font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3)
                }
            }
            .foregroundStyle(selected ? palette.ink : palette.ink.opacity(Self.restingOpacity))
            .padding(.horizontal, SidebarMetrics.inset)
            .frame(height: height)
            .background(selected ? palette.selection : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
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
        PageRow(page: .project(project.id), count: count, height: Spacing.sidebarProjectRow, selected: selected, select: select) {
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

/// 底栏里通向一页的图标钮（归档、回收站）：当前页垫选中底色。
private struct FooterPage: View {
    let page: Route
    let title: String
    let systemImage: String
    let select: (Route) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let selected = workspace.page == page
        Button { select(page) } label: {
            Image(systemName: systemImage).font(.system(size: 15))
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

/// Agent 区：只回答"现在"——在线的会话（本机桥上的与别的 Mac 同步来的），与 iOS 的 Agent 页同一种行（`PiSessionRow`）、
/// 同一个顺序（`liveRows`，要你注意的在前），全部列出（两个以上需要 /reload 的合成一行，`PiNowRow`，点开再列）；
/// 区的高度与滚动见 `Sidebar`。已结束的不列，"全部"打开 Agent 整页列表（`AgentPage`，看着它时这一行选中，区里照常列会话）。
/// 点会话在内容区打开它的整页，在线会话右键可跳到所在终端、悬停看出错原文；标题旁的 + 开新会话。没有在线会话时一行说怎么开始。
/// 没装 Pi 或版本太低时，这里是一行引导，点开说明怎么装。
private struct PiSection: View {
    let recorded: [PiSessionState]
    let deliveries: [String: DeliveryRequest]
    let renames: [String: DeliveryRequest]
    let undelivered: [String: Int]
    let total: Int
    let select: (Route) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var startingSession = false
    @State private var renaming: PiSessionState?
    @State private var reloadOpen = false

    var body: some View {
        let status = services.piIntegration.status
        let live = services.pi.sessions
        let rows = PiSessionState.liveRows(
            live: live.map {
                PiSessionState.live(
                    $0, hostID: services.hostID, projectID: workspace.sendState.projects[$0.id], recap: services.liveSessions.recaps[$0.sessionID])
            },
            recorded: recorded, deliveries: deliveries)
        if let installation = status?.pi, !installation.isSupported {
            VStack(alignment: .leading, spacing: 0) {
                SidebarHeader(title: "Agent") { EmptyView() }
                PiSetupRow(installation: installation).padding(.horizontal, SidebarMetrics.edge + SidebarMetrics.inset)
            }
        } else if status != nil || total > 0 {
            VStack(alignment: .leading, spacing: 0) {
                SidebarHeader(title: "Agent") { NewSessionButton(showing: $startingSession) }
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isHeader)
                // 扩展没装（第一次问，或拒绝过而本机的会话因此看不到）：在这一区里就地装，别的 Mac 上在线的照样列在下面
                if let connect = PiConnect(manager: services.piIntegration, declined: services.settings.piExtensionDeclined, hasLocal: !live.isEmpty) {
                    PiConnectCard(kind: connect).padding(.horizontal, SidebarMetrics.edge)
                } else if rows.isEmpty {
                    // 现状一行、怎么办一行：同一句挤成两行时"·"会落到行首
                    VStack(alignment: .leading, spacing: 2) {
                        Text("没有运行中的 Agent 会话").foregroundStyle(palette.ink3)
                        Text("在终端运行 pi 开始").foregroundStyle(palette.ink3)
                    }
                    .font(Typography.meta)
                    .padding(.horizontal, SidebarMetrics.edge + SidebarMetrics.inset).padding(.vertical, 4)
                }
                if !rows.isEmpty {
                    SidebarScroll {
                        // 在线的按会话 id 区分：状态变化时那一行不被重建
                        VStack(spacing: SidebarMetrics.rowGap) {
                            ForEach(PiNowRow.rows(rows, state: { $0 })) { nowRow in
                                switch nowRow {
                                case .session(let session): sessionRow(session, live: live)
                                case .reload(let sessions):
                                    PiReloadFold(count: sessions.count, expanded: $reloadOpen, style: SidebarMetrics.session)
                                        .padding(.leading, SidebarMetrics.dotInset).padding(.trailing, SidebarMetrics.inset)
                                        .frame(height: Spacing.sidebarRow)
                                    if reloadOpen { ForEach(sessions) { sessionRow($0, live: live) } }
                                }
                            }
                        }
                        .padding(.horizontal, SidebarMetrics.edge)
                    }
                }
                AllSessionsRow(total: total, select: select)
                    .padding(.horizontal, SidebarMetrics.edge).padding(.top, SidebarMetrics.rowGap)
            }
            .renameSession($renaming)
        }
    }

    private func sessionRow(_ session: PiSessionState, live: [CuePi.PiSession]) -> some View {
        let bridge = live.first { $0.sessionID == session.sessionID }
        return PiSessionRow(
            session: session, project: workspace.catalog?.project(session.projectID), delivery: deliveries[session.sessionID],
            rename: renames[session.sessionID], undelivered: undelivered[session.sessionID] ?? 0, style: SidebarMetrics.session)
            .equatable()
            .padding(.leading, SidebarMetrics.dotInset).padding(.trailing, SidebarMetrics.inset)
            .frame(height: Spacing.sidebarProjectRow)
            .sessionLink(session.sessionID)
            .help(bridge?.errorMessage ?? "")
            .contextMenu {
                MarkUnreadButton(session: session)
                if MacDelivery.canRename(session) {
                    Button("重命名…", systemImage: "pencil") { renaming = session }
                }
                if let bridge, !bridge.hosted {
                    Button("跳到所在终端", systemImage: "terminal") { workspace.jumpToTerminal(bridge.id) }
                }
            }
    }
}

extension PiSessionState {
    /// "现在"的会话行（侧栏 Agent 区、项目页的 Agent 栏）：本机在线的（桥上实时，`live`）与同步记录里没结束的（别的 Mac 上的）
    /// 一起按要你注意的先后；同一个会话只出现一次（本机实时优先）。已结束的不列，历史在 Agent 整页里。`recorded` 是会话列表查询的一页。
    static func liveRows(
        live: [PiSessionState], recorded: [PiSessionState], deliveries: [String: DeliveryRequest] = [:]
    ) -> [PiSessionState] {
        let shown = Set(live.map(\.sessionID))
        let others = recorded.filter { !shown.contains($0.sessionID) && $0.state != .known(.ended) }
        return inListOrder(live + others, deliveries: deliveries)
    }
}

/// Agent 区底下的"全部"：打开 Agent 整页。单独读当前页，换页时 Agent 区的会话行不跟着重算。
private struct AllSessionsRow: View {
    let total: Int
    let select: (Route) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        PageRow(page: .agent, count: total, selected: workspace.page == .agent, select: select) {
            Image(systemName: "rectangle.stack").font(.system(size: 13, weight: .medium)).foregroundStyle(palette.ink2)
        } title: {
            Text("全部")
        }
        .help("按项目查看、搜索全部会话")
    }
}

/// 没装 Pi 或版本太低：侧栏 Pi 分组里的一行引导，点开是安装说明（`PiSetupGuide`）。
private struct PiSetupRow: View {
    let installation: PiInstallation
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(installation == .notFound ? "安装 Pi" : "升级 Pi").foregroundStyle(.primary)
                    Text("把灵感和任务直接发进 Pi").font(Typography.meta).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "terminal")
            }
        }
        .buttonStyle(PressStyle())
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            PiSetupGuide(installation: installation).padding(16).frame(width: 360)
        }
    }
}

/// Agent 区里装 CuePad 扩展的那一块要怎么说：第一次检测到 Pi 而扩展没装时问一次；拒绝过、本机的会话因此看不到时只留一行就地安装。
private enum PiConnect {
    case ask, declined

    init?(manager: PiIntegrationManager, declined: Bool, hasLocal: Bool) {
        if manager.needsConsent { self = .ask; return }
        guard declined, !hasLocal, let status = manager.status, status.pi.isSupported, status.file != .current else { return nil }
        self = .declined
    }
}

/// 装 CuePad 扩展的小卡（扩展与技能一起装，见 `PiIntegrationManager`）：一个图标、一句话说装了能做什么，右边"安装"；第一次问时多一颗"不用了"。
private struct PiConnectCard: View {
    let kind: PiConnect
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var installing = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "puzzlepiece.extension").font(.system(size: 14)).foregroundStyle(palette.ink2)
                .frame(width: 28, height: 28).background(palette.fill, in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(kind == .ask ? "连接 Pi" : "装上 Pi 扩展").font(Typography.label).foregroundStyle(palette.ink).lineLimit(1)
                Text(kind == .ask ? "看会话、交任务" : "看到本机会话").font(Typography.meta).foregroundStyle(palette.ink3).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(spacing: 4) {
                Button(action: install) {
                    Text(installing ? "安装中" : "安装").font(Typography.meta.weight(.semibold)).foregroundStyle(palette.onSignature)
                        .padding(.horizontal, 12).frame(height: 24)
                        .background(palette.signatureFill, in: .capsule).contentShape(.capsule)
                }
                .buttonStyle(PressStyle())
                .disabled(installing)
                if kind == .ask {
                    Button("不用了") {
                        withAnimation(Motion.quick) { services.piIntegration.decline() }
                    }
                    .buttonStyle(.plain).font(Typography.meta).foregroundStyle(palette.ink3)
                }
            }
        }
        .padding(10)
        .background(palette.paper, in: .rect(cornerRadius: 12, style: .continuous))
        .help("扩展让 CuePad 看到 Pi 会话的实时状态、把话发进会话；技能让 Agent 能把页面和截图发到手机上看。会写入 Pi 目录下的 extensions 与 skills。")
        .transition(.opacity)
    }

    private func install() {
        installing = true
        let manager = services.piIntegration
        Task {
            defer { installing = false }
            do {
                try await manager.install()
                workspace.say("已安装；已在运行的 Pi 会话重启后生效")
            } catch {
                workspace.fail(error)
            }
        }
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
                Label("\(services.startupIssues.count) 个启动问题", systemImage: "exclamationmark.triangle")
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
