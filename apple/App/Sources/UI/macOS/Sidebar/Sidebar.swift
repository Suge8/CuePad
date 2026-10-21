#if os(macOS)
import CueStore
import SwiftUI

/// 侧栏的结构与 iPhone、iPad 同一份（`SidebarOutline`），这里只管 Mac 的长相，一列到底：最上面 Cue 名片（`CueSidebarCard`）、
/// 下面并排两块磁贴（`PlaceTiles`：任务打开看板页，会话打开会话页）、项目（置顶的在前；Mac 没有书架，全部列出），底栏是归档、回收站与设置。
/// 点哪一处，内容区就是哪一页。在线会话不在侧栏另列：全部在会话页，项目行尾的状态标说这个项目里有没有要看的。
/// 名片与磁贴一直在看得见的地方，只有项目区滚动（方向键与 ⌘1–9 换到的项目滚进可见区）；项目区是普通栈：几十行的量级，行高固定。
struct Sidebar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var trashCount: Int?
    /// 点过侧栏里的页后焦点留在侧栏，方向键才有地方去
    @FocusState private var focused: Bool

    var body: some View {
        // 不用 List：系统选中是灰胶囊，压不过墨色体系；当前页由各处自己画，方向键由 onMoveCommand 接管
        let catalog = workspace.catalog
        let pages = catalog.map(SidebarPages.init)
        VStack(spacing: 0) {
            CueSidebarCard(select: select).padding(.top, 6)
            PlaceTiles(select: select).padding(.horizontal, SidebarMetrics.edge).padding(.top, 10)
            VStack(alignment: .leading, spacing: 0) {
                SidebarHeader(title: "项目") {
                    Button("新建项目", icon: .add) { workspace.projectForm = .init() }.disabled(!workspace.isLibraryReady)
                        .help("新建项目")
                }
                SidebarScroll {
                    if let catalog, let pages {
                        ProjectRows(pages: pages, catalog: catalog, select: select).padding(.horizontal, SidebarMetrics.column)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            footer(trashCount: trashCount ?? 0)
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
        .observing(services.store, into: $trashCount, onError: workspace.fail) { try $0.trashCount() }
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
    private func footer(trashCount: Int) -> some View {
        VStack(spacing: 8) {
            StartupIssues()
            HStack(spacing: 2) {
                FooterPage(entry: .archive, select: select)
                FooterPage(entry: .trash, count: trashCount, select: select)
                Spacer()
                let settings = SidebarOutline.Entry.settings
                Button { SettingsPane.open() } label: {
                    Image(settings.icon).font(.system(size: 15)).foregroundStyle(palette.ink2)
                        .frame(width: SidebarMetrics.footerButton, height: SidebarMetrics.footerButton).contentShape(.circle)
                }
                .buttonStyle(PressStyle(.button))
                .help("设置（⌘,）")
                .accessibilityLabel(settings.title)
            }
            .padding(.horizontal, SidebarMetrics.edge)
            .padding(.bottom, 10)
        }
        .padding(.top, 6)
    }
}

/// 侧栏一行的横向尺寸：侧栏边缘到行的图标列 `column`，行的底（`RowStyle`）向外让出 `RowMetrics.bleed`、离侧栏边缘 `edge`（名片与磁贴也离边缘 `edge`）；
/// 图标列宽 `Spacing.sidebarIcon`，名字离图标列 `titleGap`。
enum SidebarMetrics {
    static let edge: CGFloat = 10
    static let column = edge + RowMetrics.bleed
    static let rowGap: CGFloat = 2
    static let titleGap: CGFloat = 8
    /// 底栏图标钮（归档、回收站、设置）的边长：悬停与选中的底是这么大的圆。
    static let footerButton: CGFloat = 32
}

/// 项目区的滚动：放得下时不弹；下面还有没露出的行时底边淡出一截，看得出能往下滚（只换一层遮盖，不影响排版）。
/// 当前页是区里的一行（打开时、方向键、⌘1–9 换到）且不在可见处时，滚到它出现在可见区中间附近（不给锚点时 macOS 的实测行为），行以页（`Route`）为 id。
private struct SidebarScroll<Content: View>: View {
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
                .onChange(of: workspace.page, initial: true) { _, page in proxy.scrollTo(page) }
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

/// 侧栏分组标题：名称在左、一颗动作在右（项目的"新建项目"）。
private struct SidebarHeader<Action: View>: View {
    let title: String
    @ViewBuilder let action: Action
    @Environment(\.palette) private var palette

    var body: some View {
        HStack {
            Text(title).font(Typography.sidebarHeader).foregroundStyle(palette.ink3)
            Spacer()
            action
                .labelStyle(SidebarHeaderAction())
                .buttonStyle(PressStyle(.button))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.ink2)
        }
        .padding(.leading, SidebarMetrics.column).padding(.trailing, SidebarMetrics.edge)
        .padding(.top, 6)
    }
}

/// 区头的动作钮只露图标，框是 24 的圆：悬停的底（`PressFeedback`）就这么大。
private struct SidebarHeaderAction: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.icon.frame(width: 24, height: 24).contentShape(.circle)
    }
}

/// 侧栏里能去的页，按显示顺序：任务 → 会话 → 项目（`SidebarOutline`）→ 归档 → 回收站。方向键共用这一份顺序。
private struct SidebarPages {
    let outline: SidebarOutline

    init(_ catalog: ProjectCatalog) {
        outline = SidebarOutline(catalog)
    }

    var order: [Route] {
        [.tasks, .agent] + outline.projects.map { .project($0.id) } + [.archive, .trash]
    }
}

/// 名片下面并排的两块磁贴（`SidebarOutline.places`，数是 `Entry.count`，iPad 侧栏同一个）：任务（没做完的；打开看板页，同 ⌘⇧T）、
/// 会话（在线的，有在跑的再写"N 在跑"、靛青，与菜单栏面板区头"在跑"同一档 `LiveWork.running`；点进会话页；
/// 会话哪一行都不在屏上时接力落在这里，`relaySpot(dock:)`）。
/// 单独读当前页与在线会话，换页、会话状态变时侧栏别处不跟着重算。
private struct PlaceTiles: View {
    let select: (Route) -> Void
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SidebarOutline.places, id: \.self) { entry in
                switch entry {
                case .tasks:
                    PlaceTile(entry: entry, count: entry.count(in: workspace), selected: workspace.page == entry.route) { select(entry.route) }
                        .help("任务（⌘⇧T）")
                default:
                    PlaceTile(entry: entry, count: entry.count(in: workspace), running: workspace.liveWork.running, selected: workspace.page == entry.route) {
                        select(entry.route)
                    }
                    .relaySpot(dock: true)
                        .help("按项目查看、搜索全部会话")
                }
            }
        }
    }
}

