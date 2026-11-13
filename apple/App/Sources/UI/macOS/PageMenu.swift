#if os(macOS)
import CueStore
import SwiftUI

/// 没有可放的页（归档）钮停用、同系统停用的控件那样变淡：与可用时一个样子，点了没反应像是坏了。
/// 菜单项不按页面数据置灰：菜单拿不到页面读的库，抄一份过来就是第二个事实源；没有可归档、可清空的时候点了什么也不发生。
/// 钮在每一页都在、只随页面置灰，栏头不随换页增删控件、不重排。进展页它是项目范围（筛选的图形，选了项目时角上是那个项目），
/// 排在列头那一排的开头（`leads`）：先选范围再看四列，右端留给滑到 Cue 浮板下面的列，压在最后一列的列头上会盖住列名。
/// 那一页别的操作各在原处——归档做完的在已完成那一列的列头，接入 Agent 在设置。
/// 会话页的钮跟着页面就在，菜单里的会话项等页面交来的值、并晚于标题两帧（`showsMenu`）。
struct PageMenuSlot: View {
    var leads = false
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    /// 编辑页开着的那张卡（外层 nil 是还没读到；不是编辑页时读出的是 nil）。
    @State private var opened: Card??
    @State private var inspirationSharing = InspirationSharing()

    private enum Content: Equatable {
        case card(Card?)
        case project(UUID)
        case progress
        case trash

        var help: LocalizedStringResource {
            switch self {
            case .card: "置顶、移到项目、复制、归档、删除"
            case .project: "选择灵感、看这个项目的进展、项目操作"
            case .progress: "项目范围"
            case .trash: "清空回收站"
            }
        }
    }

    /// nil：这一页没有操作，不摆钮。
    private var content: Content? {
        if let id = workspace.openCard { return .card((opened ?? nil).flatMap { $0.id == id ? $0 : nil }) }
        return switch workspace.mainRoute {
        case .project(let id): .project(id)
        case .progress: .progress
        case .trash: .trash
        default: nil
        }
    }

    var body: some View {
        let content = content
        Group {
            if let content {
                Menu { items(content).labelStyle(.titleAndIcon) } label: { menuLabel(content) }
                    .menuStyle(.button).menuIndicator(.hidden)
                    .buttonStyle(ControlButtonStyle(kind: .circular))
                    .fixedSize()
                    .padding(.leading, leads ? 0 : Spacing.item)
                    .disabled(content == .card(nil))
                    .help(content.help)
                    .accessibilityLabel(content == .progress ? Text("项目范围") : Text("更多"))
            }
        }
        .observing(services.store, id: workspace.openCard, into: $opened, onError: workspace.fail) { [id = workspace.openCard] store in
            try id.flatMap { try store.card($0) }
        }
        .modifier(InspirationSharePresentation(sharing: inspirationSharing, editing: workspace.openCardEditing))
    }

    @ViewBuilder private func menuLabel(_ content: Content) -> some View {
        if content == .progress { ProjectScopeLabel() } else { Image(.more) }
    }

    @ViewBuilder private func items(_ content: Content) -> some View {
        switch content {
        case .card(let card?):
            if let editing = workspace.openCardEditing, editing.cardID == card.id {
                InspirationEditorActions(card: card, editing: editing, sharing: inspirationSharing)
            } else { CardActions(card: card, more: true) }
        case .project(let id): ProjectMenuItems(projectID: id)
        case .progress: ProjectScopePicker().pickerStyle(.inline)
        case .trash:
            Button("清空回收站…", icon: .trash, role: .destructive) { workspace.confirmsEmptyTrash = true }
        case .card(nil): EmptyView()
        }
    }
}

private struct ProjectMenuItems: View {
    let projectID: UUID
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let ready = workspace.isLibraryReady
        Button("选择灵感", icon: CardMenu.Item.select.icon) { workspace.presses.beginSelecting() }
            .disabled(!ready || (workspace.catalog?.summaries[projectID]?.cardCount ?? 0) == 0)
        Button("看这个项目的进展", icon: .task) { workspace.showProgress(of: projectID) }
        if let project = workspace.catalog?.project(projectID) {
            Divider()
            ProjectActions(project: project) { workspace.projectForm = .init(project: project) }
        }
    }
}
#endif
