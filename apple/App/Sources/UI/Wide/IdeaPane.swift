import CueEditor
import CueStore
import SwiftUI

/// 并排里的一条灵感（`WideNavigation.Beside.card`）：栏头写它所在的项目与第一行，拖名牌挪到别处，末端的钮收起；下面直接可改。
/// 同一条灵感只在一处可改（`CardEditing` 是唯一写者）：放进并排时盖着它的编辑页先收起（`Workspace.drop`），并排着时再打开它不另开一份（`showEditor`）。
struct IdeaPane: View {
    let cardID: UUID
    let column: Workspace.Column
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.headInset) private var inset
    @State private var data: Shown?
    @State private var editing: CardEditing?

    nonisolated private struct Shown: Sendable, Equatable {
        var card: Card
        var project: Project?
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let data, let editing {
                editor(data.card, editing).padding(.top, Chrome.band + Spacing.item)
            }
            head.padding(inset).frame(height: Chrome.band)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.desk)
        // 卡没了（删了、并进了草稿）由工作区收起这一块（`leave`），不当成出错
        .observing(services.store, id: cardID, into: $data, onError: { [workspace] error in
            if case CueStoreError.notFound = error { return }
            workspace.fail(error)
        }) { [cardID] store in
            guard let card = try store.card(cardID) else { throw CueStoreError.notFound }
            return Shown(card: card, project: try store.project(card.projectID))
        }
        .onChange(of: data?.card.id, initial: true) {
            guard editing == nil, let card = data?.card else { return }
            editing = CardEditing(card, workspace: workspace)
        }
        .onDisappear { editing?.leave() }
    }

    @ViewBuilder private func editor(_ card: Card, _ editing: CardEditing) -> some View {
        let theme = CueEditorTheme.inspiration(palette, horizontalInset: Spacing.page, maxTextWidth: InspirationPaper.textWidth)
        #if os(macOS)
        editing.field(card, theme: theme)
        #else
        CardTextField(card: card, editing: editing, theme: theme)
        #endif
    }

    private var head: some View {
        HStack(spacing: Spacing.item) {
            name
            Spacer(minLength: Spacing.item)
            HeadTool(label: "收起并排", icon: .rightColumn) { workspace.closeColumn(column) }
        }
        .accessibilityElement(children: .contain)
        .windowDragArea()
    }

    /// 同会话那一块的名牌（`WideSessionTitle`）：项目名是去那个项目的钮，第一行是拖它的把手。
    private var name: some View {
        HStack(spacing: Spacing.glyph) {
            if let project = data?.project {
                Button { workspace.select(.project(project.id)) } label: { Text(verbatim: project.shownName).lineLimit(1) }
                    .buttonStyle(PressStyle(.inline))
                    .foregroundStyle(palette.ink3)
                Text(verbatim: "/").foregroundStyle(palette.ink3).readerHidden(true)
            }
            let title = data?.card.heading ?? ""
            #if os(iOS)
            WideTitleDrag(title: title, type: .cuepadCard, item: DraggedCard.idea(cardID)).layoutPriority(1)
            #else
            Text(verbatim: title).foregroundStyle(palette.ink).lineLimit(1)
                .contentShape(.rect)
                .draggable(DraggedCard.idea(cardID))
                .layoutPriority(1)
            #endif
        }
        .font(Typography.toolbarTitle)
        .padding(.horizontal, Spacing.block)
        .frame(height: Chrome.control)
        .glass(in: .capsule)
    }
}

/// 盖在会话上打开的灵感（编辑页）栏头那颗：把它挪到会话旁边并排，边聊边看。只在主区最左是会话时有。
extension View {
    @ViewBuilder func draggable(idea: UUID?) -> some View {
        if let idea { draggable(DraggedCard.idea(idea)) } else { self }
    }
}

struct BesideIdeaButton: View {
    let cardID: UUID
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.layout == .wide, workspace.session(in: .main) != nil, workspace.openCard == cardID {
            #if os(macOS)
            HeadTool(label: "并排打开", icon: .rightColumn, action: besides)
            #else
            // 页头右边那一排自己是一块玻璃（`FloatingHeader`）：钮不再带玻璃
            Button("并排打开", icon: .rightColumn, action: besides)
            #endif
        }
    }

    private func besides() { workspace.drop(.card(cardID), at: WideNavigation.maxPanes, replacing: false) }
}
