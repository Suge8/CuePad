import CueEditor
import CueStore
import SwiftUI

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
            WideTitleDrag(title: title, type: .cuepadCard, item: DraggedCard.idea(cardID), pane: .card(cardID)).layoutPriority(1)
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

extension View {
    @ViewBuilder func draggable(idea: UUID?) -> some View {
        if let idea { draggable(DraggedCard.idea(idea)).reportsWideDrag(.card(idea)) } else { self }
    }
}

struct ChatAlongsideButton: View {
    let cardID: UUID
    var editing: CardEditing?
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if let action {
            #if os(macOS)
            HeadTool(label: "边聊边看", icon: .rightColumn, action: action)
            #else
            Button("边聊边看", icon: .rightColumn, action: action)
                .disabled(workspace.layout == .narrow && editing?.text.isEmpty != false)
            #endif
        }
    }

    private var action: (() -> Void)? {
        switch workspace.layout {
        case .wide:
            guard workspace.session(in: .main) != nil, workspace.openCard == cardID else { return nil }
            return beside
        case .narrow: return pick
        }
    }

    private func beside() {
        if !workspace.drop(.card(cardID), at: WideNavigation.maxPanes, replacing: false) { workspace.say("窗口太窄，放不下并排", tone: .failure) }
    }

    private func pick() {
        workspace.attempt { [workspace, editing, cardID] in
            _ = try await editing?.flushed()
            workspace.pickDock(cardID)
        }
    }
}
