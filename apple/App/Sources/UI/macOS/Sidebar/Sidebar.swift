#if os(macOS)
import CueStore
import SwiftUI

/// 侧栏的结构与 iPhone、iPad 同一份（`SidebarOutline`），这里只管 Mac 的长相，一列到底：最上面 Cue 名片（`CueSidebarCard`，要你拍板的事）、
/// 下面一行进展（`ProgressRow`：看板与会话）、项目（全部，置顶的在前；行只有图标与名字），项目区下面一行额度（`SidebarQuota`），底栏是归档、回收站、技能与说明与设置。
/// 点哪一处，内容区就是哪一页。会话不在侧栏列：全部在进展页的会话段；项目行不挂状态标——要看的在 Cue，在动的在进展。
/// 名片与进展一直在看得见的地方，只有项目区滚动（方向键与 ⌘1–9 换到的项目滚进可见区）；项目区是普通栈：几十行的量级，行高固定。
struct Sidebar: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    /// 点过侧栏里的页后焦点留在侧栏，方向键才有地方去
    @FocusState private var focused: Bool

    var body: some View {
        // 不用 List：系统选中是灰胶囊，压不过墨色体系；当前页由各处自己画，方向键由 onMoveCommand 接管
        let catalog = workspace.catalog
        let pages = catalog.map(SidebarPages.init)
        VStack(spacing: 0) {
            CueSidebarCard(select: select).padding(.top, 6)
            ProgressRow(select: select).padding(.horizontal, SidebarMetrics.column).padding(.top, 10)
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
            SidebarQuota().padding(.horizontal, SidebarMetrics.column)
            footer
        }
        .focusable()
        .focused($focused)
        // 选中样式本身就标出了位置，不再套系统焦点环
        .focusEffectDisabled()
        .onMoveCommand { direction in
            guard let order = pages?.order, let page = Self.page(after: workspace.root, in: order, moving: direction) else { return }
            workspace.show(page)
        }
        // 侧栏比桌面深一档：浅色、深色都能看出分层，与内容同一色温
        .background(palette.sidebar)
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

    /// 底栏：启动问题（有才出现），下面一排归档、回收站、技能与说明（有要整理的角上带点）与设置。
    private var footer: some View {
        VStack(spacing: 8) {
            StartupIssues()
            HStack(spacing: 2) {
                FooterPage(entry: .archive, select: select)
                TrashFooterPage(select: select)
                FooterPage(entry: .library, alert: !(workspace.library?.tidies.isEmpty ?? true), select: select)
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

/// 侧栏一行的横向尺寸：侧栏边缘到行的图标列 `column`，行的底（`RowStyle`）向外让出 `RowMetrics.bleed`、离侧栏边缘 `edge`（名片也离边缘 `edge`）；
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
                .onChange(of: workspace.root, initial: true) { _, page in proxy.scrollTo(page) }
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
    let title: LocalizedStringResource
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

/// 区头的动作钮只露图标，框是 24 的圆：悬停的底（`PressFeedback`）就这么大。名字交给 `.iconOnly`：只画图标时读屏照样读得到它。
private struct SidebarHeaderAction: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label { configuration.title } icon: { configuration.icon.frame(width: 24, height: 24).contentShape(.circle) }
            .labelStyle(.iconOnly)
    }
}

/// 侧栏里能去的页，按显示顺序：进展 → 项目（`SidebarOutline`）→ 归档 → 回收站。方向键共用这一份顺序。
private struct SidebarPages {
    let outline: SidebarOutline

    init(_ catalog: ProjectCatalog) {
        outline = SidebarOutline(catalog)
    }

    var order: [Route] {
        [.progress] + outline.projects.map { .project($0.id) } + [.archive, .trash]
    }
}

/// 名片下面一行"进展"（`SidebarOutline.places`，同 ⌘⇧T）：行尾写推进中几件、等你几件（`ProgressTally`，读 Cue 那一份计数）。
/// 会话哪一行都不在屏上时接力落在这一行（`relaySpot(dock:)`）。单独读当前页，换页时侧栏别处不跟着重算。
private struct ProgressRow: View {
    let select: (Route) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let entry = SidebarOutline.Entry.progress
        PageRow(selected: workspace.root == entry.route, action: { select(entry.route) }) {
            Image(entry.icon).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.ink2)
        } title: {
            Text(entry.title)
        } trailing: {
            ProgressTally().font(Typography.meta)
        }
        .relaySpot(dock: true)
        .help("进展：看板与会话（⌘⇧T）")
    }
}

