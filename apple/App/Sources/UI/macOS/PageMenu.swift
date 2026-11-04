#if os(macOS)
import CueStore
import SwiftUI

/// 工具栏右上的"⋯"：当前页的操作，只放页上已有的动作；没有可放的页（归档）钮停用、同系统停用的控件那样变淡（与可用时一个样子，点了没反应像是坏了）。
/// 编辑页开着（`Workspace.openCard`，盖在项目页上）时是这张卡的操作，编辑页里不另放"⋯"：卡由这里按 `openCard` 自己从库里读（`observing`），
/// 没读到时钮停用。
/// 菜单项不按页面数据置灰：菜单拿不到页面读的库，抄一份过来就是第二个事实源；没有可归档、可清空的时候点了什么也不发生。
/// 它排在右边那一项里（`TrailingSlots`），圆钮的玻璃自己画，与"收起"同一种做法。
/// 左沿报给看板段的列头（`MacPages.moreEdge`）：它下面的列头到它前面止。
/// 钮在每一页都在、只随页面置灰：工具栏项的尺寸一变整条工具栏重排（一次进出会话页约占动作后主线程 CPU 的三分之一到一半）。
/// 会话页的钮跟着页面就在，菜单里的会话项等页面交来的值、并晚于标题两帧（`showsMenu`）。
struct PageMenuSlot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    /// 编辑页开着的那张卡（外层 nil 是还没读到；不是编辑页时读出的是 nil）。
    @State private var opened: Card??

    private enum Content: Equatable {
        /// 会话页；页面还没交来值时是 nil。
        case session(SessionHeader.State?)
        /// 编辑页开着：这张卡的操作；还没读到时是 nil。
        case card(Card?)
        case project(UUID)
        case cue
        case progress
        case trash
        case none

        var help: LocalizedStringResource {
            switch self {
            case .session: "完成或绑定任务、重命名、跳到终端、结束会话"
            case .card: "置顶、移到项目、复制、归档、删除"
            case .project: "选择灵感、看这个项目的会话、项目操作"
            case .cue: "启用或停用 Cue、运行情况、设置"
            case .progress: "新任务、新会话、项目范围、搜索、归档做完的、接入 Agent"
            case .trash: "清空回收站"
            case .none: "这一页没有更多操作"
            }
        }
    }

    private var content: Content {
        if let id = workspace.openCard { return .card((opened ?? nil).flatMap { $0.id == id ? $0 : nil }) }
        return switch workspace.root {
        case .session: .session(workspace.shownSessionHeader)
        case .project(let id): .project(id)
        case .cue: .cue
        case .progress: .progress
        case .trash: .trash
        default: .none
        }
    }

    var body: some View {
        let content = content
        Menu {
            Group { items(content) }
                // macOS 27 起菜单默认藏起菜单项的图片：标明图标与字都画（docs/ui.md）
                .labelStyle(.titleAndIcon)
        } label: {
            // 看板段选了项目范围（范围收在这里）：钮角上带这个项目的小图形，一眼看得出只在看一个项目
            Image(.more).overlay(alignment: .topTrailing) {
                if content == .progress, workspace.progressPane == .board, let project = workspace.catalog?.project(workspace.scopedProject) {
                    ProjectGlyph(project: project, size: 10).offset(x: 12, y: -10)
                }
            }
        }
        .menuStyle(.button).menuIndicator(.hidden)
        .buttonStyle(ControlButtonStyle(kind: .circular))
        .fixedSize()
        .background { WindowFrame(\.minX) { workspace.pages.moreEdge = $0 } }
        .padding(.leading, Spacing.toolbarGap)
        .disabled(content == .none || content == .card(nil))
        .help(content.help)
        .accessibilityLabel("更多")
        .observing(services.store, id: workspace.openCard, into: $opened, onError: workspace.fail) { [id = workspace.openCard] store in
            try id.flatMap { try store.card($0) }
        }
    }

    @ViewBuilder private func items(_ content: Content) -> some View {
        switch content {
        case .session(let state?): if state.showsMenu { SessionMenuItems(state: state) }
        case .card(let card?): CardActions(card: card, more: true)
        case .project(let id): ProjectMenuItems(projectID: id)
        case .cue:
            let cue = workspace.cue
            // 开关同设置里那一个（`AppServices.turnCue`）；停用后再启用回到停用前那台
            if cue.presence == .disabled {
                Button("启用 \(cue.name)", icon: .wakeEnabled) { workspace.turnCue(true) }
            } else {
                Button("停用 \(cue.name)", icon: .wakeEnabled) { workspace.turnCue(false) }
            }
            // 运行情况给开发者看：只在 Cue 于这台 Mac 值班时有（经过只在值班的管理器里）
            if workspace.services.cue.keeper != nil {
                Toggle("运行情况", icon: .session, isOn: Bindable(cue).showsRun)
            }
            Button("\(cue.name) 的设置…", icon: .settings) { SettingsPane.open(.general) }
        case .progress:
            Button("新任务", icon: .add) { workspace.progressPane = .board; workspace.addsTask = true }
            Button("新会话", icon: .add) { workspace.newSession() }
            ProjectScopeItems()
            Button("搜索（⌘K）", icon: .search) { workspace.searching = true }
                .disabled(!workspace.isLibraryReady)
            Divider()
            Button("全部归档做完的", icon: .archive) { workspace.attempt { try await workspace.archiveCompletedTasks() } }
            Button("接入 Agent…", icon: .extensionNote) { workspace.showsSetup = true }
        case .trash:
            Button("清空回收站…", icon: .trash, role: .destructive) { workspace.confirmsEmptyTrash = true }
        case .session(nil), .card(nil), .none: EmptyView()
        }
    }
}

/// 项目页"⋯"里的几项：进入批量选择（`CardPresses`，一条都还没选，点卡再选）、看这个项目的会话（进展页两段共用的项目范围设成它，再去会话段）、项目的操作。
/// 添加任务就在页上的任务区里。
private struct ProjectMenuItems: View {
    let projectID: UUID
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let ready = workspace.isLibraryReady
        Button("选择灵感", icon: CardMenu.Item.select.icon) { workspace.presses.beginSelecting() }
            .disabled(!ready || (workspace.catalog?.cardCounts[projectID] ?? 0) == 0)
        Button("看这个项目的会话", icon: .session) {
            workspace.projectScope = projectID
            workspace.showSessions()
        }
        if let project = workspace.catalog?.project(projectID) {
            Divider()
            ProjectActions(project: project) { workspace.projectForm = .init(project: project) }
        }
    }
}
#endif