/// 一块磁贴：纸色圆角，图标左上、数字右上、名字左下（会话的"N 在跑"在右下）；选中（当前页）换成选中底。
private struct PlaceTile: View {
    let entry: SidebarOutline.Entry
    let count: Int
    var running = 0
    let selected: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    private static let corner: CGFloat = 16
    private static let height: CGFloat = 66

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        Button(action: action) {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Image(entry.icon).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.ink2).padding(.top, 4)
                    Spacer(minLength: 4)
                    Text(count, format: .number).font(Typography.sidebarTileCount).foregroundStyle(palette.ink).counting(count)
                }
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title).font(Typography.sidebarRow.weight(selected ? .semibold : .medium)).foregroundStyle(palette.ink)
                    Spacer(minLength: 4)
                    if running > 0 {
                        Text("\(running) 在跑").font(Typography.meta.monospacedDigit()).foregroundStyle(palette.signature).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
            .background(selected ? palette.selection : palette.paper, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(PressStyle(.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(running > 0 ? "\(entry.title)，\(count)，\(running) 个在跑" : "\(entry.title)，\(count)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 项目区的行。只有这里读当前页与在线会话，每行拿到"选没选中"与行尾的状态标：换页时只重算选中变了的两行
/// （每行各读当前页时，换一次页项目再多也全部重算），会话状态变时只重算标变了的行。
private struct ProjectRows: View {
    let pages: SidebarPages
    let catalog: ProjectCatalog
    let select: (Route) -> Void
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let current = workspace.page
        let marks = marks()
        VStack(spacing: SidebarMetrics.rowGap) {
            ForEach(pages.outline.projects) { project in
                ProjectRow(
                    project: project, mark: marks[project.id], selected: current == .project(project.id),
                    select: select, edit: { workspace.projectForm = .init(project: project) })
                    .equatable()
                    .id(Route.project(project.id))
            }
        }
    }

    /// 各项目行尾的状态标：项目的"此刻"（`ProjectNow`，iPad 侧栏与手机书架同一条挑法）挑中的会话，只在要你动手（等你、出错、没能送达，
    /// `PiShown.needsYou`）或在跑（`isRunning`）时画；有新回复、要重载与停着的不画（行上只有一颗标，只给要看的与在动的）。
    private func marks() -> [UUID: ProjectMark] {
        let now = ProjectNow.byProject(pages.outline.projects, sessions: workspace.services.liveSessions.items, tasks: [:], shown: workspace.shown)
        return now.compactMapValues { now in
            guard case .agent(let shown, let session) = now.source, shown.needsYou || shown.isRunning else { return nil }
            return ProjectMark(shown: shown, session: session)
        }
    }
}

/// 项目行尾的状态标：哪个会话、显示成什么。
private struct ProjectMark: Equatable {
    let shown: PiShown
    let session: String
}

/// 侧栏里的一行：图标列、名字、行尾一样东西（状态标或条数）；当前页是行的选中底（`RowStyle`）、文字加粗。
private struct PageRow<Icon: View, Title: View, Trailing: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let icon: Icon
    @ViewBuilder let title: Title
    @ViewBuilder let trailing: Trailing
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                icon.frame(width: Spacing.sidebarIcon)
                title.font(Typography.sidebarRow).fontWeight(selected ? .semibold : .regular).lineLimit(1)
                    .padding(.leading, SidebarMetrics.titleGap)
                Spacer(minLength: 4)
                trailing
            }
            .foregroundStyle(palette.ink)
            .frame(height: Spacing.sidebarRow)
            .contentShape(.rect)
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        // macOS 不把按钮的"已选中"特征交给读屏，当前页另用值念出来
        .accessibilityValue(selected ? "当前页" : "")
    }
}

/// 项目行：图标、名字，行尾项目的状态标（`ProjectMark`，`PiStateDot`；接力落到这个会话时落在标上）。
/// 只随自己的项目、状态标与选中重算：会话状态一变，各行的标重新算一遍，没变的行不跟着重算。
private struct ProjectRow: View, Equatable {
    let project: Project
    let mark: ProjectMark?
    let selected: Bool
    let select: (Route) -> Void
    let edit: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.project == b.project && a.mark == b.mark && a.selected == b.selected }

    var body: some View {
        PageRow(selected: selected, action: { select(.project(project.id)) }) {
            ProjectGlyph(project: project)
        } title: {
            Text(project.name)
        } trailing: {
            if let mark { PiStateDot(shown: mark.shown, size: 7, announces: true).relaySpot(session: mark.session, row: .project) }
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
                .frame(width: SidebarMetrics.footerButton, height: SidebarMetrics.footerButton)
                .background(selected ? palette.selection : .clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle(.button))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
            .buttonStyle(PressStyle(.inline))
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