/// 项目区的行。只有这里读当前页，每行拿到"选没选中"：换页时只重算选中变了的两行（每行各读当前页时，换一次页项目再多也全部重算）。
private struct ProjectRows: View {
    let pages: SidebarPages
    let catalog: ProjectCatalog
    let select: (Route) -> Void
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let current = workspace.root
        VStack(spacing: SidebarMetrics.rowGap) {
            ForEach(pages.outline.projects) { project in
                ProjectRow(
                    project: project, selected: current == .project(project.id),
                    select: select, edit: { workspace.projectForm = .init(project: project) })
                    .equatable()
                    .id(Route.project(project.id))
            }
        }
    }
}

/// 侧栏里的一行：图标列、名字、行尾一样东西（进展的计数）；当前页是行的选中底（`RowStyle`）、文字加粗。
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
                    // 去处名不截断，行尾的东西（进展的计数）放不下时自己让步
                    .layoutPriority(1)
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

/// 项目行：图标与名字，只随自己的项目与选中重算。
/// 指针停在行上时记下这个项目（`Workspace.hoveredProject`）：任务看板上别的项目的卡淡下去。行只写不读它，指针划过不重算行。
private struct ProjectRow: View, Equatable {
    let project: Project
    let selected: Bool
    let select: (Route) -> Void
    let edit: () -> Void
    @Environment(Workspace.self) private var workspace

    static func == (a: Self, b: Self) -> Bool { a.project == b.project && a.selected == b.selected }

    var body: some View {
        PageRow(selected: selected, action: { select(.project(project.id)) }) {
            ProjectGlyph(project: project)
        } title: {
            Text(project.shownName)
        } trailing: {
            EmptyView()
        }
        .contextMenu { ProjectActions(project: project, edit: edit) }
        .onHover { workspace.hoverProject(project.id, $0) }
        // 预设悬停只认停着的那一处：别处的同一项目一出现就报"没停着"，会把它清掉
        .presetHover(Binding { false } set: { if $0 { workspace.hoverProject(project.id, true) } })
    }
}

/// 底栏里通向一页的图标钮（归档、回收站，有东西时读屏念出条数）：当前页垫选中底色。
private struct FooterPage: View {
    let entry: SidebarOutline.Entry
    var count = 0
    /// 角上带一颗墨点：这一页里有要你处理的（技能与说明有要整理的），不在那一页时也看得到，不打断。
    var alert = false
    let select: (Route) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private var title: String {
        if alert { return String(localized: "\(entry.title)，有要整理的") }
        return count > 0 ? String(localized: "\(entry.title)，\(count) 项") : entry.title
    }

    var body: some View {
        let selected = workspace.root == entry.route
        Button { select(entry.route) } label: {
            IconImage(entry.icon, accent: selected ? .lit : .none).font(.system(size: 15))
                .foregroundStyle(selected ? palette.ink : palette.ink2)
                .frame(width: SidebarMetrics.footerButton, height: SidebarMetrics.footerButton)
                .background(selected ? palette.selection : .clear, in: .circle)
                .overlay(alignment: .topTrailing) {
                    if alert { Circle().fill(palette.ink).frame(width: CueDot.size, height: CueDot.size).offset(x: -5, y: 5).transition(.opacity) }
                }
                .animation(HandOff.quick, value: alert)
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle(.button))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 回收站那一颗：条数只有它读（读到时只重算这一颗，不重算整个侧栏）。
private struct TrashFooterPage: View {
    let select: (Route) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var count: Int?

    var body: some View {
        FooterPage(entry: .trash, count: count ?? 0, select: select)
            .observing(services.store, into: $count, onError: workspace.fail) { try $0.trashCount() }
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
