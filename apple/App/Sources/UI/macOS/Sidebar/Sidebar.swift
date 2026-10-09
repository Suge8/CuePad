#if os(macOS)
import CuePi
import CueStore
import SwiftUI

nonisolated private struct SidebarData: Sendable {
    var trashCount: Int
    /// 同步记录里在线的会话（含别的 Mac 上的）与全部会话数。
    var live: [PiSessionState]
    var sessionTotal: Int
    /// 发给在线会话的最近一条投送请求与最近一条改名（Pi 的会话 id →）。
    var deliveries: [String: DeliveryRequest]
    var renames: [String: DeliveryRequest]
    /// 项目行的"此刻"（`ProjectNow`）读的：此刻有事的会话（`PiSessionQuery.current`）与各项目最近开始的进行中任务。
    var current: [PiSessionListItem]
    var leading: [UUID: [ProjectNow.InProgress]]
}

/// 侧栏两区：项目（置顶的在前，末尾未分类；项目多时在上面滚动）与 Agent（固定在底部、只列在线的会话，最多露出几行，
/// 其余与历史在"全部会话"里）；归档、回收站与设置在底栏。点哪一行，内容区就是哪一页。
struct Sidebar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: SidebarData?
    @State private var creating = false
    @State private var renaming: Project?
    /// 点过侧栏里的页后焦点留在侧栏，方向键才有地方去
    @FocusState private var focused: Bool

    private static let footerFade: CGFloat = 16

    var body: some View {
        // 不用 List 的选中：系统选中是灰胶囊，压不过墨色体系；当前页由 PageRow 自己画，方向键由 onMoveCommand 接管
        let catalog = workspace.catalog
        let pages = data.flatMap { data in catalog.map { SidebarPages($0, trashCount: data.trashCount) } }
        List {
            if let data, let catalog, let pages {
                // 各项目的"此刻"在数据变化时算一次，行只拿结果
                let now = ProjectNow.byProject(catalog.projects, sessions: data.current, tasks: data.leading, shown: services.settings.shown)
                Section {
                    ForEach(pages.projects) { row($0, catalog, now: now[$0.id]) }
                    if pages.inboxCount > 0 {
                        PageRow(page: .inbox, count: pages.inboxCount, select: select) {
                            Label("未分类", systemImage: "tray")
                        }
                    }
                } header: {
                    SidebarHeader(title: "项目") {
                        Button("新建项目", systemImage: "plus") { creating = true }.disabled(!workspace.isLibraryReady)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, Spacing.sidebarRow)
        .focusable()
        .focused($focused)
        // 选中样式本身就标出了位置，不再套系统焦点环
        .focusEffectDisabled()
        .onMoveCommand { direction in
            guard let order = pages?.order, let page = Self.page(after: workspace.page, in: order, moving: direction) else { return }
            workspace.show(page)
        }
        // 侧栏比桌面深一档：浅色、深色都能看出分层，与内容同一色温
        .scrollContentBackground(.hidden)
        .background(palette.sidebar)
        .safeAreaInset(edge: .bottom) {
            // Agent 区不随项目列表滚动：项目再多，要你注意的会话也一直露在侧栏里
            VStack(spacing: 0) {
                if let data {
                    PiSection(recorded: data.live, deliveries: data.deliveries, renames: data.renames, total: data.sessionTotal)
                        .padding(.horizontal, 10)
                }
                footer(showsBins: pages?.showsBins ?? false, trashCount: data?.trashCount ?? 0)
            }
            // 底下是实底：列表滚到这里先淡掉，不压在会话与按钮上
            .background(palette.sidebar.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) {
                LinearGradient(colors: [palette.sidebar.opacity(0), palette.sidebar], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.footerFade)
                    .offset(y: -Self.footerFade)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .sheet(isPresented: $creating) { ProjectForm(project: nil) }
        .sheet(item: $renaming) { ProjectForm(project: $0) }
        .observing(services.store, [.projects, .cards, .piSessionStates, .deliveryRequests], into: $data, onError: workspace.fail) { store in
            let live = try store.piSessionPage(.live)
            return SidebarData(
                trashCount: try store.trashedProjects().count + store.trashedCards().count,
                live: live.items.map(\.listed), sessionTotal: try store.piSessionPage(PiSessionQuery(limit: 0)).total,
                deliveries: Dictionary(live.items.compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first },
                renames: Dictionary(live.items.compactMap { item in item.rename.map { (item.state.sessionID, $0) } }) { first, _ in first },
                current: try store.piSessionPage(.current).items, leading: try TaskBoard.leading(from: store))
        }
    }

    private func select(_ page: Workspace.Page) {
        workspace.show(page)
        focused = true
    }

    /// 方向键：上一页 / 下一页，到头不循环；当前页不在侧栏里时从第一页开始。
    private static func page(after current: Workspace.Page, in order: [Workspace.Page], moving direction: MoveCommandDirection) -> Workspace.Page? {
        guard let index = order.firstIndex(of: current) else { return order.first }
        switch direction {
        case .up: return index > order.startIndex ? order[index - 1] : nil
        case .down: return index + 1 < order.endIndex ? order[index + 1] : nil
        default: return nil
        }
    }

    /// 项目行：名称，下面一行是"此刻"（`ProjectNow`，与书架同一条规则）。行高一直是两行的高度，状态出现、消失时列表不跳；
    /// 没有可说的时名称在行里居中，不在上半截空出一行（一列里有的有、有的没有时，名称高低错落）。
    private func row(_ project: Project, _ catalog: ProjectCatalog, now: ProjectNow?) -> some View {
        PageRow(page: .project(project.id), count: catalog.cardCounts[project.id] ?? 0, height: Spacing.sidebarProjectRow, select: select) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                    if now != nil { ProjectNowLine(now: now, font: Typography.sidebarDetail, dot: 6).fontWeight(.regular) }
                }
                .animation(Motion.quick, value: now == nil)
            } icon: {
                ProjectGlyph(project: project)
            }
        }
        .contextMenu { ProjectActions(project: project, edit: { renaming = project }) }
    }

    /// 底栏：连接 Pi 的询问与启动问题（有才出现），下面一排归档、回收站与设置。
    private func footer(showsBins: Bool, trashCount: Int) -> some View {
        VStack(spacing: 8) {
            ExtensionConsent()
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
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .padding(.top, 6)
    }
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
        .padding(.top, 10)
    }
}

/// 侧栏里能去的页，按显示顺序：项目（置顶在前，`store.projects()` 的顺序）→ 未分类 → 归档 → 回收站。方向键共用这一份顺序。
private struct SidebarPages {
    let projects: [Project]
    let inboxCount: Int
    let showsBins: Bool

    init(_ catalog: ProjectCatalog, trashCount: Int) {
        projects = catalog.projects
        inboxCount = catalog.cardCounts[nil] ?? 0
        showsBins = trashCount > 0 || !catalog.projects.isEmpty
    }

    var order: [Workspace.Page] {
        projects.map { .project($0.id) } + (inboxCount > 0 ? [.inbox] : []) + (showsBins ? [.archive, .trash] : [])
    }
}

/// 侧栏里通向一页的一行：当前页垫选中底色、文字加粗；其余用 85% 的墨，不发灰。
private struct PageRow<Title: View>: View {
    let page: Workspace.Page
    let count: Int
    /// 有时代替计数写在行尾（"还有 N 个"）。
    var note: String?
    var height = Spacing.sidebarRow
    let select: (Workspace.Page) -> Void
    @ViewBuilder let title: Title
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private static var restingOpacity: Double { 0.85 }

    var body: some View {
        let selected = workspace.page == page
        Button { select(page) } label: {
            HStack(spacing: 6) {
                title.font(Typography.sidebarRow).fontWeight(selected ? .semibold : .regular)
                Spacer(minLength: 4)
                if let note {
                    Text(note).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink2)
                } else if count > 0 {
                    Text("\(count)").font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3)
                }
            }
            .foregroundStyle(selected ? palette.ink : palette.ink.opacity(Self.restingOpacity))
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(selected ? palette.selection : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .listRowInsets(EdgeInsets(top: 1, leading: 2, bottom: 1, trailing: 2))
        .accessibilityAddTraits(selected ? .isSelected : [])
        // macOS 不把按钮的"已选中"特征交给读屏，当前页另用值念出来
        .accessibilityValue(selected ? "当前页" : "")
    }
}

/// 底栏里通向一页的图标钮（归档、回收站）：当前页垫选中底色。
private struct FooterPage: View {
    let page: Workspace.Page
    let title: String
    let systemImage: String
    let select: (Workspace.Page) -> Void
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
        .buttonStyle(PressStyle(scale: Press.button))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Agent 区：只回答"现在"——在线的会话（本机桥上的与别的 Mac 同步来的），与 iOS 的 Agent 页同一种行（`PiSessionRow`）、
/// 同一个顺序（`liveRows`，要你注意的在前）；固定在侧栏底部，最多露出 `SidebarAgents.limit` 行，多的写在"全部会话"行尾"还有 N 个"；
/// 已结束的不列，"全部会话"打开 Agent 整页列表（`AgentPage`）。点会话在内容区打开它的整页，
/// 在线会话右键可跳到所在终端、悬停看出错原文；标题旁的 + 开新会话。没有在线会话时一行说怎么开始。
/// 没装 Pi 或版本太低时，这里是一行引导，点开说明怎么装。
private struct PiSection: View {
    let recorded: [PiSessionState]
    let deliveries: [String: DeliveryRequest]
    let renames: [String: DeliveryRequest]
    let total: Int
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
                    $0, hostID: services.hostID, projectID: workspace.sessionProjects[$0.id], recap: workspace.sessionRecaps[$0.sessionID])
            },
            recorded: recorded, deliveries: deliveries)
        let agents = SidebarAgents(rows: rows, page: workspace.page)
        if workspace.page == .agent {
            PageRow(page: .agent, count: total, select: { workspace.show($0) }) {
                Label("全部会话", systemImage: "rectangle.stack")
            }
        } else if let installation = status?.pi, !installation.isSupported {
            VStack(alignment: .leading, spacing: 2) {
                SidebarHeader(title: "Agent") { EmptyView() }
                PiSetupRow(installation: installation)
            }
        } else if status != nil || total > 0 {
            VStack(alignment: .leading, spacing: 2) {
                SidebarHeader(title: "Agent") { NewSessionButton(showing: $startingSession) }
                    .padding(.horizontal, 4)
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isHeader)
                // 拒绝过安装扩展时本机的在线会话不会出现：说清去哪装（别的 Mac 上在线的照样列在下面）
                let declined = status?.file != .current && services.settings.piExtensionDeclined && live.isEmpty
                if declined || rows.isEmpty {
                    // 现状一行、怎么办一行：同一句挤成两行时"·"会落到行首
                    VStack(alignment: .leading, spacing: 2) {
                        Text(declined ? "没装扩展，看不到本机在线的会话" : "没有运行中的 Agent 会话").foregroundStyle(palette.ink3)
                        if declined {
                            Button("在设置 › Pi 里安装") { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) }
                                .buttonStyle(.plain).foregroundStyle(palette.ink2)
                        } else {
                            Text("在终端运行 pi 开始").foregroundStyle(palette.ink3)
                        }
                    }
                    .font(Typography.meta)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                }
                // 在线的按会话 id 区分：状态变化时那一行不被重建。两个以上需要 /reload 的合成一行（`PiNowRow`），点开再列
                ForEach(agents.displayRows) { nowRow in
                    switch nowRow {
                    case .session(let session): sessionRow(session, live: live)
                    case .reload(let sessions):
                        PiReloadFold(count: sessions.count, expanded: $reloadOpen).padding(.horizontal, 10)
                        if reloadOpen { ForEach(sessions) { sessionRow($0, live: live) } }
                    }
                }
                if total > 0 {
                    PageRow(page: .agent, count: total, note: agents.overflow > 0 ? "还有 \(agents.overflow) 个" : nil, select: { workspace.show($0) }) {
                        Label("全部会话", systemImage: "rectangle.stack")
                    }
                    .help("按项目查看、搜索全部会话")
                }
            }
            .renameSession($renaming)
        }
    }

    private func sessionRow(_ session: PiSessionState, live: [CuePi.PiSession]) -> some View {
        let bridge = live.first { $0.sessionID == session.sessionID }
        return PiSessionRow(
            session: session, project: workspace.catalog?.project(session.projectID), delivery: deliveries[session.sessionID],
            rename: renames[session.sessionID])
            .padding(.horizontal, 8).padding(.vertical, 5)
            .sessionLink(session.sessionID)
            .help(bridge?.state.errorMessage ?? "")
            .contextMenu {
                if MacDelivery.canRename(session) {
                    Button("重命名…", systemImage: "pencil") { renaming = session }
                }
                if let bridge, !bridge.hosted {
                    Button("跳到所在终端", systemImage: "terminal") { workspace.jumpToTerminal(bridge.id) }
                }
            }
    }
}

/// 侧栏 Agent 区露出的行：前 `limit` 行（`liveRows` 的顺序，要你注意的在前），其余只算个数。
/// 行数有上限，区域才能固定在侧栏底部、不被项目挤到折线以下。正看 Agent 整页时不重复列会话，只留"全部会话"。
struct SidebarAgents {
    static let limit = 3
    let visible: [PiSessionState]
    let overflow: Int

    init(rows: [PiSessionState], page: Workspace.Page) {
        visible = page == .agent ? [] : Array(rows.prefix(Self.limit))
        overflow = page == .agent ? 0 : max(0, rows.count - Self.limit)
    }

    /// 多个 /reload 会话通常合成一行；如果这样会少于三行，侧栏宁可暂时逐个列出它们，保证"现在"真的露出三行。
    var displayRows: [PiNowRow<PiSessionState>] {
        let collapsed = PiNowRow.rows(visible, state: { $0 })
        return collapsed.count >= Self.limit ? collapsed : visible.map(PiNowRow.session)
    }
}

extension PiSessionState {
    /// "现在"的会话行（侧栏 Agent 区、项目页的 Agent 栏）：本机在线的（桥上实时，`live`）与同步记录里没结束的（别的 Mac 上的）
    /// 一起按要你注意的先后；同一个会话只出现一次（本机实时优先）。已结束的不列，历史在"全部会话"里。`recorded` 是会话列表查询的一页。
    static func liveRows(
        live: [PiSessionState], recorded: [PiSessionState], deliveries: [String: DeliveryRequest] = [:]
    ) -> [PiSessionState] {
        let shown = Set(live.map(\.sessionID))
        let others = recorded.filter { !shown.contains($0.sessionID) && $0.state != .known(.ended) }
        return inListOrder(live + others, deliveries: deliveries)
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
        .buttonStyle(PressStyle(scale: 0.98))
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            PiSetupGuide(installation: installation).padding(16).frame(width: 360)
        }
    }
}

/// 首次检测到 Pi 而扩展与技能未装时征求同意；拒绝后不再询问、两样都不装。
private struct ExtensionConsent: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var installing = false

    var body: some View {
        if services.piIntegration.needsConsent {
            VStack(alignment: .leading, spacing: 8) {
                Label("连接 Pi", systemImage: "terminal").font(Typography.label)
                Text("安装 CuePad 扩展后，这里能看到 Pi 会话的实时状态，并能把提示词直接发进会话；还会装一个小技能，让 Agent 能把页面和截图发到手机上看。会写入 Pi 目录下的 extensions 与 skills。")
                    .font(Typography.meta).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("不用了") {
                        withAnimation(.easeOut(duration: 0.15)) { services.piIntegration.decline() }
                        workspace.say("之后可在 设置 › Pi 里安装")
                    }
                    Button("安装") { install() }.buttonStyle(.borderedProminent).disabled(installing)
                }
                .controlSize(.small)
            }
            .padding(12)
            .paper(radius: 12)
            .padding(.horizontal, 10)
            .transition(.opacity)
        }
    }

    private func install() {
        installing = true
        Task {
            defer { installing = false }
            do {
                try await services.piIntegration.install()
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
